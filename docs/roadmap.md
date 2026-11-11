# clear-ls roadmap

clear-ls is an experimental Crystal language server written in Crystal. It
parses with Tree-sitter and answers editor queries from an approximate,
editor-oriented semantic model. The Crystal compiler stays authoritative for
diagnostics and final semantics.

Current state: [status.md](status.md). Code map:
[architecture.md](architecture.md); workflow and tools:
[development.md](development.md); pitfalls: [gotchas.md](gotchas.md).

Design background:

- [Semantic architecture](design/crystal-lsp-semantic-architecture.md):
  CST/HIR split, IDs, DefMap, CFG, inference, overloads, macros, queries.
- [Cursor position lookup](design/cursor-position-semantic-lookup.md):
  position encoding, cursor bias, syntax→HIR mapping, program points.
- [Persistent cache](design/persistent-cache.md) (Phase 11): layers,
  invalidation, file format, compiler facts.
- [Tree-sitter grammar notes](tree-sitter-grammar-notes.md): known parse gaps.

The first two design docs were written for the earlier "Opal" prototype; the names
differ but the architecture applies unchanged.

## Pipeline

```text
VFS (disk + overlays) → snapshot → Tree-sitter CST
   ├── item lowering → item tree → DefMap / project index
   └── body lowering (on demand) → body HIR → CFG → inference → call resolution
                                                      ↑
                         compiler facts (async, labelled) ┘
```

## Toolchain baseline

| Component | Version |
|---|---|
| Crystal | 1.22.0 (LLVM 22) |
| Tree-sitter runtime | v0.26.9, vendored and statically linked |
| tree-sitter-crystal | `50ca9e6` (2025-10-11), statically linked |
| crystal-tree-sitter binding | `1d46ca2`; only `LibTreeSitter` declarations are relied on |

The binding links `pkg_config: "tree-sitter"`; the Makefile provides a local
`tree-sitter.pc` that points at the static archive. `Language#abi_version`
calls the removed `ts_language_version`, so clear-ls uses its own
`ts_language_abi_version` declaration.

## Phases

### Phase 0 — foundations (done)

The server keeps an exact, incrementally reparsed view of every open buffer.

- Makefile: pinned deps, static archives, `verify-static`, `grammar-check`.
- `TextRange`, `FileId`, `LineIndex` (byte ↔ point ↔ LSP position;
  utf-8/utf-16/utf-32 encodings).
- VFS with overlay-over-disk precedence; immutable `Snapshot`.
- Syntax layer: generated `SyntaxKind`/field IDs from `node-types.json`,
  node helpers, incremental reparse with `ts_tree_edit`.
- LSP stdio transport, JSON-RPC, lifecycle, incremental text sync.
- CLI: `clear-ls lsp`, `clear-ls dump-cst FILE`.

Exit: edits keep incremental and fresh parses identical (property test);
position conversion round-trips; a real client can open/edit/close.

Measurements (stdlib, 1646 files, 9.1 MB, `--release`): 2.4 s single-thread
parse. Keeping every tree alive needs 282 MB GC heap with the binding's
default Boehm allocator versus 17 MB heap with
`-Dcrystal_tree_sitter_no_init` (libc malloc; RSS 297 MB vs 272 MB).
Syntax trees for non-open files should be dropped after item lowering; the
allocator choice is revisited in Phase 11 (kept: libc, step 8).

### Phase 1 — declarations and project model (done)

- Item tree per file: namespaces, defs, macros, aliases, constants, enums,
  `lib`/`fun`, annotations, include/extend, visibility, docs.
- Full signatures: external/internal names, defaults, splats, blocks,
  restrictions, return types, `forall`.
- Known declarative macros: `getter`/`setter`/`property` family, `record`,
  `delegate`, with generated provenance.
- Item fingerprints: body-only edits do not invalidate declarations.
- DefMap: reopened types share one identity; path resolution; ancestors.
- Project model: shard root, `lib/`, require graph, prelude, stdlib index.
- Features: document/workspace symbols, folding, selection range, type and
  constant goto-definition and hover, require document links.

Status: implemented as above, plus `{% if flag?(...) %}` bodies (reparsed
with included ranges, filtered by target flags) and declarations recovered
from `ERROR` nodes. Not yet: `delegate`/`def_equals*` macros, file-private
type scoping, multi-root workspaces, persistent stdlib cache.

Measurements (`--release`): this repo indexes 386 files (prelude closure +
shard + workspace) in ~0.65 s on 8 workers; the whole stdlib lowers in
0.35 s after parsing. Definition and hover answer in < 1 ms once indexed;
workspace symbol search ~35 ms over ~45k items.

### Phase 2 — body HIR and scopes (done)

- On-demand body lowering with `BindingId`s and two-way source maps.
- Error nodes lower to `Missing`/`Unknown` placeholders.
- Cursor lookup per the design doc.
- Features: local definition, document highlight, local rename and
  references, semantic tokens.

Status: implemented. Scoping rules were checked against the compiler
(`x = x` sees the outer `x`, `@x` params bind `x`, block-assigned locals stay
in the block, `if`/`while`/`case` share the enclosing scope). Top-level and
type-body code get their own file body. Not yet: locals inside macro bodies
(`{% %}` / `{{ }}`), the `SpanIndex`/`ProgramPoint` parts of the cursor-lookup
design (deferred to Phase 4), references/rename for non-locals (Phase 9).

Measurements (`--release`): the stdlib's 15k defs lower in 0.33 s
(21 µs/def). On a 380-line file, full semantic tokens take ~3 ms warm;
local definition/references/rename answer in < 1 ms.

### Phase 3 — basic types (done)

- `TypeId`, `TypeSet` with certainty and provenance.
- Literals, annotations, `.new`, assignments, declared returns, ivars,
  accessor types.
- Features: typed hover, receiver/path/ivar completion, type inlay hints.

Status: implemented, plus generic substitution (receiver args, `include
Enumerable(T)` propagation, `forall` from args and block returns) and
shallow yield summaries for blocks without restrictions. These were planned
for Phase 6 and turned out to be needed for useful completion on stdlib
collections. Branches are joined structurally with nil/`is_a?` narrowing;
no CFG yet. Method hover/definition follow inferred receivers. Completion
analyses a copy of the buffer with a placeholder identifier at the cursor.

Coverage (locals and block args with a known type): ~64% in this repo,
~35% in the stdlib (which uses many untyped params). Inference averages
~0.35 ms per def including summaries; completion/hover answer in 1–3 ms.

Not yet: method return inference for unannotated defs (Phase 6),
untyped-param call-site specialisation (Phase 6), overload ranking by
argument types (Phase 5), keyword-argument completion (Phase 5).

### Phase 4 — control-flow analysis (done)

- Per-body CFG; joins; narrowing by `is_a?`, `nil?`, truthiness, `&&`/`||`,
  `case`/`in`; loop fixed points; rescue/ensure; unreachability.
- Features: flow-sensitive hover/completion; type at cursor.

Steps (one commit each):

1. **HIR prep.** Lower modifier `if`/`unless` as `[cond, then]` (CST
   order is `then, cond`); tag rescue clauses (`syntax: Rescue`, rescue
   var binding on the clause); `when`/`in`/`else` clauses keep their
   syntax kind. No inference changes beyond the modifier-if fix.
2. **CFG builder** (`src/clear_ls/flow/`). Basic blocks of HIR
   operations in evaluation order, terminators (jump, branch on a
   condition expr, return, break, next, raise-free fallthrough), loop
   heads, call blocks as 0..n loops, rescue/ensure edges, unreachable
   blocks. `dump-cfg FILE LINE` CLI and shape specs. Inference unchanged.
3. **Dataflow inference on the CFG.** Worklist over block-entry
   environments with joins, iteration budget, and edge refinements
   (truthiness, `nil?`, `is_a?`, `!`, `&&`/`||`). Replaces the structured
   `visit_if`/`visit_case`/`visit_loop`/`visit_and_or`; per-expression
   transfer logic is reused. Early exits mid-branch, loop fixed points.
4. **`case`/`in`, rescue, ensure.** `when T`/`in T`/`when .nil?` narrow
   the subject local; rescue vars typed from their restriction (else
   `Exception`); ensure runs on all paths.
5. **Program points.** Environment before an expression / at a cursor
   offset; hover reports the type at the reference's program point,
   completion and local-type details use it. Flow-sensitive hover spec.
6. **Verification and docs.** Coverage/perf against Phase 3 baselines,
   headless Neovim check, roadmap + README status.

Not planned: ivar/cvar narrowing. The compiler narrows only locals
(`if @a` leaves `@a` nilable), so clear-ls does the same.

Status: implemented as planned. `Flow::Builder` turns a body into basic
blocks of evaluation-ordered operations; `Types::Infer` solves block-entry
environments with a worklist (reverse postorder, widening to unknown after
8 changes of a block's state). NoReturn calls (`raise`, `exit`) end
reachable code; edges whose narrowing leaves a local with no possible type
are infeasible. Code after an exit is analysed afterwards from the code it
follows, so completion works while editing it. `Infer#env_at` replays a
block to the cursor; local completion details and hover use it.

Measurements (`--release`, vs Phase 3): coverage of locals and block args
62.8% in this repo (61.7%), 35.5% in the stdlib (35.4%); the remaining
unknowns are mostly unannotated method returns (Phase 6). Inference over
this repo's 540 defs takes 0.18 s (0.38 s); stdlib sample 1.58 s (1.98 s).
CFG construction for all 15k stdlib defs takes 86 ms.

Not yet: `responds_to?` narrowing, closure-captured locals stay narrowed
(the compiler does not narrow them), ensure on exceptional paths.

### Phase 5 — call resolution (done)

- Argument binding (defaults, named, splats, blocks), three-valued
  compatibility, bounded specificity; `IO#gets` regression family.
- Features: signature help, overload-aware definition, implementation,
  outgoing call hierarchy.

Steps (one commit each):

1. **Call shape in HIR.** Splat / double-splat arguments get their own
   kinds; `&blk` / `&->foo` (block pass) is distinguished from `&.foo` and
   literal blocks. No resolution changes.
2. **Resolver** (`Types::CallResolver`). Structural binding of
   positional, named (external names), defaulted, splat, double-splat,
   named-only (after `*`), and block arguments; three-valued compatibility
   of argument types with restrictions (unknown keeps a candidate);
   bounded specificity ranking; `CallResolution` with kind (unique,
   multiple runtime targets, ambiguous, unresolved) and per-candidate
   argument → parameter maps. Specs: `IO#gets` family on a fake prelude.
3. **Use it.** Inference return/block types from the viable set; hover
   and definition show viable overloads (the whole family when none is
   viable); `IO#gets` LSP spec. Replaces `arity_ok?`.
4. **Signature help** (`(`/`,` triggers): enclosing call, viable
   signatures, active signature/parameter by binding; works in
   unfinished calls.
5. **Named-argument completion** inside call parentheses from the
   viable candidates (`io.gets(li|)` → `limit:`).
6. **Implementation and outgoing call hierarchy.** Overrides of a
   method in subtypes / implementers of an abstract def; subtypes of a
   type; resolved calls in a def body. Incoming calls need workspace
   references (Phase 9).
7. **Verification and docs.**

Exit criterion (design doc): the `IO#gets` examples narrow to the
expected overload set without guessing when argument types are unknown.

Status: implemented as planned. `Types::CallResolver` binds arguments
structurally (an unknown count from `*xs` / `**opts` keeps candidates),
checks types three-valued with literal autocasting (`1` to any number, `:sym`
to enums), expands union arguments into at most 16 runtime combinations,
and drops a candidate only when a definitely matching candidate is at least
as specific (overrides: the nearer ancestor wins ties). `IO#gets` specs: literal arguments pick one
overload, `io.gets(value)` keeps the four one-argument ones, `String | Char`
gives the two delimiter overloads as multiple runtime targets.

Pulled in to avoid regressions when the arity filter went away: number
primitives that the stdlib declares inside `{% for %}` (operators, `to_*`),
alias expansion in restrictions (`Process::Stdio`), and `&.foo` receivers
typed from the block argument.

Measurements (`--release`, vs Phase 4): typed locals and block args 66.0%
in this repo (62.8%), 39.9% in the stdlib (35.5%). Inference over this
repo takes 0.23 s for 603 defs (0.18 s for 540). In Neovim: signature help
< 1 ms, implementation < 1 ms, outgoing calls 80 ms (cold body inference).

Not yet: incoming calls (Phase 9), return inference for unannotated defs
such as `Enumerable#sum`, `Hash#[]?` (Phase 6). Signature help needs the
call's line to parse: an unclosed `(` before `end` makes Tree-sitter
swallow the enclosing def, so the call is only found after a `)` is
inserted on the same line (handled) or typed.

### Phase 6 — generics and summaries (done)

- Generic substitution, on-demand return summaries, call-site-keyed method
  instances, recursion and widening budgets, block/collection contracts.
- Features: typed collection chains, block parameter types, more inlay hints.

Already done in Phase 3: substitution from receivers, includes, and
`forall`; shallow yield summaries. Measured blockers (unknown locals by
cause, stdlib / this repo): viable call without declared return 506 / 89,
unknown receiver 633 / 67 (mostly downstream of the former), unresolved
name 185 / 28.

Steps (one commit each):

1. **Summary engine.** `Types::Summaries` per Typing generation: return
   (and yield) summaries of unannotated defs keyed by (def, self type,
   argument types), computed on demand by inferring the def's body with
   params bound to the call's argument types; states Computing → Complete,
   recursion yields the partial result (or unknown), depth and total-work
   budgets. Replaces the separate yield summary path. Unit specs with the
   fake prelude (`Item#label`, recursive defs, mutual recursion).
2. **Use summaries in inference.** `declared_return` falls back to the
   summary; `return` values, implicit last expression, and NoReturn paths
   all join. Coverage/regression diff on repo and stdlib.
3. **`typeof` and element types.** `typeof(expr)` in restrictions and
   bodies (`[] of typeof(...)`), `Enumerable.element_type`, `.not_nil!`
   in type position → `compact_map`, `compact`, `flatten`, `sum`, `to_h`.
4. **Collection/block contracts.** Remaining exit-criterion chains that
   summaries cannot reach (primitive-backed or macro-generated stdlib
   code): tuple `[]` with literal index, `Hash#[]`/`[]?`, `reduce`,
   `find`, measured by the chains fixture.
5. **Features.** Inlay hints for unannotated method returns; hover shows
   inferred return types (labelled inferred).
6. **Verification and docs.**

Exit criterion (design doc): Array(T), Hash(K, V), tuple, block, map,
compact_map, find, and reduce chains retain useful concrete types.

Status: implemented as planned; step 4 needed far fewer contracts than
expected. `Types::Summaries` caches (def, file revision, self type,
argument types [, block value]) → joined return and yield types, computed
by inferring the def's body with params bound to the call's argument
types (restricted params too, when the argument fits: `Int#//(other :
Int::Primitive)` called with Int32). Recursion and unknown block values
are `Pending`: they vanish from unions without ending control flow, like a
first fixed-point iteration; results depending on a cut are not cached
below the cycle head. Budgets: depth 12, 8 shapes (16 since Phase 8) per (def, receiver),
20k summaries per generation, a per-solve step cap. Through summaries
alone, `reduce`, `find`, `Hash#[]`/`[]?`, `group_by`, `to_h`,
`compact_map`, `compact`, and user defs without annotations type
correctly. Contracts (only for stdlib collection owners when resolution
leaves the result unknown): tuple `[]` with a literal index, `sum`,
`flatten`, `zip`. Constants are inferred as expressions (`%w()`, `[...]`,
calls); tables over 4 KB from a prefix.

Measurements (`--release`, vs Phase 5 incl. post-phase hover fixes):
typed locals and block args 89.6% in this repo (73.5%), 59.8% in the
stdlib (43.3%); per-local type diff against each step's predecessor
showed no unexplained regressions. Inference over this repo's 639 defs
takes 0.46 s cold (0.26 s); worst stdlib def 43 ms cold; warm hover
0.1–0.3 ms. All chains in the exit fixture (`tools/fixtures/chains/src/c.cr`)
are typed.

Not yet: closure-captured variables, ivar types from assignments in
methods, macro-generated defs (`{% for %}`), `responds_to?` narrowing.
Remaining unknowns are mostly untyped params of stdlib defs analysed
without a caller and macro-heavy code.

### Phase 7 — compiler integration (done)

- Async `crystal build --no-codegen -f json` diagnostics.
- `crystal tool expand` for explicit macros; a separate exporter for macro
  hooks (`tool expand` cannot locate hook expansions).
- Features: compiler diagnostics, expansion preview, formatting via
  `crystal tool format`, compiler-confirmed types.

Measured (Crystal 1.22): `build --no-codegen -f json` writes a JSON array
of frames (instantiation trace, then the error) to stderr and exits 1;
warnings stay text even with `-f json`; columns count codepoints. It takes
~0.7 s on a small project and 1.8 s on this repo. `--stdin-filename` only
replaces the main file, so compiler results describe saved files.
`tool expand -c` finds a cursor in a non-main file only when that file is
also passed as a source; hook expansions (`included`, `inherited`) are never
found. An extra source with `macro finished` sees every method, including
those that hooks, `{% for %}` and `property` generate, with locations, and can run in
the diagnostics compile (stdout vs stderr). Ivar types need a nested
`\{% %}` inside a def body. `tool format -` takes ~25 ms. `tool context`
takes ~0.8 s per location, which is too slow to call from hover directly.

Steps (one commit each):

1. **Toolchain runner** (`src/clear_ls/compiler/`). Subprocess runner
   with timeout and kill; entry-point selection (shard targets whose
   require closure contains the file, else the file itself); parsers for
   JSON error frames (final error + trace as related information) and
   text warnings. Unit specs on recorded output plus one real-compiler
   spec.
2. **Async diagnostics.** On open/save, a background fiber compiles each
   affected entry point; a newer run supersedes (kills) an older one;
   `publishDiagnostics` per file, clearing files that no longer have
   errors; codepoint columns are converted to the client encoding using the
   text of the saved file. `initializationOptions.compiler` (`enabled`, `path`,
   `entries`). Requests never wait on the compiler.
3. **Formatting.** `textDocument/formatting` via `crystal tool format -`
   on the buffer text, minimal line-range edit; syntax errors return no
   edits plus a log message.
4. **Expansion preview.** `clearLs/expandMacro` request (position →
   expanded sources and macro locations) on the saved file; Neovim usage
   in README.
5. **Compiler facts exporter.** Extra `macro finished` source in the
   diagnostics compile: workspace methods (owner, name, signature,
   location) and ivar types. Methods missing from the DefMap become
   synthetic items (provenance `compiler`, location = generating call);
   ivar types fill unknown ivars. Facts are labelled and replaced on the
   next successful run.
6. **Compiler-confirmed types.** `tool context` for the def under the
   cursor, run in the background after a hover on an unchanged saved
   file and cached by (file revision, def); later hovers show
   `compiler: T` beside the inferred type.
7. **Verification and docs.**

Exit criterion (design doc): compiler facts improve semantic results
without blocking normal requests.

Status: implemented as planned. `Compiler::Toolchain` and `Job` run
subprocesses with timeouts and cancellation. `Compiler::Checker` checks
each program (the shard targets whose require closure contains the file,
else the file itself) at startup, on open, and on save. A newer request
cancels the running check, and results are merged per file, so files that
became clean are cleared. A stdlib error is reported at the last workspace
frame of its trace, and the full trace becomes related information.
Compiler columns are codepoints and are converted with the saved text.
Formatting (`crystal tool format -`) formats the buffer text and sends one
line-range edit. `clearLs/expandMacro` passes the cursor file as a source
because the tool ignores cursors in required files.

`Compiler::Exporter` adds about 0.05 s to the diagnostics compile and
reports methods with locations and ivar types. Methods whose location has
no source member of that name become `Origin::Compiler` items located at
the generating code: hooks, `{% for %}`, `JSON::Serializable`. Undeclared
ivars get the compiler's types. Facts from files saved since the check are
skipped. A compile error stops the export after the methods section, and
the previous ivars are kept. Hover labels both kinds of fact. Hovering a
local in a saved, unmodified file starts a `tool context` run for its def.
Later hovers then show `compiler: T` per instantiation. The tool falls
back to top-level variables for uninstantiated defs, and those results are
rejected. Requests that wait on a subprocess (expansion) are answered from
a fiber (`LSP::Deferred`).

Measurements (`--release`, this repo, 460 files): check 1.9 s (exporter
adds no measurable time), 2140 method and 532 ivar facts → 826 synthetic
members; DefMap rebuild 4 ms without facts, 5–7 ms with them (first
application 60 ms, header parse cached per result). Hover latency while a
check runs: median 0.2 ms. Small project: diagnostics 0.9 s after
indexing, expansion 0.8 s, formatting 21 ms, context 0.7 s. `make spec`
takes ~9 s now (was 1.1 s) because 9 specs run the real compiler.

Not yet: diagnostics for unsaved buffers (the compiler only reads files;
`--stdin-filename` replaces only the main file); hook-macro expansion
preview (the tool cannot locate it); compiler facts for generic types'
ivars (`type_vars` non-empty) and the stdlib; facts are not used for
completion ranking beyond normal member lookup.

### Phase 8 — language-semantics parity

The Crystal 1.22 syntax and semantics book's examples, run through both
the compiler and clear-ls, found wrong and missing types. The gaps are
grouped in [book-gaps.md](book-gaps.md) (IDs A1–M5). clear-ls stays
best-effort and DX-first, not a copy of the compiler. This phase fixes
wrong results, fills in unknowns where a cheap local rule exists, and
records any deliberate deviation.

Harness: `make bin/probes/type_marks && tools/book_diff.py`. Baseline
191/290 markers match, 1 accepted deviation, 25 wrong. Each step reports
the new count and runs the `types_dump` regression diff (repo and
stdlib).

Steps (one commit each, wrong results first):

0. **Harness.** `type_marks` probe, `book_diff.py`, book fixtures,
   [book-gaps.md](book-gaps.md).
1. **Literals and autocasting** (A1–A3, B1–B4). Integer literal ranges;
   begin-less ranges; pseudo-constants; float literals no longer
   autocast to integers; exact matches rank above autocast ones.
   *Done:* book 202/290 (+11) plus `autocast.cr` 19/19; regression diff
   repo 0/0, stdlib 0 regressed, 5 improved (summaries keep type params
   that the receiver carries, e.g. `Pointer(UC)#+`).
2. **Enums** (C1–C4). Members typed as the enum; `value` as the base
   type; flags `|`/`&` and predicates.
   *Done:* book 211/290 (+9), new `enums.cr` 27/28 (`==` is D3); regression
   diff repo 0 regressed / 31 improved, stdlib 0 / 15 (enum-typed lib
   calls and callbacks).
3. **Primitives** (D1–D9). Empty `@[Primitive]` bodies are unknown, not
   `Nil`, with contracts for `class`, `malloc`, `==`, `/`, `unsafe_as`,
   `null`, `name`; lowering for `pointerof`/`sizeof`-family nodes and
   `$~`/`$1`; `try` per union member.
   *Done:* book 233/290 (+22), new `primitives.cr` 56/57 (+1 accepted:
   `spawn`); fixed six older bugs on the way (book-gaps O1–O6: class-method
   self, abstract/override ranking, nominal tuples, summary shape cap,
   macro returns, generic aliases). Coverage repo 93.8% (91.6%), stdlib
   67.1% (59.9%), same timings; regression diff repo 0 regressed / 40
   improved, stdlib 4 / 376, the 4 being former wrong `NoReturn`/`Nil`
   answers now unknown.
4. **`break` values** (E1–E3). `while`/`until` value = breaks + `Nil`
   unless the condition is `true`; a block's `break` joins the call's
   type.
   *Done:* book 238/290 (+5), new `loops.cr` 17/17 (2 accepted); regression
   diff repo 0/0, stdlib 0 regressed, 2 changed (`while true` loops that
   only `return`, now not nilable); coverage unchanged.
5. **Procs and blocks** (F1–F5). Proc return annotations; `&proc`
   values; method procs (`->foo`, `->x.foo(T)`); `-> _` block returns;
   `with … yield` receivers.
   *Done:* book 246/290 (+8), new `procs.cr` 29/29; also `Proc(A, R)`
   written nominally is the structural proc, `Proc#arity`, and completion
   inside `with … yield` blocks offers the receiver's methods. Regression
   diff repo 0 regressed / 4 improved, stdlib 0 / 0; stdlib inference
   +2% time (with-receiver lookup, only for defs whose source has
   `with … yield`).
6. **Splats** (G1–G6). Splat params (`*xs : T` per argument) and
   `**opts` from the call; splatted tuple/named-tuple arguments; splats in
   tuple, array and multi-assign literals.
   *Done:* book 250/290 (+4, +1 accepted), new `splats.cr` 24/24 (2
   accepted). Splats in collection literals needed a lowering workaround
   for a grammar quirk (`*xs` lexed as regex modifier `x` + `s`, see
   tree-sitter-grammar-notes). Regression diff 0/0 on repo and stdlib;
   stdlib inference +4% time (more summary shapes: 4847 vs 4768).
7. **Closures and redefinitions** (H1, I1–I4). Captured locals take the
   union of all their assignments; `previous_def` replaces instead of
   overloading; `super`; generic args from `initialize`; `new` in class
   methods.
   *Done:* book 256/290 (+6), new `closures.cr` 21/21; no wrong book
   entries left. Captured locals use a second solve with their joined
   type; redefinitions follow the compiler's restriction key (checked:
   defaulted trailing params and param names don't count). Regression
   diff repo 0 / +1, stdlib 0 / +23 (O7); coverage stdlib 67.5% (67.1%).
8. **Ivar rules and narrowing** (J1–J4, K1–K3), per decision 5 in
   book-gaps.md.
   *Done:* book 267/290 (+11), new `ivars.cr` 22/22 (3 accepted) and
   `narrowing.cr` 11/11. Undeclared ivars are items with
   `Origin::Assigned`, so body edits that change them rebuild the DefMap
   (fingerprint); compiler facts replace them. Coverage stdlib 70.5%
   (67.6%), repo 93.7%; regression diff 0 regressed, stdlib +151, repo
   0; stdlib inference +3% time. `book_diff.py` now indexes each fixture
   alone (fixtures reuse class names).
9. **Union shape** (M1–M5), per decisions 1–4 and 6.
   *Done:* book 271/290 + 9 accepted (the union-shape examples), new
   `union_shape.cr` 14/14 (2 accepted); completion filters union members;
   abstract dispatch; tuple-union indexing; declared-local flow types;
   types as values; `(A | B).class` display. Regression diff 0 regressed,
   repo +5, stdlib +26; coverage stdlib 71.0% (70.5%), +3% time.
10. **C bindings** (L1–L2).
    *Done:* new `c_bindings.cr` 20/20; book 275/290 + 15 accepted, so every
    book example now matches or is an accepted deviation (all fixtures:
    527 match + 25 accepted of 552). Regression diff 0 regressed, repo +5,
    stdlib +31 (and 30 locals newly visible: `out` declares them);
    coverage stdlib 71.6% (71.0%).
11. **Verification and docs.** Book diff, coverage and regression diff,
    `make nvim-check`, roadmap and README.

Exit criterion: no *wrong* entries left in book-gaps.md; each remaining
difference is either an accepted deviation (marked `# cls:` in the
fixtures) or listed with a reason.

Status: done (exit criterion met). Every marker in the 22 book fixtures
matches the compiler or is an accepted deviation: 527 match + 25
accepted of 552 (the original 290 book markers: 275 + 15; 262 markers in
the 11 fixtures added during the phase: 252 + 10). The 25 deviations
are the design decisions in book-gaps.md (exact unions, tuple unions,
declared returns), defs analysed without a call (`*args`, generic
ivars), compiler-only rules (lib-fun ivars, `out` ivars), and grammar or
macro limits (`*{…}` literal splats, `spawn`, iterator generics). Six
older inference bugs found on the way are listed as O1–O7.

Measurements (`--release`, vs Phase 7 end): typed locals and block args
93.6% in this repo (89.7%), 71.6% in the stdlib (59.5%); regression diff
repo 0 regressed / 106 improved, stdlib 4 / 627 (the 4 were wrong
`NoReturn`/`Nil` answers, now unknown). Inference time over the stdlib
sample 3.36 s (2.65 s, +27%), this repo 0.74 s (0.60 s): more summary
shapes (exact splat and block-value shapes, abstract dispatch,
captured-local re-solves), and more code is now analysed instead of
skipped. Warm hover and completion unchanged in Neovim (0.1–0.3 ms /
2–7 ms); semantic tokens 4.8 ms on a 635-line file. `make spec`: 208
examples.

Not yet: hover for `x : T` locals reads the flow type after
`y : Bar? = nil` as `Nil` by design (decision 3); editing an `@x = v`
line in a def body rebuilds the DefMap (`Origin::Assigned` items are
declarations); captured-local detection resolves block calls a second
time (bounded by a name pre-check).

### Usage feedback after Phase 8 (done)

Issues found in daily Neovim use (C1–C7), each fixed in its own commit
with a spec and a headless Neovim observation:

- C1 return-type inlay hint rendered inside the parens
  (`def f(a : A : R)`): anchored after the `)`.
- C2 `@|` missed ivars assigned only in a def body: already fixed by the
  Phase 8 ivar rules (`Origin::Assigned`).
- C3 after `:e` (didClose + didOpen) diagnostics vanished: didOpen now
  republishes the last problems of programs already checked. Inlay
  hints of locals typed by compiler facts stayed empty until the client
  asked again: the server sends `workspace/inlayHint/refresh` and
  `semanticTokens/refresh` when facts change.
- C4 `xs.map(&.|)` offered the collection's methods: completion accepts
  implicit-object calls and takes the block argument / case subject.
  Also fixed: `&.a.b` left `b` untyped (repo +17 locals, stdlib one
  wrong `NoReturn` fixed, 0 regressions; book diff unchanged), and
  patched completion copies shared an inference cache key.
- C7 glob `require "./x/*"` hovered/jumped to the first file only.

Deferred: C5 (ivar definition) and C6 (workspace scope) below.

### Phase 9 — workspace identity

- `DefId`-keyed reference index, incrementally maintained.
- Features: workspace references and rename (exact identity only), type
  hierarchy, incoming calls, code actions.

Measured before planning (`tools/probes/refs_probe.cr`, release build):

- **Call resolution is precise enough for exact identity.** Of 12,144
  calls in this repo's 793 defs, 75.1% resolve to one target, 0.6% to
  several runtime targets, 0.7% stay ambiguous, 3.5% name-only, 12.7%
  unresolved (mostly enum predicates like `kind.def?`, generated by
  macros), 7.4% not evaluated (unreachable or nil-only receivers). The
  stdlib sample (6,051 defs) shows the same shape: 75.5% / 0.5% / 1.3%.
- **A full eager index is too slow to build on start.** Inferring every
  body takes 0.78 s for this repo and 4.6 s for the stdlib sample;
  re-running it on each edit is not an option.
- **A name-filtered lazy search is fast.** Searching for a method name
  textually, then inferring only the bodies that contain it, takes
  22–63 ms for names with up to 29 calls (`infer_at`, `def_map`,
  `lookup_path`) and 165–241 ms for very common names (`size` 170 calls,
  `each` 208), cold. Every call of the rare names resolved; `size`/`each`
  had 11–15% unresolved, which become "possible" rather than exact
  references.
- **Positions in the DefMap go stale on body edits (bug).** A body-only
  edit keeps the fingerprint, so the DefMap is not rebuilt, but every
  `Item` range after the edit has moved. After inserting two lines into
  one def, definition of a later method jumped two lines too early,
  hover on its header returned nil, and implementation found nothing.
  References and rename would edit the wrong bytes. Fix first.
- **Per-program views are cheap.** A DefMap over this workspace (486
  files) builds in 4.5 ms and holds ~2.3 MB; one per project view (C6)
  is affordable, and simpler than filtering a shared map's lookups.
- **The compiler gives no help for references.** `crystal tool
  implementations` exists but nothing like a reference query; the
  compiler's "did you mean" text covers only locals.

Decisions:

- **DefId = (file, item path).** The item's index path within its file's
  `ItemTree` (stable across body edits, unlike byte ranges), plus the
  owner `TypeId` from the DefMap. A reopened class has one `TypeId` and
  many sites; a method's identity is its own site, so overloads and
  reopenings stay distinct.
- **References are found on demand, not indexed eagerly.** A per-file
  word index (name → files, built during indexing from the text, kept
  current on edits) narrows candidates; candidate bodies are inferred
  and their resolved targets compared with the DefId. Inference results
  are cached per file revision already. An eager index can come in
  Phase 11 with the persistent cache.
- **Certainty is explicit.** Each reference is exact (resolution
  Unique/MultipleRuntimeTargets containing the def) or possible
  (Ambiguous, NameOnly, or unknown receiver with the same name).
  References return exact ones, plus possible ones only when the client
  asks via `initializationOptions.references.includePossible`. Rename
  uses exact ones and refuses when any possible reference exists, or when
  the declaration is macro-generated, in the stdlib/shards, or an
  operator.

Steps (one commit each):

1. **Fresh positions after body edits.** Re-lower a changed file's items
   on every edit and update the DefMap's sites for that file in place
   when the fingerprint is unchanged (same items, new ranges), without
   invalidating Typing. Spec: definition, hover, implementation after a
   body edit that shifts later defs.
   *Done:* `Index#update` moves the old items to the new positions
   (`Item#move_to`, recursive, params included) instead of replacing the
   entry; the DefMap shares those items and only drops its
   namespace-range cache. No rebuild, Typing kept; summaries are keyed
   by range start and revision, so moved defs get new keys.
2. **Workspace scope (C6).** Root = nearest `shard.yml` above the
   opened file (client root only as fallback); nested projects are
   skipped by the source walk. One DefMap per program view: a project
   (prelude + targets' closures, or `src/` without targets) and each
   loose file or out-of-target script (prelude + its own closure). The
   server picks the view per file. Specs: unrelated `class Item` in a
   sibling project and in a loose file are not definitions of each
   other; a script sees the project's types.
   *Done:* `Index` keeps one set of item trees; `Index::View`s (project,
   nested project, own-file) each build a DefMap over the prelude plus
   their roots' require closure, and the server keeps one Typing per
   map. Root = client root, or the nearest `shard.yml` above it; without
   a `shard.yml` every file is its own program. Stdlib/shard files use
   the project view. Compiler facts apply to the views that contain
   them. `Index#load_missing` now follows requires transitively (a new
   `require` of a file that requires others indexed one level only).
3. **DefIds and the candidate word index.** `Semantics::DefId`, lookup
   site ↔ DefId, and a per-file set of identifier words (from the CST,
   updated per edit). Unit specs.
   *Done:* `Semantics::DefId` (file + item index path; `Index#def_id`,
   `Index#item`). The word index hashes identifier words of workspace
   files from their text (stdlib/shards excluded; 1646 stdlib files
   would cost 0.2 s and 10 MB), refreshed on every update;
   `Index#files_with_word`.
4. **Workspace references.** Methods (calls, def headers, `super`/
   `previous_def` excluded), types and constants (constant paths in
   bodies, restrictions, superclass/include, headers of reopenings),
   from any position (declaration or use). Exact vs possible; local
   bindings keep the current path.
   *Done:* `IDE::References` (target at cursor: def header, call, or
   constant path; search over `files_with_word` candidates that see the
   declaration). Calls count when their resolution contains a target
   site: exact if every viable candidate is a target (or the resolution
   is unique/runtime targets), possible when name-only/unresolved with a
   receiver; possible ones only with `references.includePossible`. Uses
   of `Typing#infer_at` in this repo: all 21 found (probes and scripts
   included, they require the library), none extra; 884 ms cold (infers
   every body of the candidate files), 2 ms warm. `DefMap` (type): 50
   refs, 58 ms cold.
5. **Ivar definitions and references (C5).** Lower `initialize(@x)`
   params to ivar items; definition picks the strongest category
   (declaration, accessor macro, `initialize(@x)`, else every
   assignment); references are `@x` uses in the owner's and its
   subtypes' bodies.
   *Done:* `def f(@x : T = v)` params are ivar items with
   `Origin::Param` (typed like assignments; hidden from document
   symbols); `@|` completion now lists them from any file (the header
   scan is gone). Definition picks source > macro > param > assigned >
   compiler sites of the nearest ancestor that has any. References:
   `@x` tokens of the program's files whose owner (nearest ancestor with
   the ivar) is the target's. Regression diff repo 0/0, stdlib 0
   regressed / 16 improved; book diff unchanged.
6. **Workspace rename.** Methods, types, constants, ivars: exact
   references only; refuse as described above; `prepareRename` explains
   why it refuses. Rename of a type renames every reopening and use.
   *Done:* `References#rename_plan` (locals keep their path; a def name
   wins over the class-body "locals" of accessor arguments). A method
   rename covers its virtual family (the topmost ancestor declaring it
   and every descendant's def of that name), so overrides stay
   overrides. Refuses: operators, macro/compiler-generated declarations
   (including accessor ivars), declarations or uses outside the
   workspace, any possible (unconfirmed) reference, invalid names.
   `prepareRename` returns the refusal as the error message.
7. **Incoming calls and type hierarchy.** `callHierarchy/incomingCalls`
   from method references grouped by enclosing def;
   `typeHierarchy/{prepare,supertypes,subtypes}` from the DefMap
   (superclass, includes, subtypes).
   *Done:* incoming calls are the def's exact references grouped by the
   enclosing def (top-level code as a File item); abstract defs are
   found through virtual calls. Type hierarchy items carry the type's
   full name and a file of the view they come from (`data`), so
   supertypes/subtypes resolve in the same program view.
8. **Code actions.** Measured candidates only. Start with: add a missing
   `require` for an unresolved constant defined in a workspace file;
   "did you mean" for an `undefined method` diagnostic whose receiver
   type has a close name (edit distance ≤ 2).
   *Done (adjusted):* the compiler already prints "Did you mean 'x'?"
   for methods, constants and locals, so the quick fix applies that
   suggestion instead of computing edit distances (checked with Crystal
   1.22: `undefined method 'rendr' for Widget\nDid you mean 'render'?`).
   `undefined constant Foo` offers `require` of workspace files that
   declare `Foo` at the top level (a file only sees what it requires,
   step 2), inserted after the last top-level require. Only diagnostics
   with `source: crystal`.
9. **Verification and docs.** Neovim check `workspace` (references,
   rename, incoming calls, hierarchy, a code action) on a multi-file
   fixture, timings, roadmap/README/architecture.

Exit criterion (design doc): workspace rename does not edit unrelated
same-name symbols.

Status: done (exit criterion met: rename uses exact references only and
refuses when any same-name use is unconfirmed; specs cover a same-name
method of an unrelated class, a same-name class in another program, and
an untyped receiver). Every step landed as planned except step 8, which
reuses the compiler's "Did you mean" suggestions instead of an edit
distance.

Measurements (`--release`, this repo): references cold 53–930 ms
(`DefMap` 53 refs 53 ms; `Typing#infer_at` 21 refs 930 ms, which infers
every body of 21 candidate files), warm 1–16 ms; rename of `DefMap` 53
edits in 15 files 152 ms. `infer_at` and `Infer#type_of` renames are
refused because probes/specs call them on untyped receivers (the
message lists the uses). Neovim `workspace` check: references 577 ms
cold. Coverage unchanged (repo 94.3%, stdlib sample 71.8%); regression
diff vs Phase 8: repo 0 regressed / 22 improved, stdlib 0 / 16 (the
`def f(@x)` ivar items); book diff 527 + 25 accepted, 0 mismatches.
`make spec`: 231 examples.

Not yet: references search one root (Phase 14 multi-root); reference
search is on demand (no persistent index; first search over a large
program infers its candidate bodies); method references inside macro
bodies and `{{...}}` are not found; rename of a method reached through a
`responds_to?`/duck-typed call is refused rather than guessed.

### Phase 10 — responsiveness

The original "hardening" phase is split into three: responsiveness
(here), startup and warm caches (Phase 11), multi-root (Phase 14).

Measured before planning (release build; this repo and Marten, a large
web framework: 1366 own files, 1955 indexed with shards and stdlib):

- **Long requests block everything.** Messages are handled one at a
  time; `$/cancelRequest` is ignored. In Marten a hover sent behind
  references of `Request#method` waited 3.4 s, and the cancelled
  references request was still computed to the end.
- **Memory grows with open spec files.** 250 MB RSS after indexing,
  640 MB after opening 60 spec files, 790 MB–1 GB after one references
  search. Every spec is outside the program's require closure, so each
  gets its own view: a DefMap plus a Typing with an empty summary cache,
  although all 457 Marten specs require the same `spec_helper` (the
  whole framework). A references search creates a view per candidate
  spec (84 for `method`).
- **References over specs stay slow when warm** (1.0 s warm, 3.4 s
  cold for `Request#method`): each spec view infers its bodies again.
- **`prepareRename` runs the whole reference search** (2.5–5.5 s in a
  40,856-request sweep of random positions over 345 Marten files; the
  sweep had 0 internal errors, and 96 answers over 300 ms were almost
  all prepareRename).
- Startup (1.0 s on Marten) and edits that rebuild a DefMap (first
  hover 65 ms, then 30–36 ms) are acceptable for now (Phase 11).

Decisions:

- **Specs are one program, like `crystal spec`.** Spec files
  (`spec/**/*_spec.cr`) that require the same helper form one view;
  specs written to compile together (Marten: 120 files define namespaced
  helper types, two reopen `TestUser`/`Post` from the test project) get
  the same answers the compiler would give. Bounded memory, one shared
  summary cache. Scripts and loose files keep per-file views. Rejected:
  per-file overlay views over a shared base (more precise per file, but
  needs layered DefMaps and summary caches, memory still per spec, and
  diverges from what `crystal spec` compiles).
- **Budgets fail clearly; no partial results.** A request over its
  budget answers with an error naming what was searched (`references for
  'method' stopped after 5 s: 61 of 84 candidate files searched`).
- **Cooperative scheduling on one thread.** Server state is not
  thread-safe; long requests run as jobs on fibers and yield between
  candidate files/bodies, so interactive requests are answered in
  between.

Steps (one commit each):

1. **Marten sweep and soak probe.** Track the random-position sweep and
   a latency/RSS probe as `tools/probes/` scripts against a pinned
   external project (cloned on demand into an ignored directory, not
   committed): internal errors, answers over budget, p50/p99 per method,
   hover latency during a long request, RSS after opening N specs. This
   is the phase's baseline and regression shield.
   *Done:* `tools/external.sh` (Marten pinned at `9c29576`),
   `tools/soak.py`, `tools/sweep.py`, `tools/lsp_client.py`. Baseline:
   index 1.1 s / 208 MB; 100 specs opened 858 MB; after 10 searches
   1823 MB; references `Request#method` 3.5 s cold, 0.8–1.0 s warm;
   hover during that search 3.8 s; cancel ignored (full result 0.9 s
   later). Sweep (120 s, 28,384 requests): 0 errors, 0 timeouts, 78
   answers over 300 ms (77 prepareRename, p99 788 ms, max 3.2 s).
2. **Spec program views.** `Index::View` for each spec helper group:
   roots are all `*_spec.cr` files under `spec/` that require that
   helper (detected from the first `require` of each spec), indexed
   lazily on the first spec opened. Specs: two spec files see each
   other's helper types; a script outside `spec/` keeps its own view;
   memory and references measured with the step 1 probe.
   *Done:* spec files whose first `require` leads (through chained
   per-directory `spec_helper`s) to the same helper form one view;
   support files in `spec/` take the view of the spec program whose
   closure has them. Two more causes of the memory growth surfaced and
   were fixed: Typing objects were evicted once 8 maps existed, so every
   search over spec views re-inferred their bodies; and nested
   `spec/a/spec_helper.cr` chains split Marten into 22 groups. Soak
   (Marten): 100 specs 858 → 300–332 MB; after 10 searches 1823 → 399–428
   MB; references `Request#method` cold 3.5 s → 0.9 s, warm 0.8–1.0 s →
   35 ms; sweep 60 s: 0 errors, 5 answers over 300 ms (was 78/120 s).
   Tried and reverted: evicting disk-loaded VFS states (LRU 128) made
   it worse (re-read files get new revisions, so their inference ran
   again: 550 MB, warm 250 ms).
3. **Cheap `prepareRename`.** Only the static refusals (operator,
   generated, library, invalid position); the reference search moves to
   `rename`, which still refuses on possible references.
   *Done:* `rename_plan(search: false)`; the range is the name token
   under the cursor (constant segment, ivar, method name). Sweep:
   prepareRename p99 788 ms → 0.2 ms, max 3.2 s → 15 ms.
4. **Cancellable jobs.** References, rename, incoming calls (and later
   warm-up) run as jobs with a checkpoint per candidate file and per
   body; `$/cancelRequest` answers `RequestCancelled`; an edit of a file
   a job has read cancels it with `ContentModified`. Interactive
   requests run between checkpoints. Specs with a fake slow finder;
   Neovim check: hover during references.
   *Done:* `LSP::Job` (fiber per request, `Job.current`, checkpoint =
   cancel/budget check + `Fiber.yield`); `References` takes a checkpoint
   callback (per candidate file and per inferred body). An edit of a file
   a job read cancels it; a declaration edit cancels every job (the maps
   are rebuilt). Soak: hover during a cold `Request#method` search p99
   3.8 s → 48–51 ms; `$/cancelRequest` answered in 2–3 ms with
   RequestCancelled (was ignored). Neovim `workspace`: hover during
   references, cancel visible in the server log. Step 5's budgets are in
   the same commit (the job is where they are checked).
5. **Budgets.** Per-request time budgets (references/rename/incoming
   calls 5 s, configurable via `initializationOptions.budgets`) and a
   candidate-file cap; failures say what was covered.
   *Done (with step 4):* `initializationOptions.budgets`
   (`references`/`rename`/`incomingCalls` seconds, `maxCandidates`).
   Over budget: `references stopped after 5.0 s: 61 of 84 candidate
   files searched`; over the cap: ``` `run` appears in 2412 files (limit
   2000); search not run```.
   *Also:* `ClearLS::Memory.trim` (glibc `malloc_trim`) after indexing
   and after jobs. Tree-sitter's libc allocations freed by parallel
   parse workers stayed in per-thread arenas: on Marten 130 of 234 MB
   RSS right after indexing. Soak RSS: index 234 → 121 MB, 100 specs
   324 → 214 MB, after 10 searches 421–441 → 277 MB.
6. **Verification and docs.** Probe numbers before/after, `make
   nvim-check`, README.

Exit criteria (Marten, measured by the step 1 probe): hover answers in
< 100 ms p99 while a references search runs; RSS stays under ~400 MB
after opening 100 specs and running 10 searches; no request exceeds its
budget without a clear error; the sweep has 0 internal errors.

Status: done; every exit criterion met.

| Marten (`tools/soak.py`, `tools/sweep.py`) | before | after |
|---|---|---|
| RSS after indexing | 208 MB | 91–121 MB |
| RSS after 100 specs | 858 MB | 190–214 MB |
| RSS after 100 specs + 10 searches | 1823 MB | 277–278 MB |
| references `Request#method` cold / warm | 3.5 s / 0.8–1.0 s | 0.94 s / 39–51 ms |
| hover p99 during a cold search | 3.8 s | 37–51 ms |
| `$/cancelRequest` | ignored (full result) | RequestCancelled in 2–16 ms |
| sweep answers over 300 ms (120 s) | 78 (77 prepareRename) | 1 |
| prepareRename p99 / max | 788 ms / 3.2 s | 0.2 ms / 15 ms |
| sweep internal errors / timeouts | 0 / 0 | 0 / 0 |

This repo: references warm 2–13 ms, cold 37–930 ms; rename of `DefMap`
54 edits in 15 files 118 ms. `make spec` 235 examples; book diff 527 +
25 accepted, 0 mismatches; `make nvim-check` unchanged plus hover during
references (answered first) and a cancelled job in the `workspace`
check.

Not yet: the remaining slow first answer is cold inference (a hover
1.1 s on the first body of a fresh view in the sweep; first
`Request#method` search 0.94 s), which Phase 11's warm-up addresses.
`include Mod` at the top level was not followed (fixed in the round
below).

### Fix round after Phase 10: top-level `include` (done)

Found while verifying Phase 10 references (and noticed in use before).
Two lookup bugs, both against the compiler's `path_lookup.cr`:

- **File-level code was analysed inside the first type of the file.**
  The file body's namespace was `namespace_at(0)`, which a type declared
  on the first line covers: in a file starting with `module App`,
  top-level `Item.new` typed `App::Item` where the compiler reports an
  undefined constant. File bodies now use the program, and constants
  and types are looked up at each expression's own namespace
  (`Infer#type_body_ns`), which also typed class-level ivar declarations
  like `@ops = [] of Op` (looked up at the top level before).
- **Top-level `include`/`extend` were dropped.** The compiler makes the
  module an ancestor of the program (`@top_level.ancestors == [Outer]`):
  its types, constants and instance methods are visible everywhere
  (top-level code, defs, other classes' methods), its class methods are
  not; the program's own declarations win, then the last include.
  The stdlib's spec DSL relies on it (`include Spec::Methods`,
  `include Spec::Expectations`), so `describe`/`it`/`eq`/`be_nil` were
  unresolved in every spec file. Now `ItemTree#mixins` (part of the
  fingerprint) → program include/extend refs → `ancestors(PROGRAM)`;
  `top_level_sites` and bare-identifier completion walk them.

Measurements: book fixture `toplevel_include.cr` 13/13 match (book
total 540 + 25 accepted of 565, 0 mismatches). Receiverless calls in
spec files unresolved: this repo 1227/1799 → 50/1807 (locals typed 58%
→ 92%), Marten 23,756/25,102 → 1,589/25,102. Regression diff (file
bodies included): repo, specs, probes, stdlib, Marten 0 regressed (spec
+320, probes +73, Marten +52). Marten soak still meets the Phase 10
exit criteria (hover p99 during a search 55 ms, RSS 278 MB; the first
`Request#method` search 0.94 → 1.13 s since spec bodies now resolve);
sweep 0 errors. Neovim `workspace`: spec-file hover/definition/
completion of the DSL.

Also in this round, from usage: **go to definition on an alias use
site jumped to the alias target** (`def foo : Env?` with `alias Env =
Hash(...)` opened `Hash`). Navigation now resolves paths with
`DefMap#lookup_path_raw` (aliases not followed); definition, hover,
references and rename of `Env` work on the alias, and its own
definition leads on to the target. Inference keeps `lookup_path`
(through aliases): regression diff 0 changed types.

### Phase 11 — startup and warm caches

Design and measurements: [persistent-cache.md](design/persistent-cache.md).
Marten today: `Index#load` 1.1 s for 1955 files (stdlib 460, shards 149,
project 1346); decoding all their item trees from a binary pack takes
15–25 ms, and statting every file ~10 ms.

- **Parallel work-queue indexing.** Workers pick up newly discovered
  requires instead of waiting for each round. Measured ceiling on
  Marten: 1044 ms (8 workers, rounds) → 505 ms (one flat batch).
- **Persistent cache in two layers.** Global
  (`$XDG_CACHE_HOME/clear-ls/`): item trees of the stdlib, one pack per
  Crystal version and stdlib path, and of each shard version.
  Project-local (`.clear-ls/cache/`, ignored by its own `.gitignore`):
  project files, path dependencies, resolved requires, word sets and
  compiler facts. Entries are checked by size and content hash. Packs
  carry a build key (`ClearLS::VERSION`, schema, grammar ABI). Custom
  binary format with a string table, written atomically.
- **Background warm-up** (idle, lowest priority, cancellable via the
  Phase 10 jobs): infer workspace bodies once so the first references
  search is warm.
- **Allocator measurement** (open since Phase 0): Boehm heap vs RSS vs
  libc for Tree-sitter under the Marten soak; keep or change
  `-Dcrystal_tree_sitter_no_init`.

Steps (one commit each):

1. **Version and measurement.** Bump `ClearLS::VERSION` to 0.10.1 for
   the fix round after Phase 10 and start the version workflow
   ([development.md](development.md#versions)). Add a startup probe that
   splits `Index#load` into stat/read, parse+lower, require resolution
   and DefMap build, so each later step has a baseline.
2. **Stable hashes.** `String#hash` is seeded per process. A fixed
   64-bit hash (FNV-1a or xxHash64, written in clear-ls, no new library)
   for `ItemTree#fingerprint`, `Index.words` and `CompilerFacts`
   digests. Spec: same value in two processes.
   *Done:* `ClearLS::StableHash` (XXH64, seed 0; vectors from
   `xxhsum -H64`, plus a spec that runs it in a second process).
   Word sets on Marten 137–144 ms (was 127–154). 0.10.2.
3. **Work-queue indexing.** One worker pool with a shared queue; newly
   resolved requires are queued as soon as they are found.
   *Done:* `Index#index_files`. Workers also resolve requires and collect
   word sets (both were serial, ~210 ms on Marten); the main fiber only
   adds entries and queues new paths. Marten load 1040–1100 → 720–820 ms
   (startup probe; 8, 12 or 16 workers within noise, 4 workers ~1 s),
   soak index 1.13–1.17 → 0.83–0.87 s; index RSS 130–135 MB (old build
   91–160 MB across runs). This repo 670–800 → 400–630 ms. Still above
   the 505 ms one-batch ceiling: parsing is CPU-bound (3.5 s user over
   8 workers), so the cache is what gets below 300 ms.
4. **Codec.** `Cache::Pack` reader/writer (header, string table,
   directory, payloads, checksum) for `ItemTree`. Round-trip spec over
   the stdlib and a fixture project: equal fingerprints and
   `dump-items`. Corrupt/truncated packs read as missing.
   *Done:* `Cache::Writer` / `Cache::Pack` / `Cache::Reader`
   (`src/clear_ls/cache/pack.cr`), `Cache::BUILD_ID` from
   `tools/build_id.sh` (commit, digest of uncommitted `src/` changes,
   grammar commit). The round-trip spec compares every instance variable
   by macro, so a field missing from the codec fails it (checked by
   dropping `extends`). Marten, all 1955 trees in one pack: 5.9 MB
   (string table 2.8 MB, two thirds of it docs; payloads 2.9 MB),
   encode 89 ms, read + decode 23–27 ms. 0.10.3.
5. **Global layer.** Stdlib and shard packs; lookup by pack key, use of
   an entry only on size + hash match; merge-and-rename when a project
   needs new files; eviction. Spec: two projects share the stdlib pack;
   a patched file in `lib/` is re-parsed.
   *Done:* `Cache::Store` (`src/clear_ls/cache/store.cr`), used by
   `Index#store` (not yet by the server: step 6). Workers look trees up
   by size + `StableHash` of the text; misses are recorded and flushed
   after `#load` (old entries + new, atomic rename); packs are touched
   on use and evicted after 30 days. Shards come from
   `lib/.shards.info`, skipping `path:` and symlinked ones. Marten:
   stdlib pack 3.5 MB, shards 68 KB–512 KB; startup probe with
   `CACHE=` cold 913 ms (writes packs), warm 551–726 ms, 609 hits — the
   1346 project files are still parsed.
6. **Local layer and controls.** Project pack with resolved requires,
   word sets, path dependencies and the pack list; `.clear-ls/.gitignore`;
   `--no-cache`, `initializationOptions.cache`, `clearLs/clearCache`,
   `clear-ls cache info|clear`. Persist the compiler facts snapshot per
   entry point and apply it at start (digest rule as today).
   *Done:* `Cache::Local` (`src/clear_ls/cache/local.cr`): entries by
   size + mtime (ns), so a hit doesn't read the file; word sets in the
   payload; requires are still resolved on load (globs and new files;
   ~7 ms on Marten across workers). Dropped files are pruned on flush.
   Facts: `facts.pack`, written after each check, restored on
   `initialized` before the first check. The pack key is the Crystal
   version, target and `CRYSTAL_PATH`. `clear-ls lsp` enables the cache;
   `Server#cache_enabled` is off for embedders and specs. Marten through
   the server (compiler off, `index ready` log): cold 976 ms (writes
   packs), warm 213–227 ms, first `workspace/symbol` answered 233–247 ms
   after `initialized`; local pack 2.2 MB. 0.10.4.
7. **Background warm-up.**
   *Done:* `src/clear_ls/lsp/warmup.cr`: after indexing, a fiber infers
   every body of the workspace files, one per step, only after 300 ms
   without messages and with no job running; a declaration change
   restarts it. On for `clear-ls lsp` (`initializationOptions.warmup`).
   What it keeps is the point: a kept `Infer` per body cost 460 MB on
   Marten (RSS 772 MB), summaries alone left the first search at
   600–740 ms (re-inferring 185 candidate bodies, 86% of it spec files'
   file bodies). So `Typing#call_facts` stores per call only name range,
   resolution kind and target keys (89k calls), and the reference
   search reads those instead of `Infer#resolutions`. `tools/warm.py`
   on Marten: warm-up ~7.5 s idle, RSS 300 MB, first `Request#method`
   search after it 88 ms (cold 1340 ms, warm 36–44 ms). References on
   150 sampled Marten defs: identical to the previous build (664 refs).
   Soak: RSS after 100 specs + 10 searches 239 MB (was 277), hover p99
   39 ms; sweep 0 errors, 0 over 300 ms. `soak.py`/`sweep.py` turn the
   warm-up off (Phase 10 numbers are of a cold server). 0.10.5.
8. **Allocator measurement.**
   *Done:* keep `-Dcrystal_tree_sitter_no_init` (libc malloc). Same
   commit built both ways (`make release CRYSTAL_FLAGS=` for Boehm),
   Marten:

   | | libc (kept) | Boehm |
   |---|---|---|
   | cold index (soak, `--no-cache`) | 0.82–0.84 s, 127–129 MB | 2.06 s, 110–112 MB |
   | after 100 specs | 217–218 MB | 168–169 MB |
   | after 100 specs + 10 searches | 237–244 MB | 258–263 MB |
   | hover p99 during a cold search | 70–80 ms | 76–86 ms |
   | cold start writing the cache (`warm.py`) | 857 ms | 2225 ms |
   | warm start | 237–254 ms | 239 ms |
   | RSS after background warm-up | 300 MB | 380 MB |

   Boehm is lower only while specs are parsed and kept open, and loses
   that once searches or the warm-up run; it is 2.5× slower to parse
   (parallel workers contend on the GC lock). With the cache, cold
   parsing happens once per change, but the first start and every
   Crystal or clear-ls upgrade still pay it.
9. **Verification and docs.** Soak, sweep, `make nvim-check`, README.
   *Done:* `tools/warm.py` (criteria below), `cache` Neovim check (two
   sessions on one copy), README/architecture/gotchas/tools docs; 0.11.0.

Exit criteria: Marten warm start < 300 ms; the first references search
after warm-up matches warm time; cache invalidation specs (file edit,
patched shard file, Crystal upgrade, clear-ls version bump, deleted file,
corrupt pack); facts from the previous session are applied before the
first check.

Status: done; every exit criterion met.

| Marten | before | after |
|---|---|---|
| start to first answer, warm cache (`warm.py`) | 1.1–1.2 s (no cache) | 237–254 ms |
| cold index (soak, `--no-cache`) | 1.13–1.17 s | 0.82–0.84 s |
| first references `Request#method` after warm-up | 1.34 s (cold) | 88 ms (warm 36–44 ms) |
| RSS after warm-up | — | 300 MB |
| RSS after 100 specs + 10 searches (soak) | 277–278 MB | 234–244 MB |
| hover p99 during a cold search | 37–55 ms | 38–80 ms |
| sweep (60 s) internal errors / over 300 ms | 0 / 1 | 0 / 0 |

Invalidation specs: `spec/cache/` (round trip of every field, corrupt/
truncated/foreign packs, shared stdlib/shard packs, patched shard file,
new stdlib files, other Crystal version, eviction) and
`spec/features_phase11_spec.cr` (second session from the cache, edited/
new/deleted files, corrupt pack and other build, Crystal upgrade,
disabled cache, `clearLs/clearCache`, facts before the first check,
warm-up idle/restart). `make spec` 261 examples; book diff unchanged (0
mismatches); references on 150 sampled Marten defs identical to the
pre-warm-up build; `make nvim-check` unchanged plus `cache`.

Not yet: requires are resolved on every start; cached facts can be
stale until the first check when the file that caused them changed
while the server was off; the warm-up covers the project view's
workspace files, not shard sources (references into shards are rare and
refused by rename).

### Phase 12 — editing UX and feature gaps

From usage feedback on Phase 11 (`../clearls-feedback.md`, items F1–F6
below; the file numbers them C1–C6, renamed here to avoid confusion
with the post-Phase-8 C1–C7). Each finding was checked against 0.11.0
first.

**Measured / reproduced (0.11.0):**

- **F1 accessor references.** For `property name = "foo"`, references
  from the `name` in the declaration give only `item.name` reads; from
  `item.name = ...` they give nothing; prepareRename refuses ("defined
  by a macro"); hover on the declaration says "local variable" (the
  class-body argument lowers to a local). Definition from a use already
  jumps to the declaration.
- **F2-1 `()` on completion.** clear-ls sends no `insertText`: the
  parentheses come from the client. blink.cmp's auto-brackets add `()`
  to every `Method`/`Function` kind item unless the filetype is
  blocked: `ruby` is blocked by default, `crystal` is not
  (`completion.accept.auto_brackets.blocked_filetypes` changes that).
  So accessors get `name()` too.
- **F2-2 setters.** `item.nam` lists `name` and `name=`; accepting
  `name=` inserts `name=` (valid Crystal only as `item.name=(v)`).
  Crystal also accepts `&.name = "y"` (checked with the compiler) and
  `&.+ 1`, `&.[0]` short blocks. Operators complete as plain labels
  (`+` after `a.` inserts `a.+`).
- **F2-3 blocks.** No block snippets. In the stdlib, 35 of 71 public
  `Enumerable` methods take a block in every overload (`each`,
  `compact_map`, `find`, ...), 21 only in some (`select`, `count`,
  `first`, `index`, ...); `Array#map`, `sort_by` always do.
- **F3 settings.** Every option is under `initializationOptions`
  (`compiler`, `references`, `budgets`, `cache`, `warmup`); there is no
  `workspace/didChangeConfiguration`, no inlay-hint switches, and the
  options are spread over README and comments.
- **F4 CLI errors.** `dump-items /nope.cr` prints `File::NotFoundError`
  with a stack trace; `dump-hir FILE abc` an `ArgumentError` trace.
  `unknown command` and missing arguments are already clean.
- **F5 block form conversion.** No code actions besides compiler quick
  fixes.
- **F6 alias in inlay hints.** `l = item.list` with `def list : Names`
  (`alias Names = Array(String)`) hints and hovers `Array(String)`. The
  compiler also reports `Array(String)` (`typeof`, `tool context`):
  aliases are expanded during typing. The alias name is only known
  where it was written: a restriction or return type.

**Design decisions** (reviewed; "decided" marks the user's choices):

1. **Accessor identity (F1).** One accessor declaration is one symbol
   with up to three members: the getter (`name`, `name?` for `property?`
   / `getter?`), the setter `name=`, and the ivar `@name`. References
   from the declaration's name, from any generated method's use, or
   from `@name` inside the class return the same set: every read call,
   every `x.name = v` / `x.name += v` call (the setter, also through
   `&.name = v`), every `@name` use in the owner and its subtypes, and
   the declaration. A `def name=` written by hand next to a `getter`
   joins the set only through its own name (it is a different def).
   Rename renames all of them consistently (`name` → `title` rewrites
   `name=`, `@name`, `name?`, the declaration). `record` fields work the
   same; named arguments `Point.new(x: 1)` are renamed too, positional
   ones need nothing. Refused for accessors generated by unknown macros
   (compiler facts) as today. Hover on the declaration shows the
   generated signatures, not "local variable".
2. **Completion shapes (F2).** Server-side, client-agnostic:
   - Parentheses (F2-1, decided): the server keeps inserting plain
     names (no `(`); the `()` comes from the client. The fix is a
     documented Neovim setup: blink.cmp
     `completion.accept.auto_brackets.blocked_filetypes = { "crystal" }`
     (as blink does for Ruby; disables both its kind and its semantic
     token bracket checks), so `puts "foo"` style works. No server
     setting, no item-kind change.
   - Setters: the `name=` item inserts `name = ` (one space, cursor
     after) through a `textEdit`; in `&.` blocks the same (`&.name =
     ` is valid). Its label stays `name=`, with `filterText` `name`
     so typing `nam` keeps both visible. Operators after `.` insert
     ` + ` with the dot removed (`a.` + `+` → `a + `) via a text edit
     over the dot; index operators insert `[$1]`; unary ones keep the
     method form. `&.+` keeps `&.+ ` (valid short block).
   - Blocks: only for methods whose **every** overload takes a block
     (or that resolve to a block overload already), insert
     `map { |${1:x}| $0 }` with block parameter names from the def's
     `yield`/block restriction when known (`each_with_index { |${1:x},
     ${2:i}| }`, names from the signature's block type arity); a
     parameter without a usable name is a placeholder (`${1:x}`,
     decided). Braces by default (a one-line form the cursor can
     finish in place; `do ... end` needs a new line and indent);
     `completion.blockStyle: "do"` switches. Mixed overloads
     (`select`, `count`) get no block: the bare name is never wrong. After `&.` no block snippets.
     Solargraph and ruby-lsp complete method names only (ruby-lsp adds
     block pipes on typing `do`, not in completion), so there is no
     common convention to follow; ours are opt-out
     (`completion.blockSnippets: false`).
3. **Settings (F3).** One schema, read from `initializationOptions`
   and from `workspace/didChangeConfiguration` (`settings.clearLs`),
   with the existing keys kept. New keys: `inlayHints.{locals,
   blockParams, returnTypes, aliases, enabled}`, `completion.{blockSnippets,
   blockStyle, setterSnippets}`.
   Documented in one place (`docs/settings.md`) generated from the
   schema in code (`LSP::Settings`), so docs and defaults cannot drift;
   a spec checks the doc is current.
4. **Aliases in hints (F6).** The display remembers where a type was
   written as an alias (same identity for compatibility and overloads,
   a display name for printing). The tag comes from written
   restrictions and return types and survives inference joins when
   every joined value carries it (decided):

   ```crystal
   alias Names = Array(String)
   def find_names(ok : Bool) : Names?; ...; end
   def names : Names; ["a"]; end
   a = find_names(true)          # Names?
   b = rand > 0.5 ? names : nil  # Names?
   c = rand > 0.5 ? names : ["b"] # Array(String): tagged meets untagged
   d = rand > 0.5 ? names : 1    # Names | Int32
   ```

   The compiler prints `Array(String)` everywhere (aliases are expanded
   in typing): this is display only. Hover shows both (`a : Names?` and
   `= Array(String)?`). `inlayHints.aliases: false` restores the
   expansion.
5. **Block conversion (F5).** In this phase, as a refactoring code
   action over the block under the cursor: `{ |x| ... }` ↔ `do |x| ...
   end`, reindented with the surrounding line's indent, refused when
   the `{` form would change binding (a `do` block passed to a call
   without parentheses whose last argument is itself a call:
   `foo bar do ... end` binds to `foo`, `foo bar { }` to `bar`). The
   other conversions (`&.x` ↔ `{ |x| x.x }`, `if`/`unless` ↔ suffix)
   are listed but left for a code-action phase.

Steps (one commit each; patch version bump where it touches lowering,
the exporter or the cache):

1. **Settings schema and CLI errors (F3, F4).** `LSP::Settings` with
   defaults, validation (unknown key → one warning in the log),
   `initializationOptions` + `didChangeConfiguration`; existing options
   moved onto it unchanged. `docs/settings.md` from the schema plus a
   spec that it is current, with a Neovim section (recommended
   `vim.lsp.config` and blink.cmp `auto_brackets` setup, F2-1). CLI: unreadable files, bad numbers and
   unknown options print `clear-ls: <message>` and exit 2, no trace
   (`--log-level debug` keeps the trace).
   *Done:* `LSP::Settings` (`src/clear_ls/lsp/settings.cr`): one key
   table for defaults, type checks, change tracking and the generated
   `docs/settings.md` (`clear-ls settings-doc`; spec fails when stale).
   `Server#settings`; `cache_allowed`/`warmup_allowed` say what the host
   permits (`clear-ls lsp` both). Keys of later steps join the table in
   their step. CLI: `CLI.main` turns `UsageError`, file errors and option
   errors into `clear-ls: message` (exit 2; I/O failures exit 1, trace
   only with `--log-level debug`); LINE range checked. `spec/cli_spec.cr`
   runs the binary (`make spec` builds it).
2. **Inlay hint switches (F3).** `inlayHints.enabled`, `.locals`,
   `.blockParams`, `.returnTypes`; refresh hints on change when the
   client supports `workspace/inlayHint/refresh`.
   *Done:* `IDE::InlayHintKinds`; settings `inlayHints.{enabled, locals,
   blockParams, returnTypes}`; a change sends only
   `workspace/inlayHint/refresh`.
3. **Accessor symbol (F1).** `Items` links the members generated by
   one accessor call (getter, `?` getter, setter, ivar) to the call's
   name range; references/highlight/rename/hover go through it; setter
   calls (`x.name = v`, `x.name += v`, `&.name = v`) resolve to the
   setter. Specs for `getter`, `setter`, `property`, `property?`,
   `property!`, `class_property`, `record` and a hand-written `name=`.
   *Done:* `IDE::AccessorTarget`: macro-generated members sharing one
   name token (getters, `?` getter, setter, ivar; `record`'s
   `initialize` for named `new` arguments). `target_at` lifts a member
   target into it; references search each member (setters by their base
   word), rename edits the base name inside each reference
   (`name?`, `name=`, `@name`). Fixes found on the way: `x.name = v` /
   `x.name += v` resolved `name=` with no argument (NameOnly) — the
   setter now gets the value (`Infer#setter_value`); `&.name = v` parses
   with an ERROR node (grammar notes) and lowers to `name=`; `Foo.new`
   without `self.new` records its resolution and `initialize_resolution`
   (named args → record fields). Hover on the declared name shows the
   generated defs. Types regression diff (repo, stdlib, Marten):
   0 regressed, 0 improved (1 union reordered); book diff 0 mismatches.
   A hand-written `def name=` beside a `getter` stays a separate
   method. 0.11.1.
4. **Setter and operator completion (F2-2).** Setter and operator text
   edits, `filterText`; capability checks (`snippetSupport`). Verified
   in a headless Neovim check with the built-in completion.
   *Done:* `Completion#shape_member`, `CompletionOptions`; setting
   `completion.setterSnippets` (default on). Unary-only operators (`!`,
   `~`) and `&.` short blocks keep the call form; `[]` becomes `[$1]`
   with snippet support. Neovim check `editing` runs each response
   through `vim.lsp.completion._convert_results` and applies the item.
   Found on the way: items sent optional fields as `null`
   (`"textEdit": null`), which crashes Neovim's built-in completion
   (`adjust_start_col` indexes it); fields are now omitted. 0.11.2.
5. **Block snippets (F2-3).** Every-overload rule, parameter names from
   the block type (`&block : T, Int32 ->` → 2 params; names from the
   def's `yield` call arguments when they are locals with names, else
   `x`/`i` style placeholders), `blockStyle`. Spec over the stdlib:
   no snippet for a method with a non-block overload.
   *Done:* `Completion#with_block`, `Typing#block_param_names` (arity from
   `& : T, U ->` / `(T, U) ->`, else the first `yield`; names from plain
   identifier `yield` arguments, else `x`, `y`, ... placeholders).
   Settings `completion.blockSnippets`, `completion.blockStyle`
   (`braces` | `do`). Not after `&.`, nor before an existing `{`, `(`,
   `do`; only with client `snippetSupport`. Stdlib spec: every
   completed `Array`/`Hash`/`String` method (>150) gets a block exactly
   when every public overload takes one. In Neovim (`editing` check, via
   `vim.snippet`): `items.ma` → `items.map { |x|  }` with `x` selected;
   `items.selec` → `items.select`. 0.11.3.
6. **Aliases in hints and hover (F6).** Alias-tagged types, printing,
   `hover`/inlay rules above; regression diff (`types_diff.py`) must
   show only display changes (identity unchanged: `book_diff.py` 0
   mismatches).
   *Done:* as a display layer, not in the type table:
   `IDE::AliasDisplay` derives per-member alias spellings from written
   types (call return types, param restrictions, `x : T`) and carries
   them through assignments, reads, `if`/`unless`/`||`/`&&` joins and
   narrowing, dropping a spelling when a joined value lacks it. Inference
   and type identity are untouched (types regression diff 0 changed;
   book diff 0 mismatches), so no interning change was needed. The
   decided examples are a spec. Only whole union parts are spelled
   (`Names`, `Names?`, `Names | Int32`), not aliases inside generic
   args. Setting `inlayHints.aliases` (hints and hover). Warm inlay
   hints over 4 large repo files: 24 ms vs 23 ms without; the repo
   now hints `: Env` in `infer.cr`. 0.11.4.
7. **Block form code action (F5).** `{}` ↔ `do end` with the binding
   check; round-trip spec (convert twice = original, modulo
   whitespace) over every block of the stdlib that converts.
   *Done:* `IDE::BlockForm` (`ide/block_form.cr`), served as a
   `refactor.rewrite` code action (a `disabled` action with the reason
   when refused). Binding rules checked with the compiler: braces → do
   refused inside an unparenthesized argument list (`foo bar { }`),
   except operator calls (`xs << ys.map do ... end` binds the same) and
   short blocks (`x.try &.each { }`); do → braces refused when the
   unparenthesized last argument (or a named argument's value) is a
   call, a bare name or a constant (`record Foo {` is a `Foo{}`
   literal). Also refused: `rescue`/`else`/`ensure` in a `do` block,
   and `do` bodies that declare defs/types (macro bodies). Comments keep
   the block multi-line. Proc literals (`-> do end`) convert freely.
   Full stdlib run (`BLOCK_FILES=9999 BLOCKS_PER_FILE=9999`): 5195
   blocks, 5109 converted and round-tripped (each result re-parses
   without errors), 86 refused; the default spec samples 120 files.
   0.11.5.
8. **Verification and docs.** Neovim checks for F1–F6, README feature
   list, settings doc linked from README, status.
   *Done:* Neovim `editing` check covers F1 (references and rename from
   `item.name =`), F2 (accepted completions), F5 (code action applied)
   and F6 (`18: Names`); F3 via `didChangeConfiguration` specs. 0.12.0.

Exit criteria: references/rename from any accessor member give the
same set (spec over the accessor macros); the documented blink.cmp
setup completes `puts` and accessors without `()`; accepting `name=`
yields `x.name = |`; block snippets only
for every-overload block methods (stdlib spec); every setting
documented and live-reloadable; CLI errors without traces; an alias
return type shows its name in hints; `{}` ↔ `do end` round-trips.

Decided after review: no server-side bracket handling (F2-1, Neovim
docs instead); placeholders for unnamed block parameters; aliases
survive joins of tagged values only.

Status: done; every exit criterion met.

- F1: one reference set from the declaration, a getter use, a setter
  use, `&.name =` and `@name` (spec over `property`, `getter?`,
  `getter!`, `class_property`, `record`); rename rewrites all members.
  On 150 sampled Marten defs, references only gained (664 → 679: setter
  calls such as `conf.root = "files"` were missed before).
- F2: Neovim `editing` check (built-in completion's conversion):
  `item.name`, `item.name = `, `items.each &.name = `, `item + `,
  `puts`, `items.map { |x|  }`, `items.select`; stdlib spec for the
  block rule (>150 methods). blink.cmp setup documented.
- F3: `docs/settings.md` generated and checked by a spec;
  `didChangeConfiguration` applies everything not marked *restart*.
- F4: CLI errors are one line (spec runs the binary).
- F5: 5109 of 5195 stdlib blocks convert and round-trip, 86 refused
  with a reason.
- F6: the decided alias examples are a spec; types regression diff 0
  changed.

Also measured: Marten soak unchanged (hover p99 during a search 39 ms,
RSS after 100 specs + 10 searches 255 MB), sweep 0 errors / 0 over
300 ms, `warm.py` warm start 231 ms and first search after warm-up
89 ms; `make spec` 287 examples (~40 s; the block round trip samples
120 stdlib files); book diff 0 mismatches.

Found and fixed on the way: setter calls (`x.name = v`) resolved to
nothing; `Foo.new` without `self.new` recorded no resolution; completion
items carried `null` fields that crash Neovim's built-in completion.

Not yet: block parameter names come from plain `yield` arguments only;
other code actions (`&.x` ↔ `{ |x| x.x }`, suffix `if`) are for a
code-action phase.

### Fix round after Phase 12: aliases inside generics (done)

From usage: with `alias Id = Int32 | String`, `id = foo.id` hinted `Id`
but `xs = [] of Id` hinted `Array(Int32 | String)` and `x = xs.first`
`Int32 | String`. Phase 12 tagged only whole union parts and only
written return types. Now a tag names any type node at any depth
(`Array(Id)`, `Hash(String, Id)`, `{String, Id}`), comes also from
`[] of T` / `{} of K => V` and element values, and flows from a call's
receiver and arguments into its result and into block parameters
(their *inner* spellings: `names.map { }` builds a plain
`Array(String)`, not a `Names`). The feedback's snippet now hints
`Id`, `Array(Id)`, `Id`; `h["a"]?` → `Id?`, `h.to_a` →
`Array({String, Id})`, `group_by` → `Hash(Bool, Array(Id))`, an
untagged `[1, "a"]` stays `Array(Int32 | String)`. Approximation: a
tag covers every occurrence of its node in one value. Assignments and
blocks are indexed once per body (warm hints over 4 large files 28 ms,
23 ms with aliases off). Types diff 0 changed. 0.12.1.

### Hover and definition on type parameters (done)

Researched on 0.12.1, implemented in 0.12.2 (results at the end).

**Today:** for `class Box(T)`, `def map(& : T -> U) : Box(U) forall U`,
`def first_of(xs : Array(E)) : E forall E`, `struct Pair(K, *V)`, all
15 positions tried return no hover and no definition (declaration,
`@value : T`, param and return restrictions, proc types, `T.class`, `T`
as a value in a body, `forall` lists, splat params). Semantic tokens
already mark the declaration in `class Box(T)` as `typeParameter`, not
the uses. Worse: a parameter that shadows a type (`class Key; end` +
`class Store(Key)`) resolves `k : Key` to the outer `class Key`; the
compiler uses the parameter. Stdlib: 115 generic types, 473 uses of
`forall` variables.

**Scoping rules** (checked with Crystal 1.22):

- A type's params are visible in its body, defs and class methods
  (`def self.k : T.class`), including reopenings without params
  (`class Box` after `class Box(T)`); a reopening must use the same
  names (`class Box(U)` is an error).
- Nested types don't see them (`Outer(T)::Inner` → undefined `T`).
- `forall T` on a def shadows a type param `T`.
- A param shadows a constant of the same name (`class T; end` +
  `class Box(T)`: `T` inside is the param).
- Module params are the module's (`module M(T)` with `include M(Int32)`
  is bound per includer: not knowable at the declaration).

**Plan (low cost, one step).** A resolver
`Analysis#type_param_at(offset)` before `resolve_path_at`, for a
`constant` node with a single segment:

1. The enclosing def's `forall` list (CST: `method_def.forall`) → that
   def's declaration token.
2. Else the type params of the innermost enclosing type
   (`namespace_at` → `DefMap` info `type_params`) → the token in the
   header of the reopening that declares them (`class_def` name's
   `generic_type` params; the first site with params, else the
   reopening the cursor is in).
3. Else nothing (fall through to constants, as today).

What each feature gets:

- **definition:** the declaring token (`T` in `class Box(T)` or `U` in
  `forall U`).
- **hover:** `T` with its role: ``type parameter of `Box(T)` `` or
  ``free variable of `map` (`forall U`)``, plus what it's bound to
  where known: in a body under inference, hover the def's `self`
  instantiation (`Box(Int32)`: `T = Int32`) when the receiver of the
  enclosing call fixes it — only when cheap (the def's `Infer` context
  already has `self_type`); otherwise just the role.
- **semantic tokens:** uses also get `typeParameter` (same resolver), so
  they stop looking like class names.
- **document highlight:** every use of the same param in its scope
  (walk the scope's `constant` nodes with that text: same resolver).
- **references/rename:** local to the type or def (like locals),
  cheap through the same walk. Rename must cover every reopening's
  header for type params (the compiler requires equal names), so do
  references/highlight first and leave rename for when asked.
- **Fix:** `resolve_path_at` and `Infer` already parse restrictions
  with the type params known (`DefContext` type params), so inference
  is right; only the IDE path resolution has the shadowing bug, and the
  resolver order above fixes it.

Out of scope (higher cost): the per-call bound value at an arbitrary
use site (`T = Int32` inside `Box(Int32)#get` when reached from a
specific call needs call-site context); module params per includer.

Specs: every position above for hover and definition, the shadowing
case, nested type (no param), `forall` shadowing, reopening without
params, splat param `*V`, and highlight. Estimated size: one resolver
(~80 lines) plus four small call sites.

*Done:* `IDE::TypeParams` (`ide/type_params.cr`): a CST walk up from
the constant (enclosing def's `forall`, then the innermost type decl's
header, then the type's other declarations for reopenings). Used by
`Analysis#definition`/`#hover` (before constant resolution, so
`class Store(Key)` no longer resolves to `class Key`: references of the
class skip the param's uses), document highlight (uses in the file,
read kind), and semantic tokens (uses now `typeParameter`). Hover says
``type parameter of `Box(T)` `` or ``free variable of `map` (`forall
U`)``. Semantic tokens keep a scope stack during their walk instead of
asking each constant for its ancestors (Tree-sitter `parent` is
O(depth): the first version made tokens 1.6× slower); stdlib
`array.cr`/`hash.cr`/`enumerable.cr` 6.4/5.3/5.8 ms vs 6.7/5.5/6.3 ms
before. Stdlib checks: `Enumerable#first : T`, `Hash#merge`'s `K`,
`L`, `W`. Spec `features_type_params_spec.cr`. Not done: references and
rename of a param (rename must change every reopening's header),
bound values per call site, module params per includer. 0.12.2.

### Phase 13 — keyword snippets and require completion

From usage feedback on 0.12.2: built-in snippets for common structures
(definitions, control flow, `do ... end`) and completion inside
`require "..."`. Runs before Phase 14 (multi-root), the last phase.

**Today (0.12.2):** keywords complete as bare labels (`KEYWORDS` in
`ide/completion.cr`, sort tier `3`). The only snippets are block
snippets after `x.` (`completion.blockSnippets`, `blockStyle`) and
setter/index shapes, sent only with client `snippetSupport`. Inside a
`require` string nothing is offered (trigger characters are `.`, `:`,
`@`); require strings have hover, definition and document links only.

**Checked with Crystal 1.22** (exhaustive `case ... in`):

- Plain enum: `in .red?` per member is exhaustive.
- `@[Flags]` enum: never exhaustive by members ("can't be proved to be
  exhaustive", also with `.none?`).
- Nilable enum `C?`: `in .red?` fails (`undefined method 'red?' for
  Nil`); `in C::Red` ... `in nil` works.
- Union `Int32 | String | Nil`: `in Int32` / `in String` / `in Nil`;
  `C | String`: `in String` / `in C`.
- `Bool`: `in true` / `in false`.
- Abstract class: `in B` per subclass; the compiler checks against the
  *instantiated* subtypes only (one `in B` passed when only `B` was
  created), so listing every concrete subclass is always enough.
- Tuple patterns (`in {Int32, true}`) are rejected for `in`.

**Design decisions** (decided: snippet kinds are separately switchable;
only `do ... end` and exhaustive case are on by default; R4 is not a
goal):

1. **Snippet settings.** One switch per kind, all needing client
   `snippetSupport`; the bare keyword item is always offered too, so
   turning a snippet off never loses a completion:
   - `completion.doSnippet` (default **on**): `do ... end`.
   - `completion.caseSnippets` (default **on**): exhaustive branches.
   - `completion.definitionSnippets` (default off): `class`, `module`,
     `struct`, `enum`, `def`, `macro`, `lib`, `annotation`.
   - `completion.controlFlowSnippets` (default off): `if`, `unless`,
     `while`, `until`, `case`, `begin`.
   Off by default for definitions/control flow because clients that
   already insert `end` (nvim-endwise, treesitter-endwise, editor
   snippet packs) would get a double `end`.
2. **Indentation.** Snippet bodies use `\t` and newlines; items send
   `insertTextMode: adjustIndentation` (LSP 3.16) so the client applies
   the line's indent and tab/space style. Clients without it get the
   text as is (documented).
3. **Context gating.** A structural snippet is offered only where it is
   valid as a statement: at the start of a statement (only whitespace
   before the word on its line, or after `;`), never in modifier
   position (`x if y`, `return unless z`) nor as an argument. Definition
   snippets by place: `def`/`macro` in a type body or at top level, not
   inside a def; types not inside a def; `lib` at top level or in a
   module. Detection is on text plus the parsed enclosing node (the
   partial word may leave an ERROR node: fall back to the line text, as
   member completion's placeholder patch does). Sort tier `3` next to
   keywords, after locals and methods.
4. **`do ... end`.** Offered when the word being typed is `do`/`d`
   right after a call on the same line (`xs.each d|`, `foo arg d|`,
   `spawn d|`). The call is resolved like member completion; when it
   resolves and some overload takes a block, the parameters come from
   `Typing#block_param_names` (`do |${1:x}|\n\t$0\nend`); when no
   overload takes a block, nothing is offered; when unresolved, a plain
   `do\n\t$0\nend`. Not after a `{` block or inside parentheses of the
   call's own arguments.
5. **Exhaustive case.** Offered when typing `in` or `when` at the start
   of a branch line of a `case` with a subject. The subject's type at
   the `case` (inference on the patched text) gives the branches, as
   checked above: plain enum → `.member?`; enum inside a union → `E::Member`
   paths; union members → type names (`Nil` as `nil`); `Bool` →
   `true`/`false`; abstract or virtual class → its concrete subclasses
   in the DefMap (types of the view). Only branches not already written
   in this `case` are inserted, so the item also fills in the rest of a
   partial `case`. The keyword typed is kept (`in` is compiler-checked;
   `when` gives the same branches without the check). Each branch body
   is a tab stop (`$1`, `$2`, ..., `$0` after the last). Not offered for
   `@[Flags]` enums (cannot be exhaustive), unknown types, or more than
   30 branches. Label `in … (3 missing)`, detail lists them.
6. **Require completion (R1–R3).** Inside the string of a top-level
   `require` (also unterminated: `require "./fo|`). Rules from
   resolving each form with Crystal 1.22 in a Marten project
   (`/tmp/dorp`) and from `CrystalPath#each_file_expansion` (decided:
   shards by name only, stdlib internals hidden, no globs):
   - **Local** (`./`, `../`): `.cr` files of the directory without the
     extension, subdirectories as `dir/` (completion continues inside).
     A bare directory is never offered (`./src/migrations` fails to
     resolve) unless it holds `dir/dir.cr`. The file itself and paths
     already required in it are left out.
   - **Stdlib**: names under the stdlib `CRYSTAL_PATH` entry, one
     directory level per request (`http` → `http/` → `http/client`).
     A name that is both a file and a directory (`http.cr` + `http/`)
     is one item `http`; typing `/` continues into the directory.
     Hidden (internals): the prelude's own requires (`array`, `string`,
     ...: always loaded), `prelude`, `empty`, `docs_*`, `compiler`,
     `crystal`, `llvm`, and every `lib_*` segment at any depth
     (`lib_c`, `openssl/lib_ssl`). They still resolve when written.
   - **Shards**: only the names of direct dependencies in `shard.yml`
     (`dependencies` and `development_dependencies`) that are installed
     in `lib/` (`marten`, `sqlite3`), each checked to resolve. No
     subpaths (`marten/cli` is left to the shard's documentation), no
     transitive shards (`db`, `msgpack`). A shard name shadows a stdlib
     name (`lib` comes first in `CRYSTAL_PATH`): one item, the shard.
   - **No globs** (`dir/*`, `dir/**`) as items anywhere.
   - Every item is checked with `RequireResolver#resolve` and kept only
     when it resolves to the file it names, so no suggestion fails.
   - **Unchanged for written requires:** hover, definition and
     document links keep resolving everything the compiler accepts
     (`marten/cli`, `marten/marten/cli`, `msgpack/message_pack/any`,
     globs, transitive shards); completion just doesn't list them.
   - R3 details: the file's top-level declarations as detail
     (`http/client` → `HTTP::Client`) when the file is indexed; its
     leading comment as documentation; shards show their `shard.yml`
     version and description.
   - Trigger characters gain `"` and `/`; outside a require string they
     return an empty list immediately (no parse beyond the line).
   Directory listings are cached per directory until the file watcher
   reports a change; listing never follows symlinks
   (`lib/marten/lib` → `..`).

   Checked forms (Crystal 1.22): `marten`, `marten/cli`,
   `marten/marten_cli`, `db/spec`, `http`, `http/client`, `http/*`,
   `./src/project`, `./src/project.cr`, `./config/settings/*` resolve;
   `marten_cli`, `message_pack/any`, `marten/db/*`, `http/`,
   `./src/migrations` don't; `marten/*` resolves to no files (globs
   ignore the shard layout).

**Not goals:** auto-adding `require` when completing a constant from
an unrequired file (R4): requires are global to a program, so
"missing" depends on the view; reopened types have no single owner;
unrequired stdlib files are not indexed. The existing quick fix for
`undefined constant` stays the only require insertion. Generic static
snippets (`puts`, `p!`, `pp`, `spawn`) belong to the client's snippet
engine.

Steps (one commit each; pause at the end of each):

1. **Settings and snippet plumbing.** The four keys in
   `LSP::Settings` (regenerate `docs/settings.md`), `CompletionOptions`
   fields, `insertTextMode` on snippet items (only when the client
   lists `adjustIndentation` in `insertTextModeSupport`), and the
   statement-start / modifier-position detector with specs (start of
   line, after `;`, after `x if`, inside call args, inside a def vs a
   class body, partial input with ERROR nodes).
   *Done:* settings `completion.{doSnippet, caseSnippets,
   definitionSnippets, controlFlowSnippets}` (defaults on, on, off,
   off), `CompletionOptions` fields, `CompletionItem#adjust_indent` →
   `insertTextMode: 2` only when the client lists it.
   `IDE::StatementSite.at` (`ide/statement_site.cr`): the word replaced
   by a placeholder must parse as a direct child of a statement list,
   with only a comment after it on the line. Scopes: top level, type
   body, enum body, def (def/macro/fun, also blocks inside a def), and
   dynamic (`if`/`while`/`case`/blocks outside a def, where the
   compiler refuses `def` and types: "can't declare def dynamically";
   `begin` is transparent). Found on the way: any parse error *before*
   the word makes the scope unknown (nil): recovery reparents what
   follows (a word in a `lib` body lands at the top level, an
   unterminated `class A` is one ERROR), so structural snippets need a
   parse without earlier errors; an identifier in an enum body is its
   own one-child ERROR and is accepted. Macro bodies are raw text: no
   site.
2. **`do ... end`.** Decision 4. Specs: block method with named
   `yield` args, block method with placeholders, non-block method (no
   item), unresolved call (plain form), `foo arg d|`, after `{` (no
   item), setting off.
   *Done:* `Completion#do_snippet`: for the word `d`/`do` after
   something on the same line (rest of the line blank), the word is
   replaced by `do\nend` in a copy and the parser decides which call
   takes the block (`each_pair plain(1) do` → `each_pair`); a call that
   already has a block (`{ }`) gets none. Parameters from the resolved
   defs (candidates, else the name's family) via
   `Typing#block_param_names(site, implicit: true)`: a def without a
   block parameter whose body yields also counts (the compiler adds the
   block). Unknown call or a macro: plain `do\n\t$0\nend`; every def
   without a block: nothing. A `Snippet` item next to the keyword, sort
   `00do`, `insertTextMode: 2` when the client lists it. Specs
   `features_phase13_spec.cr`.
3. **Exhaustive case.** Decision 5, each subject kind from the checks
   above, partial `case` (missing branches only), `when` vs `in`,
   Flags enum and unknown type (no item). A spec compiles each
   generated `case ... in` with the compiler (fixtures for enum,
   nilable enum, union, Bool, abstract class) and expects no
   exhaustiveness error.
   *Done:* `Completion#case_snippet`: the word `i`/`in` or `w`/`when`
   alone on its line is replaced by `in <placeholder>` in a copy; the
   clause must parse as a child of a `case` with a subject, whose type
   is inferred there. Branches (`case_branches`): a plain enum alone →
   `.member?`; in a union, `nil`, `true`/`false`, enum members as
   paths, abstract classes → the concrete classes that cover them
   (`Circle`, `Square`, not `Square`'s subclass `Cube`: a class covers
   its subclasses; generic ones skipped), else the type's name.
   Already written conditions are skipped; nothing when none is
   missing, more than 30, a `@[Flags]` enum, an unknown subject, or a
   `when` and `in` mix (the compiler refuses it). Bodies indented one
   level below the clause (tab if the line uses tabs). The five
   fixtures compile (`crystal build --no-codegen` per spec, ~20 s of
   `make spec`, now 312 examples / 66 s).
4. **Definition and control-flow snippets.** Decision 3 forms
   (`class ${1:Name}\n\t$0\nend`, `def ${1:name}\n\t$0\nend`,
   `if ${1:cond}\n\t$0\nend`, `begin\n\t$1\nrescue ${2:ex}\n\t$0\nend`,
   ...), off by default; gating specs (no `if` snippet in modifier
   position, no `class` inside a def).
   *Done:* `Completion#structure_snippets`: a `Snippet` item beside
   each matching keyword (sort tier `3`, `insertTextMode: 2`), only at
   a `StatementSite`. Where (checked with Crystal 1.22): types, `lib`,
   `annotation` at the top level and in type bodies; `def`/`macro`
   there and in enum bodies; nothing in a def body ("can't define
   class/macro inside def") or under `if`/blocks outside a def ("can't
   declare ... dynamically"); control flow everywhere except enum
   bodies ("unexpected token"). Skeletons `class ${1:Name}\n\t$0\nend`,
   `if ${1:condition}\n\t$0\nend`, `case ${1:value}\nwhen
   ${2:pattern}\n\t$0\nend`, `begin ... rescue ${2:ex} ... end`.
5. **Require paths (R1, R2).** Context detection (including
   unterminated strings), local/stdlib/shard listing per the rules
   above, trigger characters. Specs over a fixture with `lib/` shards
   (direct and transitive, a `lib/x/lib` symlink loop, a shard named
   like a stdlib file): only direct names offered, no subpaths, no
   globs, internals hidden, bare directories not offered. A round trip
   over every stdlib directory: each offered string resolves to its
   file. A regression spec that hover/definition still resolve
   `marten/cli`-style subpaths, transitive shards and globs.
   *Done:* `IDE::RequireCompletion` (`ide/require_completion.cr`):
   context from the line text (`\A\s*require\s+"...` up to the
   cursor, so unterminated strings work); items replace the last path
   segment (`textEdit` up to the next `/`, `"` or end of line), kind
   `File` (17), directories `Module` with label `dir/`. Local: `.cr`
   files, directories holding sources, `dir` for `dir/dir.cr`; the file
   itself and already written requires skipped. Stdlib: one level,
   hidden top-level names (the prelude's own requires, `prelude`,
   `empty`, `docs_*`, `compiler`, `crystal`, `llvm`, `intrinsics`,
   `primitives`) and `lib_*` at any depth; a file and directory of the
   same name are one item (`http`, detail "stdlib (also http/)").
   Shards: `dependencies` + `development_dependencies` names resolving
   into `lib/`, detail `shard <version>` from the installed
   `shard.yml`; a shard named like a stdlib file appears once. Listings
   skip symlinked directories. Trigger characters `"` and `/` added; a
   `"`/`/` outside a require string returns no items. Round trip: every
   one of 386 offered stdlib strings resolves to its file (the rest are
   prelude-loaded or internal). On `/tmp/dorp` (Marten): warm request
   2–3 ms; `require "mar` → `marten` (shard 0.7.1), `marten/` → nothing.
   No per-directory cache: a listing is one `readdir` (0.8–2.3 ms in
   release).
6. **Require details (R3).** Top-level declarations and leading doc;
   shard version/description from its `shard.yml`; skip files outside
   the index (no detail rather than a parse per
   item).
   *Done:* `Completion#file_summary`: public top-level types, defs and
   macros of the file's index entry (at most 4, then `…`) before the
   detail (`HTTP::Client — stdlib (also client/)`, `Marten — shard
   0.7.1`); documentation is the shard's `shard.yml` `description`,
   else the first paragraph of the first documented declaration.
   `Index#entry_for_path?`. Files not in the index (nothing requires
   them) keep the plain detail: no parse per item. On `/tmp/dorp`,
   `http`, `http/client`, `json`, `uri` had details (Marten requires
   them); in a fixture that requires nothing, `http` had none.
7. **Verification and docs.** Neovim `editing` check: accept
   `xs.each do` (block params selected), an exhaustive `in` on an enum
   and a union, `require "./` → a file, `require "js` → `json`; with
   endwise-style auto `end` documented. README features, settings doc,
   status, architecture (Editing UX).

   *Done:* Neovim check `snippets` (`tools/nvim/snippets.lua`,
   fixture `tools/fixtures/snippets`, in `make nvim-check`): accepted
   through `vim.lsp.completion` conversion and `vim.snippet`:
   `each_pair d` → `each_pair do |x, y| / end`; `in` in `case c` (enum)
   and `case v` (`Int32 | String | Nil`) → every branch at the `case`'s
   indent with bodies one level deeper; `cla` → `class Name / end`
   (definition snippets on), none inside `if`; `require "./mo` →
   `models/`, `./models/po` → `post`, the already required `user` not
   offered; `require "js` → `json`, `http/cl` → `client`. Completion
   1 ms warm (141 ms for the first request). Found on the way: the
   case snippet wrote the line's indent itself, and Neovim's
   `vim.snippet` (like `insertTextMode: adjustIndentation`) adds it
   again: branches are now relative (`in X\n\t$1\nin Y`), with
   `adjust_indent`. README, status, architecture (Snippets and require
   completion). 0.13.0.

Exit criteria: with default settings only `do ... end` and case
snippets appear; every generated `case ... in` compiles without an
exhaustiveness error on the fixtures; no structural snippet in
modifier position; every require suggestion resolves to the file it
names (stdlib round trip), shards appear by direct name only and no
glob is offered; completion outside require strings is
unchanged (existing specs, Neovim check).

Status: done; every exit criterion met. Defaults: only `do ... end`
and case snippets (settings spec; the definition/control-flow spec
checks that `cla` gets only the keyword without the settings;
endwise-style double `end` is documented in those settings); the five case fixtures compile; the
statement-site spec covers modifier positions; 386 stdlib suggestions
resolve to their files; `editing` Neovim check output unchanged.
`make spec` 324 examples (~1.5 min); book diff 0 mismatches (565
markers); `make verify-static` OK.

Not yet: structural snippets after an earlier parse error in the file
(an unfinished `class` without `end`) are not offered (scope unknown);
require items describe only indexed files; `when` branches have no
compiler exhaustiveness check.

### Phase 14 — multi-root

The last planned phase (renumbered from 13).

- One index per workspace folder sharing stdlib/shard entries (cheap
  with the Phase 11 cache); `workspace/didChangeWorkspaceFolders`.
- Diagnostics and compiler facts per project, in its own directory
  (nested projects use the root's toolchain today).

**Today (0.13.0):** `Server#client_root` takes the first
`workspaceFolders` entry (else `rootUri`), widened to the project above
it; every other folder is ignored. Files of another folder get the
fallback views (their own per-file view, or the library view), resolved
with the first root's `lib/`. One `Compiler::Toolchain` runs in the
first root's directory, so a nested project (its own `shard.yml` and
`lib/`) is compiled there: checked with Crystal 1.22, a nested
`sub/src/app.cr` requiring its own shard fails from the outer
directory and compiles from `sub/`. Entry points are the first root's
shard targets only; the facts exporter keeps methods under that root.

**Design decisions:**

1. **Roots.** Each workspace folder maps to a project root as today
   (the folder, or the project above it); folders mapping to one root
   share it. One `Workspace::Index` per root, each with its own
   `Project` (toolchain detection, `lib/`, resolver), local cache
   (`<root>/.clear-ls/cache/`) and views. The first root is the
   primary one (`Server#index`, as before).
2. **Which index answers.** A file belongs to the root that is the
   longest prefix of its path (a nested folder wins over its parent).
   A file under no root (a stdlib or shard file opened by
   go-to-definition) is answered by the index the last workspace
   document used, when it has the file, else the first index that has
   it, else the primary one.
3. **Sharing.** Item trees of files outside every root's own sources
   (stdlib, shards) are shared between indexes: a file indexed by one
   root is reused by the next while its size and mtime match, so a
   second root doesn't parse the stdlib again. Requires are still
   resolved per root (`lib/` differs). DefMaps stay per view, as now.
4. **Edits.** An edit updates every index that has the file, and the
   file's own root.
5. **References, rename, call/type hierarchy** stay in the index of the
   file they start from: a project and a path dependency opened as two
   folders are separate programs (the dependency is a library file in
   the app's index, so renames into it are refused as today).
   `workspace/symbol` searches every index, files of any root first.
6. **Compiler per project.** Checks, `tool context` and `tool expand`
   run in the directory of the project that contains the entry point
   (`Project.find_root`), so nested projects and every folder use
   their own `shard.yml`/`lib/`. Entry points are that project's shard
   targets; `compiler.entries` applies per root (relative to each, the
   ones that exist). One exporter source per root; facts are kept per
   entry and applied to (and cached in) the index whose root has the
   entry.
7. **Folders change.** `workspace/didChangeWorkspaceFolders`
   (capability `workspace.workspaceFolders`): a new root is indexed
   like at startup (requests wait), checked and warmed up; a removed
   root's index, typings and diagnostics are dropped (empty
   `publishDiagnostics` for its files).

Steps (one commit each; pause at the end of each):

1. **Indexes per root.** `Server` keeps indexes by root; routing
   (`index_for`), shared item trees, edits and watched files to every
   index concerned, `workspace/symbol` and warm-up over all,
   `clearLs/clearCache` for all. Specs: two folders with a same-named
   class each resolve to their own; a shard of the same name with
   different versions in each `lib/`; the second root parses no stdlib
   file; a stdlib file opened from the second root.
   *Done:* `Server#indexes` (one `Workspace::Index` per root, primary
   first; `workspace_roots` maps folders as before, folders of one
   project collapse). Requests on a document (or a hierarchy item) run
   under `with_index(index_for(file))`, a per-fiber scope, so a job
   that yields keeps its index; `index` outside a scope is the primary
   one. `index_for`: the longest root containing the path, else the
   last index a workspace document used when it has the file, else the
   first that has it. Edits, closes and watched files update the
   file's own index and every index that has it. `Index#seed`: library
   trees of the earlier indexes, reused while size and mtime match
   (path dependencies still go to the root's local cache).
   `workspace/symbol` over every index (each file once, files under any
   root first); warm-up over every root's files; `clearLs/clearCache`
   clears each root. Specs `features_phase14_spec.cr` (8; the shard and
   workspace-symbol ones fail on 0.13.0). Release, `--no-cache`: this
   repo alone 566 ms / 92 MB, Marten alone 870 ms / 119 MB, both
   1190 ms / 132 MB, Marten as second root 606 ms with 353 stdlib files
   shared (Marten sits inside this repo as a nested project: its files
   route to its own index).
2. **Compiler per project.** Toolchain per project directory, entry
   points per project, exporter per root, facts per index. Specs with
   the real compiler: two folders each with a program needing its own
   `lib/` shard check clean; a nested project (not a folder) checked in
   its own directory.
   *Done:* `Compiler::Checker` takes a toolchain per entry (and extra
   sources per entry). `Server#compile_dir(path)`: the nearest
   `shard.yml` above the file, climbing out of `lib/<shard>` (an
   installed shard compiles with the project that installed it), else
   the workspace root holding it. Toolchains and `EntryPoints` are kept
   per directory; checks, `tool context` and `tool expand` run there,
   `tool format` in the request's root. Startup checks every root's
   targets. `compiler.entries` applies to the primary root and to other
   roots that have one of the listed files. One facts exporter per
   compile directory (methods under it); facts are kept per entry,
   merged into the index of the root holding the entry, and cached in
   that root's local cache. Specs (real compiler): two folders each
   needing their own `lib/dep` get only their own error; a nested
   project (not a folder) is checked in `sub/`; generated methods land
   in their own root's facts only. All three fail on step 1. `make
   spec` 335 examples; Neovim checks unchanged.
3. **Folder changes.** `didChangeWorkspaceFolders` add/remove. Specs:
   add a folder (definitions and diagnostics there), remove it
   (diagnostics cleared, files back to the fallback views).
   *Done:* `initialize` answers `workspace.workspaceFolders:
   {supported, changeNotifications}`. The server keeps the client's
   folders; `didChangeWorkspaceFolders` recomputes the roots. A new
   root is indexed (`add_root`, seeded from the other indexes), its
   cached facts restored, its targets checked, and the warm-up
   restarted; a removed root's index is flushed and dropped with its
   typings, running jobs are cancelled (`ContentModified`), and
   `Checker#forget` drops its entries' runs and results and publishes
   the files they reported (empty unless another program still reports
   them); its facts, entry points and context results go too. Open
   buffers of a removed root move to the index that now answers for
   them (edited text kept). Removing every folder keeps the last root;
   removing the first makes the next one primary. Before `initialized`,
   a change only updates the root list. Specs: add/remove (definitions
   follow the root's `lib/`), compiler diagnostics on add and cleared on
   remove, an edited buffer of a removed folder, last root kept,
   primary moved; three fail with the handler disabled. `make spec` 341
   examples.
4. **Verification and docs.** Neovim check `multiroot`
   (`vim.lsp.buf.add_workspace_folder`), startup time and RSS with two
   roots (this repo + Marten), README, status, architecture, 0.14.0.
   *Done:* Neovim check `multiroot` (fixture `tools/fixtures/multiroot`:
   `app/` and `tool/`, each with a vendored `lib/dep` of a different
   API, in `make nvim-check`): starting on `app`, `Dep.v1` resolves to
   `app/lib`, `tool.cr` (not yet a folder) can't see `Dep.v2`;
   `vim.lsp.buf.add_workspace_folder` indexes `tool` in ~80 ms, then
   `Dep.v2` goes to `tool/lib`, hover shows `def Dep.v2() : String`,
   `tool.cr` gets its own compiler error and `app.cr` keeps its own;
   workspace symbols find `Widget` in both; after
   `remove_workspace_folder` the tool diagnostics are cleared and the
   app's stay. Neovim's default `reuse_client` already attaches buffers
   under an added folder to the same client (checked). `Project.detect`
   now runs `crystal env` in the root (a version manager's
   per-project Crystal). Release build, ready / RSS: `--no-cache`: this
   repo 552 ms / 86 MB, Marten 813 ms / 132 MB, both 1242 ms / 131 MB;
   warm cache: 115 ms / 38 MB, 236 ms / 66 MB, both 335 ms / 79 MB.
   README (multi-root, compiler directory), architecture, status;
   0.14.0.

Exit criterion: two folders open in one client, each with correct
definitions and diagnostics.

Status: done. The `multiroot` Neovim check and the specs show two
folders in one client with their own definitions (each `lib/dep`) and
their own diagnostics, also when the second folder is added live.
`make spec` 341 examples; every Neovim check passes; book diff 0
mismatches; `make verify-static` OK.

Not yet: references and rename don't cross roots (a path dependency
opened as a second folder is a library file of the app); one
`compiler.path` for every root.

### Phase 15 — macOS

Development and every baseline so far are Linux (AMD EPYC 7K62, 16
cores / 32 threads). Goal: the tools, specs and checks run unchanged on
Linux and macOS, and the macOS-specific costs and bugs they reveal are
fixed.

Measured before planning (release build, Apple M3 Pro: 6 performance +
6 efficiency cores, 36 GB, macOS 26.5, Crystal 1.22.2 from Homebrew;
Marten as in Phase 10):

- **CPU-bound work is 1.6–4× faster than the EPYC:** stdlib parse
  single-thread 0.56–0.67 s (2.3 s), `coverage` this repo 0.47 s
  (0.75 s) and stdlib 1.25 s (3.4 s), compiler check of this repo
  0.93 s (1.9 s), Marten soak index 0.50–0.53 s (0.82–0.84 s), cold
  references `Request#method` 0.73–0.84 s (1.34 s), warm-up 4.6–5.2 s
  (7.5 s). Startup probe: 4–12 workers within 350–380 ms; the default
  (6 = `cpu_count // 2`) is fine. `--mcpu native` and tree-sitter at
  `-O3 -mcpu=native` change nothing measurable.
- **File-heavy work is slower: warm start 280–363 ms** (Linux
  237–254 ms; `warm.py`'s 300 ms criterion fails in most runs).
  `open()` costs ~110 µs per call from a freshly built binary and
  ~15 µs from Python on the same paths. The machine runs an endpoint
  security agent. Opens don't get faster beyond 2 threads
  (~75 µs each); `stat` and `readdir` stay cheap (1.7 ms to stat
  1346 files). So `Project#walk` costs 70–85 ms for Marten's 818
  directories, and a warm start still opens and hashes ~600 stdlib
  and shard files (global layer, content-checked). The first launch of
  a new binary is ~500 ms slower (scanned once).
- `Project.detect` runs `crystal env` and `crystal --version` one after
  the other: 13–15 ms each, 26–38 ms per root.
- **Memory:** `Memory.trim` is a no-op off glibc. `ps` RSS overstates
  the footprint: right after indexing 155 MB RSS vs 105 MB physical
  footprint (`vmmap --summary`: ~80 MB of empty `MALLOC_SMALL` regions,
  reclaimable). `malloc_zone_pressure_relief` frees nothing measurable
  (tried and reverted). Soak RSS after 100 specs + 10 searches
  272–279 MB (Linux 234–244 MB); the criterion (< 400 MB) passes.
- **Tools that fail on macOS:** `lsp_client.py` reads RSS from
  `/proc` (soak.py and warm.py crash); `tools/nvim/run.sh` calls GNU
  `timeout`; `make verify-static` expects ELF symbol names (Mach-O
  prefixes `_`) and checks only with `ldd`. `xargs -r`, `cksum`,
  `lsp_bench.py`, `book_diff.py`, `types_diff.py`, `external.sh` work.
- **Specs:** 2 of 341 fail. The toolchain spec expects the temp path
  as given; the compiler reports real paths (`/var` is a symlink to
  `/private/var`). The Phase 10 cancel spec's search over 40
  candidates finishes within its 5 ms sleep on the M3 (3 of 6 runs).
- **Paths from clients.** `$TMPDIR` ends in `/`, so `"$TMPDIR/x"` has
  `//`; Neovim sends such folder URIs as given, and the server compares
  roots with file paths by string prefix: the `multiroot` check's added
  folder never matched its files. Neovim also names buffers by real
  path (`/private/var/...`) while the folder keeps the symlinked one
  (`/var/...`). Making roots real paths fixes that, but breaks clients
  that use the symlinked path for both (26 specs).
- **Pitfalls met while measuring:** `make spec` rebuilds `bin/clear-ls`
  as a debug build when sources changed (a 3× "regression" in a
  release A/B); outside `make`, a build without `PKG_CONFIG_PATH` links
  Homebrew's shared `libtree-sitter` 0.27 silently instead of the
  vendored 0.26.9.

Decisions:

- **Portable means unchanged:** every script, probe and check runs on
  both systems with the same command and prints the same criteria;
  platform branches stay inside the tool (no macOS copies).
- **Memory criteria use one metric per platform:** `VmRSS` on Linux,
  physical footprint on macOS (what the kernel can't take back); both
  printed where they differ.
- **Fewer opens, not platform tricks:** the warm start is fixed by
  not opening unchanged files and directories (helps Linux too).
  Endpoint agents are a fact of developer machines. No
  `getattrlistbulk` or other macOS-only syscalls while the portable
  change is enough.
- **Every step is verified on both systems** (startup probe,
  `warm.py`, soak on Linux within noise of the Phase 14 numbers).

Steps (one commit each):

1. **Portable tools.** RSS from `ps` without `/proc`; `run.sh` falls
   back to `gtimeout` or a Perl alarm and copies fixtures to a real
   path; `verify-static` matches `_`-prefixed symbols and checks
   `otool -L`.
   *Done:* soak.py and warm.py run on macOS (every criterion passes
   except the warm start, step 6), `make nvim-check` runs all 9 checks
   and `make verify-static` reports OK. With the real-path work dir,
   `multiroot` shows `Dep.v2 -> tool/lib/dep/src/dep.cr` after the add
   (symlinked folders: step 5).
2. **Specs on macOS.** Real temp path in the toolchain spec; enough
   candidates that the cancel spec's search outlives its sleep.
   *Done:* toolchain spec compares against `File.realpath` of its temp
   root; cancel spec on 400 candidates (10 of 10 runs pass, was 3 of 6
   failing).
3. **Repeated slashes in client paths.** `VFS.path_for` collapses
   `//` (only that: `Path#normalize` would also resolve the `..` in
   Homebrew's stdlib path, `.../bin/../share/...`, and change file
   identities). Spec: a folder URI with `//` and a document named
   through it.
   *Done:* fails without the change (the root kept `//`). Sweep and
   `warm.py` A/B against the previous release build: equal within
   noise (completion p50 0.8 ms, cold references 0.73–0.84 s).
4. **Memory metric.** `lsp_client.py` reports physical footprint on
   macOS (`footprint`/`vmmap`, cheap enough for `warm.py`'s polling, or
   a separate call); soak and warm print it; Linux unchanged.
   *Done:* `Client.mem_mb`/`mem_text`: `footprint -p` (~16 ms; `vmmap`
   takes 0.5–0.75 s) on macOS, `VmRSS` on Linux with the same output as
   before. Marten soak: footprint 103 / 173 / 226 MB (RSS 153 / 223 /
   276 MB) after indexing / 100 specs / 10 searches; after warm-up
   footprint 299 MB (RSS 307 MB).
5. **Symlinked folders.** A file belongs to a root when its path or its
   real path is under the root's given or real path (real paths
   computed once per root and cached per file id). Specs: folder by
   symlink with documents by real path, and the reverse; both
   consistent forms keep working. Neovim `multiroot` with the
   symlinked `$TMPDIR` (no `pwd -P` in `run.sh`).
   *Done:* the root keeps the client's name (consistent clients
   unchanged). `VFS#alias_dir` maps a root's real path to it, and
   `alias_file` maps one document opened through a symlink into a root
   (checked on `didOpen` of a file under no root: one `realpath`).
   `VFS#canonical_uri` applies both in `id_for`/`file?`, and
   `Server#canonicalize` rewrites `textDocument.uri` once per message.
   Files interned before their alias (a buffer opened before its
   folder was added) are re-keyed and keep their id. Aliases outlive
   their folder (open buffers keep their ids); adding the folder again
   under its other name turns its alias around (`VFS#claim`).
   Diagnostics: a removed root also forgets entries named by real path
   (the buffer's loose-file program); publications follow
   `canonical_uri`, and a file whose name changed gets an empty
   publication under its old URI (the compiler names files neither
   like the client nor consistently). Specs: both directions, the
   consistent symlink, a buffer opened before its folder is added and
   the folder added again by real path, and the full Neovim sequence
   with the compiler (each fails without its change; the `forget_root`
   one only through the checker's state). `run.sh` uses the symlinked
   `$TMPDIR` again (only the trailing `/` dropped): every check passes,
   `multiroot` as in Phase 14 (tool diagnostics cleared on removal).
   Sweep A/B vs step 4: equal within noise. `make spec` 347 examples;
   one compiler spec failed once under load (`wait_compiler`), 8 of 8
   alone.
6. **Directory listing cache.** The local layer stores each walked
   directory's mtime and entries; an unchanged directory isn't opened
   (entries added, removed or renamed change its mtime). Specs: new,
   deleted, renamed file and directory between sessions; a nested
   `shard.yml` appearing. Target: Marten walk 70–85 → < 15 ms warm.
   *Done:* `Cache::Local#children`, a separate `dirs.pack` (names per
   directory, keyed by its mtime; `items.pack` unchanged, so no
   `SCHEMA` bump); the directory is `stat`-ed before it is listed, and
   children are still `stat`-ed as before (file kinds, nested
   `shard.yml`). `Project#children` is the walk's lister (`Dir.children`
   without the cache). The `index ready` line adds `dirs hits/total`.
   The first warm session lists the root again (the cold one created
   `.clear-ls/` in it). Marten `warm.py` A/B vs step 5: warm start
   349–392 → 228–294 ms (criterion < 300 ms met in both runs). Spec:
   hits on an unchanged tree; new directory, file renamed away, nested
   `shard.yml` appearing. `make spec` 348 examples; once, a
   compiler-backed spec failed in the full run (`keeps compiler facts`;
   6 of 6 alone, two more full runs green): `wait_compiler` may return
   before a check is scheduled (step 9).
7. **Global layer by size + mtime first.** Packs record mtime next to
   size and hash; a match skips reading the file, a mismatch falls back
   to the content hash as now (packs stay shared across checkouts).
   `Cache::SCHEMA` and patch bump. Specs: touched file with the same
   content is a hit after rehashing, patched shard file a miss.
   *Done:* `FileMeta` already had an `mtime` (global entries wrote 0),
   so the format is unchanged (no `SCHEMA` bump; 0.14.1 for the changed
   entries). Workers `stat` a global file and take
   `Store#lookup_unchanged` when size and mtime match, else read and
   hash as before. Misses are recorded with their mtime. Entries are
   not re-stamped: other checkouts of a shard version and touched files
   stay checked by content (re-stamping would make two checkouts
   rewrite the pack on alternating starts). Packs from older builds are
   never read (build key), so there is nothing to migrate. Marten
   startup probe (global layer only): index phase 293–299 → 230–234
   ms; server warm start (`index ready`, median of 10, two rounds):
   212/210 → 206/194 ms (project files already come from the local
   layer). Spec: unchanged files by stat (3 of 3), a touched stdlib file
   by content, a second checkout's shard by content. `make spec` 349
   examples.
8. **Detection.** `crystal env` and `crystal --version` concurrently,
   or one result per `crystal` executable (real path, size, mtime) in
   the global cache dir. Spec: a changed executable is detected again.
   *Done:* concurrently. Not cached: `crystal` may be a version
   manager's shim that resolves per directory (why Phase 14 runs it in
   the root), so the executable's identity says nothing about the
   Crystal it runs. Both processes start before either is read
   (outputs fit the pipe buffer). `Project.detect` with the real
   compiler: 22–27 → 12–13 ms per root. Specs: a fake `crystal` taking
   0.3 s per command is detected in < 0.55 s (0.68 s before), with its
   version, target and path; no compiler falls back to `lib`.
9. **Verification and docs.** Both systems: `make spec`, `make
   nvim-check`, `make verify-static`, `tools/book_diff.py`, soak,
   sweep, `warm.py`, startup probe; `make grammar-check` on macOS
   (`brew install tree-sitter-cli`). macOS baselines next to Linux in
   development.md; gotchas (endpoint agents and per-open cost, the
   `/var` symlink and `$TMPDIR`'s slash, `make spec` overwriting the
   release binary, Homebrew's `libtree-sitter`, RSS vs footprint);
   README; 0.15.0.
   *Done on macOS:* `make spec` 351 examples, every Neovim check
   (`multiroot` as in Phase 14 with the symlinked work dir),
   `verify-static` OK, book diff 540 match + 25 accepted (0
   mismatches), soak (hover p99 43 ms, footprint 224 MB, cancel OK),
   `warm.py` (warm start 174–237 ms, first references after warm-up 48
   ms vs 17–20 warm), sweep 60 s (0 errors, 0 over 300 ms). Found on
   the way: `$(BIN)` depended on the phony `deps`, so `make spec` and
   `make verify-static` always rebuilt it as a debug build (fixed).
   Docs: development.md (macOS baselines), gotchas.md (macOS),
   architecture.md, persistent-cache.md, tools README, README.
   `make grammar-check` on macOS: 1634/1646 with Crystal 1.22.2 (1635
   with 1.22.0): `libevent/event.cr` gained a known gap (`&.x=(v)`); the
   vendored runtime fails the same 12 files as CLI 0.27.1.
   *Done on Linux* (EPYC, Crystal 1.22.0; release builds of 0.14.0 and
   this branch run interleaved): `make spec` 351 examples (after the
   fix below), every Neovim check with output equal to 0.14.0's except
   the new `dirs` counter in `cache`, `verify-static` OK (and no longer
   rebuilds the release binary), book diff identical (540 + 25, 0
   mismatches), `make grammar-check` 1635/1646. Marten, 0.14.0 → 0.15.0:
   startup probe load median ~780 → ~783 ms uncached (12 runs each,
   701–919 vs 722–856), 389–792 → 399–799 ms from the global cache,
   `detect` median ~42 → ~31 ms; `warm.py` warm start 235–254 →
   209–239 ms, warm-up 7.5–8 s, 310–318 MB RSS, references after it
   80–90 ms both; soak RSS after 100 specs + 10 searches 245–261 →
   242–245 MB, hover p99 during a search 46–79 → 71–76 ms over 5 runs
   (noise: ~22 samples, p99 is the max); sweep 60 s 0 errors, the same
   single hover over 300 ms (`template/tag/super.cr:23`) on both.
   Found on the way: the step 7 spec assumed two checkouts' `dep.cr`
   get different mtimes; on ext4 files written back to back mostly
   share one (93 of 100), so `b`'s copy was taken by stat (failed 3 of
   4 full runs). The spec now sets it a minute back (10 of 10). The
   multi-folder compiler flakes (gotchas.md) didn't show in 4 Linux
   full runs; still open.

Exit criteria: every tool, probe and Neovim check runs unchanged on
Linux and macOS; `make spec` green on both; Marten warm start < 250 ms
on the M3 Pro (`warm.py`); no Linux regression (startup probe,
`warm.py`, soak within noise of the Phase 14 numbers).

Status: done. Every tool, probe and Neovim check runs unchanged on
both systems; `make spec` green on both; Marten warm start on the M3
Pro 280–363 → 174–237 ms; on Linux no regression (startup probe and
soak within noise) and a faster warm start (235–254 → 209–239 ms).
0.15.0.

Not yet: the two multi-folder compiler specs that failed once each in
~10 full macOS runs ([gotchas.md](gotchas.md#macos)).

### Phase 16 — type definition, declaration, range formatting

Small LSP gaps found while comparing with Lattice (a Liger fork built
on the compiler's parser plus regex symbol scans). Branch
`dev/navigation-range-format` (renamed `dev/next`).

**Today (0.15.0):** no `typeDefinitionProvider`, no
`declarationProvider`, no `documentRangeFormattingProvider`. Formatting
formats the whole buffer with `crystal tool format -` and sends one
edit from the first changed line to the last (`Server.line_diff`).

**Out of scope (decided):**

- Live syntax diagnostics: diagnostics stay compiler-only, on save. A
  half-typed buffer would only produce noise; no compiler-parser
  dependency for this.
- Lint-style inspections (unused variable, shadowing, empty rescue):
  left to ameba-ls.
- `codeLens`: no lens worth its cost yet.
- `onTypeFormatting`: needs a parse mid-edit or a regex indent guess.

**Design decisions:**

1. **Type definition** goes to the declaration of the *type* of the
   thing under the cursor. Sources, in order: a local, param or block
   argument (the flow type `local_hover` shows), an ivar/cvar (the
   `var_hover` type), a call (its return type at that call), a
   literal; on a constant naming a type it is that type's definition.
   Type → locations: `Named` gives the type's declaration sites
   (reopenings: the first site of each file, at most 10; generic
   arguments are not followed: `Array(String)` goes to `Array`);
   `Union` gives each member's, `Nil` included (as the compiler sees
   it); `Metaclass` its instance type; `Tuple`/`NamedTuple`/`Proc` the
   stdlib struct. Unknown, `TypeParam`, `NoReturn` and `Pending`
   give no result (never guessed).
2. **Declaration** is an alias of definition: Crystal has no separate
   declarations (an abstract def is a definition the implementations
   override; `implementation` already covers that direction). It
   exists so clients that bind it (Neovim `gD`) don't fail.
3. **Range formatting** filters a whole-buffer format to its changed
   hunks, the way conform.nvim does for formatters without range
   support (`runner.lua` `apply_format`): format the whole buffer
   with `crystal tool format -` (the formatter needs the full source:
   indentation, `when`/hash/assignment/comment alignment); line-diff
   the old and new text into hunks; keep the hunks whose original
   lines touch the requested lines (an insertion touches when it is at
   or next to them); each kept hunk extends the window to its end, so
   a delete/insert pair both go. One `TextEdit` per kept hunk. A
   syntax error anywhere (the formatter fails) gives no edits and a
   log message, as formatting does now. Limits (documented): a kept
   hunk can reach past the selection; a change that spans separate
   hunks (alignment where the middle line is already right) is
   applied only for the selected part.
4. **Diff.** A line diff giving all hunks (LCS on the lines between
   the common prefix and suffix; formatter output is close to its
   input). `textDocument/formatting` keeps one edit for prefix/suffix
   as now (cursor and marks stay; no behaviour change).

Steps (one commit each; pause at the end of each):

1. **Type definition and declaration.** `IDE::TypeInfo#type_at`
   (the cursor's type, reusing the hover paths) and
   `Navigation#type_definitions`; capabilities
   `typeDefinitionProvider`, `declarationProvider`. Specs: local of a
   user class, a call returning a stdlib type, a union with `Nil`
   (both), a reopened class, `Foo.new` / constant `Foo`, ivar from a
   declaration, block argument, unknown gives an empty result,
   declaration = definition.
   *Done:* `TypeInfo#type_at` shares the hover paths (`local_type`,
   `ivar_type`, `self_type_at`, `literal_type`, `call_at`'s result);
   `Navigation#type_definitions` maps the type to sites (falling back
   to the constant under the cursor). Sites of a type: its first one
   plus the first in each other *workspace* file; stdlib/shard
   reopenings are skipped (`String` on the real stdlib went to four
   files: `string.cr`, `grapheme.cr` twice, `utf16.cr`; now
   `string.cr`). `declaration` is answered by `definition`. Specs
   `features_phase16_spec.cr` (9). `make spec` 360 examples.
2. **Range formatting.** `Server.line_hunks`, `rangeFormatting`
   handler, capability. Specs: hunk diff (insert, delete, replace,
   adjacent hunks); a selection inside a def formats only it with the
   def's indentation; an untouched hunk elsewhere stays; a pair kept
   together; an already-formatted range gives no edits; a syntax
   error gives no edits.
   *Done:* `Server.line_hunks` (Myers on the lines between the common
   prefix and suffix; the trace keeps only diagonals `-d..d` per step)
   and `Server.hunks_in_range` (conform's rule: overlap, an insertion
   at or right after the window, the window grows to each kept hunk's
   end). A range ending at column 0 of a line leaves that line out
   (linewise selections in clients send the next line's start).
   `textDocument/formatting` is unchanged (one prefix/suffix edit).
   Specs: hunks, a 200-case random check that applying every hunk
   gives the new text, range selection, the LSP handler (selected
   hunk with the def's indentation, alignment against the first line
   of a hash, formatted range, column-0 end, syntax error).
   `make spec` 368 examples. A mangled `string.cr` (5929 lines,
   1261 hunks): diff 104 ms (release; 261 ms before trimming the
   trace), a 10-line range 0.95 s end to end, mostly `tool format`;
   applying all hunks of a whole-file range equals the formatter's
   output.
3. **Verification and docs.** Neovim check: `vim.lsp.buf.type_definition`
   and `declaration`, `vim.lsp.buf.format({range = …})` without conform;
   README feature list, status, architecture; 0.16.0.

   *Done:* Neovim check `navigation` (fixture
   `tools/fixtures/navigation`, in `make nvim-check`) through
   `vim.lsp.buf`, no conform: type definition of a local
   (`demo.cr:1`), a `Point?` (`nil.cr:44, demo.cr:1`), a call result on
   the real stdlib (`string.cr:147`); declaration of `find`;
   `vim.lsp.buf.format({range})` on one line of an unformatted def
   reformats that def's hunk (lines 19–22) and leaves the next def
   alone, which whole formatting then fixes. README (navigation,
   formatting and its limits), architecture, tools/README, status;
   0.16.0.

Exit criterion: type definition and declaration answer from the
inferred types; range formatting changes only the selected hunks; no
regressions (`make spec`, `make nvim-check`, `make verify-static`).

Status: done. `make spec` 368 examples; every Neovim check passes
(`navigation` added); `make verify-static` OK. 0.16.0.

Not yet: range formatting needs the whole buffer to parse (formatter
limitation); a hunk can reach past the selection, and alignment split
into separate hunks is applied only where selected.

### Phase 17 — annotations

Found while probing C bindings (`syntax/grammar.cr`): annotation
names work, everything around them doesn't. Branch
`dev/next` (shared by Phases 16–19 until merged).

**Today (0.16.0):** hover and definition on the annotation name work
for annotations declared in source (`Link`, `Deprecated`,
`JSON::Field`, user `annotation MyAnn`). Measured gaps:

- The compiler's own annotations have no declaration
  (`Program#initialize`, compiler/crystal/program.cr:270–284):
  `AlwaysInline`, `CallConvention`, `Extern`, `Naked`, `NoInline`,
  `Packed`, `Primitive`, `Raises`, `ReturnsTwice`, `ThreadLocal` give
  no hover, no definition, no completion (`@[Al` → nothing). `Link`,
  `Flags`, `Deprecated`, `Experimental`, `TargetFeature` are also
  declared in `annotations.cr` and work.
- Completion does not know it is inside `@[…]`: `@[` gives the
  ordinary expression items (`sleep`, `puts`, … 69–120 items);
  `@[Li` mixes `Link` with every `Lib*` module, `@[Pa` offers the
  `Path` struct, `@[JSON::` lists every `JSON` type. Annotations use
  the `Class` completion kind.
- Arguments: `@[Link(` and `@[JSON::Field(` give expression items,
  `@[Link("m", pk` and `@[JSON::Field(ke` give nothing. Hover on a
  named argument (`ldflags:`, `pkg_config:`, `key:`, `emit_null:`)
  or a positional one (`"m"`) gives nothing.
- Half-typed annotations parse as `ERROR` (`@[` alone is an empty
  `ERROR`; `@[JSON::` swallows the next `def`), so the context must
  come from the text before the cursor, as `RequireCompletion` does.

**Design decisions:**

1. **Built-in annotation table.** One table for the compiler's
   annotations: name, short doc, where it applies (lib, fun, def,
   struct, ivar, …), arguments (name, type, doc) as the compiler
   reads them: `Link` (`lib`, `ldflags`, `static`, `framework`,
   `pkg_config`, `wasm_import_module`, `dll`; codegen/link.cr),
   `Extern(union:)` (top_level_visitor.cr:215), `TargetFeature(cpu:)`
   (1271), `CallConvention(String)`, `Deprecated(String)`,
   `Experimental(String)`, `Primitive(Symbol)`. Hover on a built-in
   with no source has no definition location. A declared annotation
   (`annotations.cr`) keeps its source doc; the table only adds the
   arguments.
2. **Annotation context.** `IDE::AnnotationCompletion.context(text,
   offset)` from the line before the cursor: in the name (`@[`,
   `@[Na`, `@[A::`) or in the arguments (`@[Name(…`, after `(` or
   `,`). In the name: annotation types reachable from the cursor's
   namespace, plus namespaces that contain one (`JSON` for
   `JSON::Field`), plus the built-ins; nothing else.
3. **Argument names** for source annotations come from the doc
   convention the stdlib uses: `* **name**: text` bullets in the doc
   of the annotation or of the module that reads it (`JSON::Field`'s
   are on `JSON::Serializable`: 8; `YAML::Field`: 8;
   `URI::Params::Field`: 4). Where the bullets live is found from the
   `ann = x.annotation(::JSON::Field)` sites in macro code of the
   same file. Names already written are not offered again.
4. **Hover** on a named argument: its name, type when known, and the
   doc line. On a positional argument of a built-in with one
   (`@[Link("m")]` → `lib`): the same.

**Undecided (needs approval):** argument names from `ann[:key]` reads
in macro bodies (covers user annotations without docs; means scanning
`macro_content` text).

Steps (one commit each; pause at the end of each):

1. **Built-in annotations.** The table; hover and completion items
   for the built-ins; `@[AlwaysInline]`, `@[Raises]` hover. Specs:
   each built-in hovers; a declared one keeps its source doc.

   *Done:* `IDE::Annotations` (15 entries: doc, where it applies,
   arguments with type, position and whether named) and
   `Analysis#builtin_annotation_hover`: a built-in with no
   declaration hovers from the table (no definition); a declared one
   (`Link`, `Flags`, ...) keeps its stdlib doc plus "Applies to" and
   the argument list. A declared annotation in scope with a built-in's
   name (`Own::Raises`) wins, as in the compiler. Also fixed: in
   `@[Primitive]` and `@[Flags]` the compiler always takes the
   top-level annotation (semantic_visitor.cr), but clear-ls resolved
   `File::Flags` (the enum) inside `class File` and `Int::Primitive`
   (an alias) on stdlib number methods. The completion items moved to
   step 2 (they need the `@[` context). Specs
   `features_phase17_spec.cr` (5). `make spec` 373 examples.
2. **Annotation name completion.** Context detection and filtering;
   an annotation completion kind. Specs: `@[`, `@[|]`, `@[Li` (only
   `Link`), `@[Pa` (only `Packed`), `@[JSON::` (only `Field` and
   the `Serializable` namespace for `Options`), user annotations,
   inside a class body and before a `fun` in a `lib`.

   *Done:* `IDE::AnnotationContext` scans back from the cursor to the
   last `@[` (at most 4 KB) and lexes strings, chars, comments and
   nested brackets: `Name` (qualifier, prefix) or `Args` (annotation,
   prefix, named arguments written, positional count; used in step 3);
   nil once the annotation closes or inside a value. Inside a string or
   comment (checked on the CST) nothing changes. `Completion#annotation_names`:
   annotation types of the enclosing namespaces and their ancestors,
   namespaces holding an annotation (`JSON`, `Serializable`), the
   members of a written path (`@[JSON::`, `@[::`), and the built-ins;
   no other types (`Path`, `Thread`, `LibC` are gone). New
   `CompletionKind::Annotation` sent as LSP 8 (`Interface`), so clients
   show annotations apart from classes. `[` is now a trigger character;
   an automatic `[` request outside `@[` (`xs[`) gets nothing, an
   explicit one is unchanged (`context.triggerCharacter`). Specs: 10 more
   in `features_phase17_spec.cr` (15). `make spec` 383 examples.
3. **Arguments.** Named-argument completion and hover from the
   table and doc bullets. Specs: `@[Link(` → `ldflags:` …,
   `@[Link("m", pk` → `pkg_config:`, `@[JSON::Field(ke` → `key:`,
   written names skipped, hover on `emit_null:` and on `"m"`.

   *Done:* `IDE::AnnotationArgs`: a built-in's arguments from the
   table; otherwise `* **name**: text` bullets in the annotation's own
   doc, or within 3 lines after a line naming it (`` `JSON::Field`
   properties: ``, ``### Class annotation `JSON::Serializable::Options` ``)
   in any declaration doc of a file declaring it. On the real stdlib:
   `JSON::Field` 8, `YAML::Field` 7, `URI::Params::Field` 4,
   `JSON::Serializable::Options` 1. Completion at an argument start
   offers `name:` items (field kind, inserts `name: ` over the typed
   word), minus names written and built-in positions already filled
   (`@[Link("m", ` drops `lib:`); an annotation with no known
   arguments keeps the ordinary items. Hover on an argument name, and
   on a positional value the compiler names (`"m"` → `lib`,
   `Deprecated("…")` → `message`). Specs: 6 more (21). `make spec`
   389 examples.
4. **Verification and docs.** Neovim check with an annotation
   fixture (completion inside `@[`, hover on an argument); README,
   status, architecture; 0.17.0.

   *Done:* Neovim check `annotations` (fixture
   `tools/fixtures/annotations`, in `make nvim-check`): `[` is a trigger
   character; typing `@[` with `vim.lsp.completion` autotrigger opens
   the 16 annotations, `@[JSON::` gives `Field Serializable`, `xs = [`
   opens nothing; explicit requests for arguments; hovers on `Raises`,
   `"m"`, `ldflags`, `emit_null`.

   Real check on Athena (annotation-heavy: DI, serializer, console,
   ORM, routing; `athena-dependency_injection` 0.4.6,
   `athena-serializer` 0.4.4, `athena-console` 0.5.0 as shards of a
   small app). Found and fixed (`fix(semantics)` commit):
   - **Aliases inside a path.** Athena writes `@[ADI::Register]` with
     `alias ADI = Athena::DependencyInjection`; `DefMap#lookup_path_raw`
     didn't follow an alias in a middle segment, so hover, definition
     and completion on `Register` gave nothing (also `OI::K` in plain
     code). The compiler follows it. On the app's shards: 264 locals
     typed that were unknown, 0 regressions; repo source and stdlib
     unchanged (types dump diff).
   - `@[` offered no namespace aliases (`ADI`, `ASRA`, `ACONA`); now
     with the target's kind.
   - Argument docs in two more forms, in the annotation's own doc only:
     `` * `name : Type` - text `` (`ADI::Register`, `ASRA::Name`) and a
     `### name` heading followed by `**Type:** `T`` (`ACONA::AsCommand`,
     `ARTA::Route`, every ORM mapping annotation). 20 of Athena's 67
     annotations document arguments; all 20 are read (`ADI::Register`
     6, `ARTA::Route` 12, `AORMA::Column` 12, ...). The other 47 take
     no arguments or describe them only in prose.

   README (completion, information), architecture, tools/README,
   status; 0.17.0. `make spec` 393 examples.

Status: done. `make spec` 393 examples; every Neovim check passes
(`annotations` added); `make verify-static` OK. 0.17.0.

Not yet: argument names of undocumented user annotations (`ann[:key]`
in macros, not approved); positional values only for built-ins.

### Fix round after Phase 17: annotation arguments from tables only (done)

Review of step 3: doc formats vary per shard (Athena alone uses two,
the stdlib a third), so parsing them is fragile. Tracing the macros
that read an annotation (`x.annotation(ADI::Register)`, then
`ann[:key]`) links use and reader only by name at expansion time, and
misses `ann.named_args` loops (42 in Athena) and annotations passed
through variables: also a heuristic, plus an index over every macro.

Decision: argument completion and hover only for the compiler's
annotations and the stdlib's own. The stdlib ones are a table
(`Annotations::STDLIB_ARGS`, from the `ann[:…]` reads of
json/serialization.cr, yaml/serialization.cr,
uri/params/serializable.cr in Crystal 1.22: `JSON::Field` 8,
`YAML::Field` 7, `URI::Params::Field` 4, `JSON::Serializable::Options`
and `YAML::Serializable::Options` 1), used only when the annotation is
the stdlib's declaration. Doc parsing removed (bold bullets, Athena's
code bullets and `### name` + `**Type:**` sections). Kept: annotation
names for every annotation (from declarations), the alias-in-path fix,
namespace aliases after `@[`. Shard and user annotations fall back to
ordinary completion items. Specs updated (25 in
`features_phase17_spec.cr`). 0.17.1.

Exit criterion: inside `@[…]` completion offers only annotations and
their arguments; built-in annotations and argument names hover; no
regressions (`make spec`, `make nvim-check`, `make verify-static`).

### Phase 18 — C bindings (`lib`, `fun`)

Probed on `syntax/grammar.cr` and a fixture covering funs, `$vars`,
lib structs, unions, enums, aliases, `type`, variadic funs and proc
parameters. Branch `dev/next`.

**Today (0.16.0):** hover/definition on `lib`, lib `alias`, `type`,
`struct`, `union`, `enum`; document symbols list funs, `$vars`,
fields; inference types C calls by name and arity
(`Infer#lib_member_call`: `LibX.cos(1.0)` → `Float64`, variadic,
`out`, struct field get/set). Measured gaps, by cause:

- **R1 — `lib_c/<target>` not on the require path.** The compiler
  adds `<entry>/lib_c/<arch>-<os>` to `CRYSTAL_PATH`
  (`CrystalPath#add_target_path`); `Workspace::RequireResolver`
  doesn't, so `require "c/string"` etc. never resolve: only
  `lib_c.cr`'s own aliases exist. `LibC::UInt32T`, `SizeT`, `PidT`,
  `SSizeT` don't resolve, and every fun returning one is untyped
  (`LibC.strlen`, `LibC.malloc`, `LibTreeSitter.ts_language_abi_version`,
  `ts_language_symbol_count`). Confirmed with a `crystal` wrapper
  that adds the directory: `UInt32T` → `stdint.cr:8`, `strlen` →
  `UInt64`, `PidT` → `types.cr:16`.
- **R2 — C calls reach inference only.** `TypeInfo#call_at` uses the
  ordinary call resolution, which has no funs: hover on `LibX.cos`
  says `LibX.class#cos : Float64 … built-in (no source
  declaration)`; definition, references, signature help, rename are
  empty; completion after `LibX.` offers only `new`. Same for
  `$var` (`LibX.errno_v`) and lib struct fields (`pt.x`).
- **R3 — no hover on declarations.** `TypeInfo#def_hover` takes
  `method_def`, `abstract_method_def`, `macro_def` only: a `fun`
  name, a `$var`, a struct/union field name hover nothing.
- **R4 — compiler-only types and pseudo-methods.** `Void` and
  `NoReturn` are built into the compiler; their only docs are
  `struct CRYSTAL_PSEUDO__Void` / `__NoReturn` in
  `docs_pseudo_methods.cr`, which also documents `sizeof`,
  `instance_sizeof`, `alignof`, `instance_alignof`, `pointerof`,
  `offsetof`, `typeof`. None hover. `Pointer(Void)` shows as
  `Pointer(?)`.

**Design decisions:**

1. **Target path** from `Project#target_triple` mapped as the
   compiler's `Codegen::Target#architecture`-`#os_name`
   (`x86_64-unknown-linux-gnu` → `x86_64-linux-gnu`, macOS →
   `aarch64-darwin`, BSDs/android/solaris by OS name, else the
   environment part), under the first `CRYSTAL_PATH` entry that has
   it, appended once. Changes what is indexed: cache patch bump.
2. **One fun lookup.** The lookup `lib_member_call` does (lib
   metaclass receiver, member by name and arity; struct/union field
   by name) is shared with IDE features, so hover, definition,
   references, rename, signature help and completion use the same
   site the type came from. Hover shows `fun LibX.cos(x : Float64) :
   Float64`, the C name when `fun a = "c_name"`, and the doc.
3. **Pseudo docs** are read from the stdlib's `docs_pseudo_methods.cr`
   (the compiler's own source for these docs), not copied. `Void`
   prints as `Void` in types.

**Undecided (needs approval):**

- `{% if flag?(…) %}` inside def bodies (R6): **moved to Phase 20**
  (level A: plain branches only).
- `asm(…)` hover: **decided, not done.** `docs_pseudo_methods.cr` has no
  `asm` entry (the parser alone handles it), so it stays an ordinary
  keyword without hover, like `while` or `begin`.

Steps (one commit each; pause at the end of each):

1. **lib_c target path (R1).** Specs: `LibC::UInt32T` hover and
   definition, `LibC.strlen` typed `UInt64`, `require "c/string"`
   resolves, a missing target directory changes nothing.

   *Done:* `Project.with_target_path` / `Project.lib_c_target` (the
   compiler's `Codegen::Target` normalisation: `i686` → `i386`, `arm64`
   → `aarch64`, `unknown-linux` → `linux-gnu`, darwin/BSD/android by OS
   name); the directory goes on `crystal_path`, so it is also in the
   local cache key. On the real stdlib: `LibC::UInt32T` → `stdint.cr:8`,
   `SizeT`, `PidT`, `SSizeT` resolve, `LibC.strlen` → `UInt64`,
   `grammar.cr`'s `ts_language_symbol_count` → `UInt32`. Types dump:
   repo +3 known, stdlib +119 known and 12 sharper (`Pointer(?)` →
   `Pointer(LibC::Passwd)`, `Slice(?)` → `Slice(LibC::EpollEvent)`).
   The one regression (`io/encoding.cr:129`) exposed a lowering bug,
   fixed separately (0.17.2): `{% skip_file %}` was ignored, so
   `io/encoding_stubs.cr` (skipped unless `without_iconv`) declared a
   second `IO::Decoder` whose `initialize` doesn't assign
   `@in_buffer_left`, making it `UInt64?` once `SizeT` resolved. The
   rest of a file now carries the negated condition (`skip_file if`,
   `skip_file unless`, `{% if %}{% skip_file %}{% end %}`); an
   unconditional one ends the file, an unknown condition keeps it. Two
   Windows-only fiber files now drop out of the Linux view (expected).
   Specs: `project_spec.cr` (target mapping, path), `lower_spec.cr`
   (`skip_file`), `features_phase18_spec.cr` (2). `make spec` 400
   examples.
2. **Fun navigation (R2).** Hover, definition, references, rename,
   signature help on fun, `$var` and field uses; fun and `$var`
   completion after `LibX.`. Specs on the fixture's shapes
   (reopened lib, variadic, `out`, proc param, enum return, real
   name).

   *Done:* `Infer#lib_member_call` records the fun / `$var` / field it
   matched as the call's resolution (`Unique`, `record_c_target`), so
   `call_at`, `CallFact` targets and signature help see it like a
   method; inference results are unchanged (types dump: 0 changes on
   repo and stdlib). `TypeInfo#c_decl_markdown`: `fun LibM.cos(x :
   Float64) : Float64` (+ `C name: `open`` for `fun a = "open"`, the
   type at the use, the doc), `LibM.errno : Int32` (C global
   variable `$errno`), `LibM::Point#x : Int32` (struct/union field).
   `References.callable?` adds funs, `$var`s and fields as declaration
   targets; references and rename of a field or `$var` include its
   setter uses (`pt.y = 3`). Signature help shows `, ...` for variadic
   funs. Completion after `LibM.` lists only its funs and `$var`s
   (function/variable kinds), after a lib struct/union value only its
   fields (no `new`, no Object methods). On `grammar.cr`:
   `tree_sitter_crystal`, `ts_language_abi_version`,
   `ts_language_symbol_count` hover and navigate; `ts_language_symbol_name`
   still doesn't (its `self` parameter, Phase 19), nor `LibC.free`
   inside `{% if %}` (macro bodies in HIR, not approved). Specs: 6 more
   in `features_phase18_spec.cr` (8). `make spec` 406 examples.
3. **Declaration hover (R3).** `fun` name, `$var`, field.

   *Done:* `TypeInfo#c_decl_hover` (before `decl_param_hover` in the
   hover chain): on a `fun` name, a `$var` or a lib struct/union field
   name (each name of `a, b : T`), the text uses show
   (`c_decl_markdown`), without the use's type. `decl_param_hover`
   also takes `fun_param` (`fun f(x : T)`); bare-type params
   (`fun f(T*)`) have no name to hover. On `grammar.cr`: the two `fun`
   declarations hover. Specs: 2 more (10). `make spec` 408 examples.
4. **Pseudo types and methods (R4).** Hover for `Void`, `NoReturn`,
   `sizeof` & co.; `Pointer(Void)` in hovers and hints.

   *Done:* `IDE::PseudoDocs` reads the stdlib's
   `docs_pseudo_methods.cr` (once per stdlib dir, through item
   lowering): `__crystal_pseudo_<name>` defs, `Object` pseudo-methods,
   `CRYSTAL_PSEUDO__<Name>` structs. Hover on the keyword of `typeof`,
   `sizeof`, `instance_sizeof`, `alignof`, `instance_alignof`,
   `pointerof`, `offsetof` (`Analysis#pseudo_hover`), on `Void` /
   `NoReturn` when no declaration of that name resolves, and on
   `x.is_a?`, `as`, `as?`, `nil?`, `responds_to?` (instead of
   "built-in (no source declaration)"). `TyKind::Void` (`TypeTable#void`)
   for an undeclared `Void` in a type: `Pointer(Void)` instead of
   `Pointer(?)`; a def declared `: Void` returns `Nil`, like a fun.
   Types dump: no regressions; repo 1 and stdlib 31 `Pointer(?)` →
   `Pointer(Void)`. Specs: 4 more (14). `make spec` 412 examples.
5. **Verification and docs.** Neovim check with a lib fixture; a
   hover probe over `lib_c/x86_64-linux-gnu` and
   `syntax/grammar.cr`; README, status, architecture; 0.18.0.

   *Done:* Neovim check `ffi` (fixture `tools/fixtures/ffi`, in `make
   nvim-check`): hovers, definition, references, completion and
   signature help on funs, globals and fields, `LibC.strlen` through the
   target path, `Pointer(Void)`, `sizeof`. Hover probe
   (`tools/probes/hover_probe.cr`) on the 45 files of
   `lib_c/x86_64-linux-gnu`: 32 without a miss; the rest are integer
   literals in constants and arguments (`0o2000000`, intentionally no
   hover), `flag?`/`{% %}` text, `Pointer(Void).new` / `.null` calls
   inside constant values (constants have no bodies), a `->` proc
   type, and the C name of `fun strerror_r = __xpg_strerror_r`, which
   now hovers (the fun's declaration text with `C name:`). On
   `grammar.cr`: what remains is `ts_language_symbol_name`/`_type`/
   `field_name_for_id` (the `self` param parse error, Phase 19),
   `LibC.free` / `GC.free` in `{% if %}` (Phase 20), `flag?`, `||`,
   `protected` and the `asm` string (keywords and operators, no hover
   by design). README, architecture, tools/README, gotchas (`fun` is
   reserved too), status; 0.18.0.

Status: done. `make spec` 412 examples; every Neovim check passes
(`ffi` added); `make verify-static` OK. 0.18.0.

Exit criterion: a C call hovers, navigates and completes like a
method call; `LibC` target types resolve; no regressions (`make spec`,
`make nvim-check`, `make verify-static`).

Moved to Phase 19: `fun f(self : T*, …)` parses as `self`, `ERROR`,
the rest (38 funs in the tree-sitter binding; `ts_language_symbol_type`
is untyped because of it).

### Fix round after Phase 18: bodies keyed by range (done)

Report: in a loose file (or any file) starting with `def add(a, b)`,
`foo = add 1, 2` and `bar = add "foo", "bar"` had no types and hover
on the second `add` was silent (`-32603 Index out of bounds`, which
Neovim doesn't show). Not about project roots: the same text as a
shard target failed too; a leading comment or item hid it.

Cause: the file body starts at its first item, here the def, and
several caches and dedupes used `body.range.start` as the body's
identity: `Typing@results` and per-body call facts (whichever body
ran first answered for both, with expression ids from the other),
`each_body_in` (inlay hints skipped the file body),
`References` body dedupes, and callers that asked `Bodies#at(0)` for
the file body (semantic tokens, warm-up) got the def's.

Fix: key/dedupe by `TextRange` (`@results`, call facts, `@trees`,
`Infer@yields_cache`, reference scans); `Bodies#file_body`,
`Typing#infer_body` and `#body_call_facts` for the file body; a def's
`forall`/`self.` no longer leaks into a file body that starts at it.
Specs: `features_body_key_spec.cr` (loose file and shard target, both
inference orders, leading blank lines: hover, inlay hints, references,
semantic tokens). 0.18.1.

Status: done. `make spec` 415 examples; every Neovim check passes;
`make verify-static` OK.

### Phase 19 — own tree-sitter-crystal

Replaces the policy in
[tree-sitter-grammar-notes.md](tree-sitter-grammar-notes.md) ("fixes
belong upstream; clear-ls does not patch it locally"): clear-ls
maintains its own grammar as a vendored dependency and fixes gaps
there, offering fixes upstream where they fit. Branch `dev/next`.

**Today (0.18.1):**

- The Makefile clones `crystal-lang-tools/tree-sitter-crystal` at
  `50ca9e6` (shallow, into gitignored `vendor/`) and compiles its
  committed `src/parser.c` (44 MB, generated by CLI 0.25.10) and
  `src/scanner.c` (3.2k lines, external scanner). `make syntax-gen`
  regenerates `kinds.cr` from `node-types.json`. The grammar commit is
  part of `Cache::BUILD_ID` (`tools/build_id.sh`: `+ts-<commit>`), so a
  grammar change already invalidates the item-tree packs.
- Upstream: last merge 2025-10-11 (`50ca9e6`, "Update to tree-sitter
  0.25.10"); 4 open PRs, among them #132 "keywords in type
  declarations" (open since 2025-06, rebased 2025-10: moves 46 keywords
  into the external scanner, rewrites ~2M lines of `parser.c`);
  several stale WIP branches (implicit object, pseudo-methods, endless
  heredocs, trailing `?`/`!` identifiers), 60–315 commits behind.
  Upstream CI: `tree-sitter test`, stdlib coverage with an expected-fail
  list, a parse-vs-compiler AST comparison (`test/crystal_parse_stdlib.cr`
  with `crystal_parse_stdlib_fail.txt`, 713 entries), `tree-sitter
  generate` + `git diff --exit-code`, eslint, ameba.
- Coverage: stdlib 1635/1646 files without `ERROR`/`MISSING` (99.33%,
  11 files, 7 constructs in the notes); clear-ls's shards 25/25;
  Marten + Athena 2041/2068 (98.69%, 27 files).

**Measured feasibility:**

- `tree-sitter generate` with the pinned CLI 0.26.9 (Node 26 present)
  takes ~33 s and reproduces `parser.c` byte for byte except the version
  banner; it also refreshes `src/tree_sitter/array.h`. `tree-sitter
  test`: 245/245 corpus cases + 9 highlight files pass, ~6 s. Compiling
  `parser.c`: ~5 s, 6 MB object.
- Probe fix, the `self` fun parameter: one line in `fun_param`
  (`alias($.self, $.identifier)` as a name). Afterwards `fun s1(self :
  Int32*, y : Int32)` parses as two `fun_param`s; corpus 245/245;
  stdlib (11 failing files), shards, Marten and Athena results
  unchanged. Not in any failing file: its effect is on clear-ls's own
  lowering (`ts_language_symbol_name` & 37 more funs in the
  tree-sitter binding).
- External failures by construct (27 files): regex strings like
  `"^(?|...(*:47)..."` in Athena route fixtures (8, string content
  mis-tokenised); short-block setters `&.x = v` / `&.x=(v)` (5, already
  a known gap); `.[1]` on a new line (2); keyword names
  (`getter? select`, 1); hash/named-tuple literals in specific
  positions (4); misc (7).

**Working copy (decided):** the grammar is developed in a local clone,
`../tree-sitter-crystal` (next to this repository), on branch
`clear-ls` from `50ca9e6`. The remote fork comes later (user creates
it and says so); until then the Makefile points at the local clone.
Upstream PRs: not now.

**Decisions:**

1. **Form: a fork, pinned by commit.** clear-ls commits on top of
   `50ca9e6` in the clone; `GRAMMAR_REPO`/`GRAMMAR_REV` in the Makefile
   name it. Keeps upstream history (570 commits), each fix a reviewable
   commit, and the 44 MB `parser.c` out of this repository. Rejected:
   copying the grammar into this repository; patches applied at build
   time.
2. **Generated output committed in the grammar repository** (upstream's
   convention): building clear-ls needs a C compiler only; Node and the
   tree-sitter CLI (pinned 0.26.9) only to change the grammar. The first
   grammar commit is the regeneration alone.
3. **Gates per grammar commit:** `tree-sitter test` (corpus +
   highlight); a corpus case per fix; `make grammar-check` loses no
   stdlib file; the external set (`lib/`, Marten, Athena) loses no file;
   `make syntax-gen` diff reviewed (renamed or removed `Kind`/`Field`
   fixed in clear-ls in the same step); `make spec`; types dump over
   repo and stdlib without regressions. Item caches are keyed by the
   grammar commit (`BUILD_ID`) already.
4. **Upstream #132 not taken** (scanner-side handling of 46 keywords,
   conflicts with keyword fixes, open 16 months).

**Gaps by kind** (each reproduced on a one-line input with the
`50ca9e6` grammar; "files" = stdlib / external files whose only or
first error it is):

*A. Fixes for limitations clear-ls already hit.*

| Gap | Example | Effect in clear-ls | Fix location (expected) |
|---|---|---|---|
| A1 `self` as a `fun` param name | `fun f(self : T*, y : U)` | the fun's params lower wrong: `ts_language_symbol_name` and 37 more funs of the tree-sitter binding have no hover / call typing (Phase 18 step 5) | `grammar.js` `fun_param`: name may be `self` (probe: 1 line, corpus 245/245, no file lost) |
| A2 short-block setter | `.tap &.keyword = k`, `&.flush=(true)`, `try &.driver_name = "x"` | an `ERROR` token in the call; clear-ls still finds the `driver_name` reference (recovered), but the call's shape (receiver, value) is lost: no value typing | `grammar.js` implicit-object call: allow `name=` assignment / call form after `&.` (stdlib 4, external 5) |
| A3 keyword accessor names | `getter begin : B`, `property end : Bool`, `getter? select : Bool = true` | worse than the accessor alone: in a probe, `struct R; getter begin : Int32 = 0; getter size ...` lowered `R` with **no** members and lost everything after it in the file (the next `struct` and its defs), "recovered from parse errors". `Range#begin`/`#end` hover nothing | `grammar.js`: keywords accepted as the name in a type declaration that is a call argument (narrow: accessor-style `call name : T`), not #132's scanner route (stdlib 2, external 1) |
| A4 regex with `#` | `/\A#<Foo:0x\h+>\z/`, `/a#b/` works, `/#</` doesn't | the regex swallows the rest of the line as a comment and never closes: in a probe, `def a` holding `x.should match /\\A#<A>\\z/` lost `a`, the following `def b` and a whole later `class After` from items ("recovered from parse errors"); Athena's `entity_manager_spec.cr` loses 83 lines | regex content: a lone `#` (not `#{`) is content. A token-level `#` didn't work in a probe (the `comment` extra still wins inside regex content), so this likely needs the regex body in the external scanner, which already lexes percent-literal bodies: **scanner** (external 1, plus any `#<` regex in user specs) |

*B. Small fixes for more syntax.*

| Gap | Example | Files | Fix location (expected) |
|---|---|---|---|
| B1 splat in array literal | `[*columns]`, `[*a, 1]` | external 1 | `grammar.js` array elements: allow `splat` |
| B2 `.[i]` on a continuation line | `x\n  .[1]` | external 2 | `grammar.js` / scanner line-continuation for `.` followed by `[` (check which) |
| B3 unnamed proc-type `fun` param | `fun f(B*, (Bio*) -> Int)` | stdlib 1 | `grammar.js` `fun_param` / type list: parenthesised proc type |
| B4 underscore call argument | `each_abbrev(bytes, _) do` | stdlib 1 | `grammar.js` argument: `_` (as in `case`/block params) |
| B5 index-query in a short block | `try(&.pos[name]?)` | stdlib 1 | `grammar.js` implicit-object index with `?` |
| B6 hash entry value is a call without parens followed by `,` | `{0 => f "a", 1 => 2}` | external 9 (Athena route fixtures, `bundle.cr`) | precedence of command calls inside hash/tuple entries (grammar first; if conflicts explode, defer to C) |

*C. Needs scanner work or broader changes: decide later.*

| Gap | Example | Files | Why bigger |
|---|---|---|---|
| C1 mixed hash/named-tuple keys | `{1 => [1], before: {a: 1}}` | external 1 | Crystal itself rejects this (`h = {1 => 2, b: 2}` is an error); Athena's is inside a macro-only constant. Not a grammar bug: drop |
| C2 `{{` as two tuple braces | `x = {{2 => 3}, 1}` | external 1 (in a `{% if %}`) | the compiler also reads `{{` as a macro expression start (needs `{ {`): not a grammar bug: drop |
| C3 escaped macro inside a macro | `\{% if Int{{n}} == ... %}` | stdlib 1 | macro-content scanner state |
| C4 `#` handling in other literal bodies | regex as A4 if a grammar-level fix is impossible | — | scanner (moved here if A4 needs it) |
| C5 keywords everywhere as names | `def select`, `x.end`, named args `begin:` | — | #132's approach (scanner keyword tokens); only if A3's narrow fix leaves real gaps |
| C6 error recovery for half-typed code | `@[` alone, `@[JSON::` eating the next `def`, unclosed `def foo(` swallowing defs | — | precedence / recovery tuning with unclear payoff; clear-ls works around (`AnnotationContext`, `lower_error`, previous item tree). Measure before touching |

Steps (one commit each in this repository; grammar commits on
`clear-ls` in `../tree-sitter-crystal` first; pause at the end of each):

1. **Local grammar and pin.** Grammar repo: CLI-0.26.9 regeneration
   commit. Makefile: `GRAMMAR_REPO` = the local clone (a path; fork URL
   later), `GRAMMAR_REV` = that commit; `grammar-test` (`tree-sitter
   test` in `vendor/`); `grammar-check-ext` (`lib/`, Marten via
   `tools/external.sh`, Athena added there). Notes: new policy and
   workflow (edit `grammar.js` → generate → test → commit in the clone
   → bump `GRAMMAR_REV` → `make distclean`-free refresh of `vendor/` →
   `syntax-gen` → specs). Patch bump (grammar pin).

   *Done:* grammar `clear-ls` branch: `557ee42 chore: regenerate with
   tree-sitter-cli 0.26.9` (`parser.c` banner, `tree_sitter/array.h`).
   Makefile: `GRAMMAR_REPO` = `$(abspath ../tree-sitter-crystal)`,
   `GRAMMAR_REV` = `557ee42…`; `grammar-update` (fetches the pinned commit
   into the shallow `vendor/` clone, rebuilds the archive; `make`
   relinks); `grammar-test`; `grammar-check-ext` over `lib/`,
   `tools/external/marten/src`, `tools/external/athena/src` (Athena
   `d6b704c` added to `tools/external.sh`, sources only).
   `tools/grammar/coverage.sh save|check` (no-file-lost gate). Baseline:
   corpus 245/245; stdlib 1635/1646 (11 failing); external 2040/2068 (28
   failing: lib 25/25, Marten, Athena with tests). A fresh clone builds
   from the local grammar. Notes (policy, workflow), development.md,
   tools/README. `make spec` 415 examples. 0.18.2.
2. **A1 `self` fun param.** Grammar + corpus case; clear-ls spec: a fun
   with a `self` param lowers with both params, hovers and types its
   call (`ts_language_symbol_name`).

   *Done:* grammar `f6381f4 feat: allow self as a fun param name`
   (`fun_param` name may be `self`, aliased to `identifier`; the compiler
   accepts it for `fun` in a lib and at top level, rejects it for `def`,
   whose rule is unchanged) + corpus case "fun params named self"
   (246/246). `kinds.cr` unchanged. Coverage: stdlib 11 → 11, external
   28 → 27 (`lib/tree_sitter/src/lib_tree_sitter.cr` now parses: the 38
   `self` funs). On `grammar.cr`: `ts_language_symbol_name`,
   `ts_language_symbol_type` (→ `TSSymbolType`, so `type.regular?`
   resolves), `ts_language_field_name_for_id` hover and navigate.
   Types dump: repo +3 known (`grammar.cr:84 type`, `node.cr:158 raw`,
   `tree.cr:141 raw`), stdlib unchanged. Spec `features_phase19_spec.cr`
   (1). `make spec` 416 examples. 0.18.3.
3. **A2 short-block setters.** Grammar + corpus cases (`&.x = v`,
   `&.x=(v)`, `&.x += v` if cheap); clear-ls: setter references /
   rename include these uses; block-form conversion.

   *Done:* grammar `37c0a06 feat: short-block assignment &.x = v`:
   `block_argument` also takes `implicit_object_assign` /
   `implicit_object_operator_assign` (aliased `assign` / `op_assign`
   with an `implicit_object_call` lhs, also chained `&.a.b = v`, and
   `&.x=(v)`); comparisons (`&.a == b`, `<=`, `!=`, `=~`) unchanged; the
   `todo.txt` `:error` case moved to `expressions.txt` (corpus 246/246).
   `node-types.json`: `implicit_object_call` added to `assign`/`op_assign`
   lhs; `kinds.cr` unchanged. clear-ls: `LowerBody#lower_block_argument`
   treats such an assignment as a short block; the setter name
   (`name=`) comes from the parent assign instead of the old `ERROR`
   workaround; `Infer#implicit_receiver` skips the assign between the
   call and the block; `setter_value` passes the assigned value. Now
   `c.try &.name = "x"` hovers / goes to `Conn#name=` (was "built-in, no
   source declaration"), `&.count += 1` resolves, references and rename
   unchanged (they already found the use). Block-form conversion only
   applies to `{}` / `do` blocks (not affected; plan text corrected).
   Coverage: stdlib 11 → 7 (`semantic/exception.cr`, `syntax/parser.cr`,
   `unix`/`wasi` `file_descriptor.cr`), external 27 → 21 (4 Athena,
   2 Marten). Types dump: repo and stdlib unchanged. Specs: 2 more (3).
   `make spec` 418 examples; Neovim checks unchanged. 0.18.4.
4. **A3 keyword accessor names.** Grammar + corpus; clear-ls: `Range`'s
   `begin`/`end` accessors appear in items (stdlib `range.cr` parses),
   completion `r.be` → `begin`.

   *Done:* grammar `6aa6b29 feat: keywords as accessor names`: a new
   `keyword_type_declaration` (aliased `type_declaration`) in call
   argument lists (all six `args` choices): one token
   `<keyword>[ \t]+:[ \t]` for 30 keywords (`begin end else elsif
   ensure rescue then when in do case select if unless while until with
   yield self true false nil asm typeof sizeof instance_sizeof alignof
   instance_alignof pointerof offsetof`; the compiler rejects `as`,
   `is_a?`, `nil?`, `out`, `responds_to?` there), then the type and an
   optional `= value`. Measured first which keywords failed: 34 of 63
   (the rest already parsed as identifiers). `if`/`unless`/`rescue`/
   `ensure` are external-scanner keywords: the scanner now yields (no
   token) when such a keyword is followed by ` : `, with `mark_end` at
   the keyword so a "no" leaves the keyword token unchanged (a first
   try without it broke `if ::File...` in 11 files). Two-token
   variants (keyword alone, separator apart) were tried and dropped:
   the plain keyword string conflicts with every statement keyword, and
   a scanner-emitted keyword token collides with the scanner's own
   keyword handling. Consequence: the `var` node's text is `begin : `
   (keyword plus separator); clear-ls trims it (`Lower#name_of` for
   accessors and records, `LowerBody#lower_type_decl`). Corpus: todo
   case moved to `statements.txt` ("keywords as accessor names");
   "too many heredocs" (an `:error` test past the scanner's 16-heredoc
   limit) recovers differently, expected tree updated (still an error).
   `node-types.json` and `kinds.cr` unchanged. Coverage: stdlib 7 → 4
   (`range.cr`, `syntax/ast.cr`, `crystal_llvm_builder.cr`), external
   21 → 20. Types dump: stdlib +10 known (`Range#begin`/`#end` uses),
   repo unchanged. `r.begin`/`r.end` hover `Range#begin() : B` → `Int32`
   and go to `range.cr`.

   Also fixed: `make grammar-check`, `grammar-check-ext` and
   `grammar-test` ran the CLI's cached `~/.cache/tree-sitter/lib/
   crystal.so`, built from whichever checkout compiled it last; now
   `-r` (rebuild). Earlier step results were re-checked from clean
   worktrees (557ee42: 11/28, f6381f4: 11/27, 37c0a06: 7/21): correct.
   Specs: 2 more (5). `make spec` 420 examples. 0.18.5.
5. **A4 regex `#`.** Try the grammar route once more; if it needs the
   scanner, do the smallest scanner change (regex body like percent
   literals) only if it stays local, else move it to C with notes.
6. **B1–B6**, one grammar commit each (or grouped when tiny), each
   with a corpus case; any that turns into a conflict storm or scanner
   change moves to C.
7. **Verification and docs.** `make grammar-check` (expect ≥1640/1646
   stdlib), `grammar-check-ext`, types dump, Neovim checks; notes:
   "Known gaps" rewritten with the C list; README, status; 0.19.0.

Exit criterion: clear-ls builds from the pinned clear-ls grammar
without Node or the CLI; A1–A3 parse (A4 parses or is recorded in C);
no stdlib or external file lost; no regressions (`make spec`, `make
nvim-check`, `make verify-static`, types dump).

### Fix round during Phase 19: type doc from a reopening (done)

Report (reading `lsp/diagnostics.cr`): hover on `File` showed
``class File < IO::FileDescriptor`` and `_6 declarations_`, no doc;
the API docs show it. `file.cr` opens `class File < IO::FileDescriptor;
end` doc-less on line 1, before its requires, and documents the
reopening on line 7.

Cause: `IDE::Analysis#hover` described only `sites.first`, header and
doc. The compiler keeps the first doc it sees (`TopLevelVisitor#attach_doc`:
`type.doc ||= node.doc`); `DefMap::TypeInfo#doc` (completion) already
did.

Fix: header from the first declaration, doc from the first that has
one. `File` and `IO::FileDescriptor` (`io/console.cr` comes first) now
show their docs; `Process` and `Int32` have none anywhere in the
stdlib. `Crystal::System` now shows `:nodoc:` raw (its first doc):
doc directives are Phase 21. Spec: `features_type_doc_spec.cr`. 0.18.6.

Status: done. `make spec` 421 examples; every Neovim check passes;
`File` hover checked in headless Neovim.

### Declarations in `{% begin %}` and macro-split signatures

Found with the fix round above (`File.read` / `File.write` in
`lsp/diagnostics.cr`). Planned after Phase 19, before Phase 20: it
fixes the declaration level that Phase 20 builds on, and needs no HIR,
CFG or inference work. Small; released as a patch of 0.19.

**Today (0.18.6):** `File.` completion lists 56 class methods without
`read`, `write`, `new`, `open`, `each_line`, `read_lines`; hover on
`File.read` / `File.write` is empty and definition `[]`; `File.new`
falls back to `File.class#new : File — built-in (no source
declaration)`. `dump-items file.cr` leaves the 7 defs out. They read:

```crystal
{% begin %}
  # doc…
  def self.read(filename : Path | String, encoding = nil, invalid = nil, {% if compare_versions(Crystal::VERSION, "1.5.0") >= 0 %} @[Deprecated] {% end %} blocking = nil) : String
{% end %}
```

Two gaps in `Items::Lower`, each reproduced on a small file:

1. **`{% begin %}` is not lowered.** `lower_stmt` handles
   `macro_if` / `macro_unless` (`lower_macro_if` → `lower_macro_body`)
   but no case reads `macro_begin`: a plain documented def inside
   `{% begin %} … {% end %}` gives no item.
2. **A nested `{% if %}` splits a statement.** `lower_macro_body`
   flushes its `macro_content` ranges at each nested `macro_if` and
   reparses each run alone, so `def self.read(…, ` and ` blocking =
   nil) : String …` are two broken halves. Inside an outer `{% if %}`
   the def is lost too, while a plain def in the same branch is kept.

**Measured** (stdlib 1.22.2 without `compiler/` and `spec/`; macro
blocks outside defs; a probe that reparses each block body with every
`macro_content` range in one call, the nested macro nodes left out as
gaps):

| | blocks | defs today | defs with gaps |
|---|---|---|---|
| `{% if/unless %}` | 479 | 136 | 137 |
| `{% begin %}` | 30 | 0 | 19 |

+20 defs, none lost, 7 files: `file.cr` +7 (`new`, `open` ×2, `read`,
`each_line`, `read_lines`, `write`), `socket.cr` +5
(`tcp`/`udp`/`unix`, 2 `initialize`), `socket/tcp_socket.cr` +3
(`new`, 2 `initialize`), `fiber.cr` +2 (`new`, `initialize`),
`concurrent.cr` +1 (`spawn`), `io/file_descriptor.cr` +1 (`new`),
`crystal/tracing.cr` +1 (the `{% if %}` case). No recovered def has
`{{ }}` in its signature. The other `{% begin %}` blocks hold
expressions (`int.cr`: `{% begin %} if … {{@type}}::MIN …`) or
`{% for %}`-generated `case`s (`crystal/tracing.cr`).

Typing has the same split: `IDE::Typing#def_node` reparses a closed
file's def by its item range (`parse_ranges(text, [r])`), which would
still hold the inner `{% if … %} … {% end %}` (`File.write` has no
return type, so its return is inferred). Already true today, not
changed here: in an *open* file a def inside any declaration-level
macro block has no `method_def` node in the file's tree, so its body
has no locals or inference (`Bodies`), and `def_node` (which uses the
open tree) finds no node, so callers lose its inferred return type
while that file is open (probed: `x = Foo.ok(1)` is `Int32` with
`lib.cr` closed, untyped with it open; same with a plain `{% if
flag?(:linux) %}`).

**Design decisions:**

1. **Gaps, not substitution.** A macro body is reparsed once with
   every `macro_content` range; nested `{% if %}` / `{% for %}` /
   `{{ }}` / `{% %}` are left out (included ranges skip them).
   Declarations inside a nested `{% if %}` branch are still lowered
   by the recursive `lower_macro_if` under its condition; that branch
   is *not* also spliced into the enclosing text. For the stdlib case
   this drops `@[Deprecated]` on `blocking`, which no feature reads.
   Choosing a branch (then / else by `Cond`) was rejected: the
   conditions here are `compare_versions`, and a branch can be a
   whole parameter (`fiber.cr`: `execution_context : … ,`), so
   neither choice is right for every case.
2. **`{% begin %}` lowers like an unconditional `{% if %}` branch**:
   same `lower_macro_body`, no condition pushed.
3. **No `{{ }}` guard beyond the grammar.** A declaration whose name
   holds `{{ }}` parses as `ERROR` around a fragment (probed:
   `def {{name.id}}(x)`), which `lower_body` already skips. The
   generated names stay compiler facts (Phase 7).
4. **Typing reuses the gaps.** `def_node` reparses a def with the
   item range minus the macro nodes inside it (found by one parse of
   that range), so the body sees the same signature the item has;
   for an open file it does the same on the buffer's text when the
   tree has no `method_def` at the item's range (the open-file
   return-type loss above).

Steps (one commit each):

1. **Lowering.** `lower_macro_body` reparses once with gaps (decision
   1); `macro_begin` lowered (decision 2). Specs (`items/lower_spec.cr`):
   a def in `{% begin %}` with its doc; a def whose params hold `{% if
   %} @[A] {% end %}` inside `{% begin %}` and inside `{% if flag?(…)
   %}` (keeps the condition); a nested branch's own def still lowered
   under its condition; `def {{name.id}}` gives no item. Patch bump
   (item lowering).
2. **Typing.** `def_node` with gaps (decision 4). Spec: a
   `File.write`-like def in another file, no return type, `{% if %}`
   in its params: the call's type is inferred with that file closed
   and open.
3. **Verification.** Probe on `lsp/diagnostics.cr`: completion after
   `File.` has `read`/`write`/`new`/`open`; hover and definition on
   `File.read`, `File.write`, `File.new`, `spawn`, `Socket.tcp`. Items
   dump diff over the stdlib (the +20 above, nothing else); types dump
   (no regressions); `make spec`, `make nvim-check`.

Out of scope: locals, hover and inlay hints *inside* the body of a
def that sits in a macro block of an open file (`Bodies` works on the
file's tree; with Phase 20, which models macro nodes in bodies);
`{% for %}`-generated declarations.

### Phase 20 — `{% if %}` inside method bodies

Planned for later (decided after Phase 18's review; order relative to
Phase 19 open). Not specific to C bindings.

**Today (0.17.2):** declaration-level `{% if/unless %}` branches are
reparsed and lowered under their condition (`Items::Lower`; `{% begin
%}` and a `{% if %}` inside a signature are not: see "Declarations in
`{% begin %}` and macro-split signatures" above, which comes first), but in a
method body every macro node is one opaque `Missing` expression
(`HIR::LowerBody`): no locals, calls, hover or definition inside, e.g.
`LibC.free(ptr)` in `Syntax.free_native`. Compiler facts don't help:
they report methods and ivars, not calls in bodies.

**Measured** (method bodies, not `macro` defs; stdlib without
`compiler/` and `spec/`, clear-ls `src`, Marten, Athena components):

| | stdlib | clear-ls | Marten | Athena |
|---|---|---|---|---|
| `{% if/unless %}` | 371 | 5 | 2 | 46 |
| branches plain Crystal text | 310 | 4 | 2 | 35 |
| … that parse alone | 310 | 4 | 2 | 35 |
| `flag?`-only condition | 185 | 3 | 1 | 2 |
| a branch with `{{ }}` | 9 | 0 | 0 | 7 |
| a branch with `{% for %}` / `{% %}` / nested `{% if %}` | 52 | 1 | 0 | 4 |
| `{% for %}` in a body | 50 | 1 | 4 | 6 |
| `{{ }}` directly in body code | 114 | 0 | 2 | 12 |

**Scope (level A):** branches of `{% if/unless/elsif/else %}` made of
`macro_content` only. Out of scope: a branch holding `{{ }}`, `{% for %}`
or a `{% %}` statement (stays opaque, as today); `{% for %}` and `{{ }}`
in bodies (their output needs macro evaluation with type information:
compiler territory). Placeholder substitution for `{{ }}` was rejected:
an interpolation can be a name, a type, a statement or part of an
identifier, so any placeholder is a guess.

**Design decisions:**

1. Each plain branch's `macro_content` ranges are reparsed with
   `parse_ranges` (as `Items::Lower#lower_macro_body`) and lowered as
   code, so hover, definition, references and rename work in every
   branch, the inactive ones (`win32` on Linux) included.
2. Type flow: with a `flag?`-only condition (`Items::Cond` evaluates to
   true/false), the active branch flows like ordinary code and the
   inactive ones are analysed but don't flow into what follows. With any
   other condition (`T == Bool`, `compare_versions`, constants), each
   branch is analysed as an alternative and none flows into what follows.
3. Locals: one binding per name across branches; its type after the
   `{% if %}` is the active branch's (flag case) or unchanged (other).

Steps (to split before starting): HIR branch node and lowering; CFG and
inference rules above; IDE features over the new nodes; verification
(types dump over the stdlib: ~310 sites change, no regressions allowed;
hover probe on `grammar.cr`'s `free_native`).

### Phase 21 — constant hover, compiler constants, doc directives, generic class methods

Found in use after Phase 19 step 3 (0.18.1, `dev/next` at `332963d`).
Planned after Phase 20. Probed with `tools/lsp_client.py` on a loose
file, compiler integration off.

**Today:**

- **Constant hover shows the value text, not the type.** `ARGV` →
  ``ARGV = Array.new(ARGC_UNSAFE - 1) { |i| String.new(ARGV_UNSAFE[1 + i]) }``;
  `STDIN`, `STDOUT`, `PROGRAM_NAME` the same. Constant hover falls
  through every `TypeInfo` hover in `LSP::Features#hover` to
  `IDE::Analysis#hover`, which is declaration-only: `describe`
  prints `full_name = item.detail`. Inference already types the
  constant (`Infer#const_type` → `const_value_type` →
  `const_expr_type`, summary-cached): `x = STDOUT` hovers as
  `x : IO::FileDescriptor`, `e = PROGRAM_NAME` as `String`.
- **Compiler-defined constants have no declaration.** `ARGC_UNSAFE`,
  `ARGV_UNSAFE` (used by `ARGV`, `PROGRAM_NAME` in `kernel.cr`):
  hover gives nothing, `c = ARGC_UNSAFE` gives `c` with no type.
  `Crystal::VERSION` (used in `{% compare_versions %}` across the
  stdlib): same. `__FILE__`/`__LINE__`/`__DIR__` already type
  (`pseudo_constant`), with no hover on the keyword.
- **Generic args lost on explicit class methods of a bare generic.**
  `Array.new(3) { |i| "x" }` → `Array` (so `ARGV` would still hover
  as `Array` once constants show their type). See "Generic args from
  class-method calls" below for the category.
- **Doc directives are shown raw.** The second `sprintf` in
  `sprintf "%s", "hi"; sprintf "%s", ["hi"]` resolves to
  `def sprintf(format_string, args : Array | Tuple)` whose doc is
  `:ditto:`; hover shows `:ditto:`. Only completion knows about
  `:nodoc:` (`completion.cr`, hides internal methods). Since 0.18.6
  type hover takes the first doc of any reopening, so
  `Crystal::System` hovers as `:nodoc:`.

**Measured** (stdlib 1.22.0 without `compiler/`, doc comment lines):

| directive | uses | compiler semantics |
|---|---|---|
| `:ditto:` | 285 (14 with text after) | `TopLevelVisitor#check_ditto`: the doc of the previous *documented* def / macro / constant / fun / assign in visiting order; `:ditto:` + more lines appends them after a blank line |
| `:nodoc:` | 811 (118 with text after) | `Doc::Generator#nodoc?`: doc starts with `:nodoc:`, item left out of the API docs (and its namespace's members) |
| `:inherit:` | 63 | `Doc::Method#compute_doc_info`: a line `:inherit:` is replaced by the doc of the ancestor method with the same signature strictness; a def with no doc copies the previous overload's (`previous_def_docs`) or the ancestor's ("Description copied from …") |
| `:showdoc:` | 0 | lchopped; makes `private` / lib items documented |

Compiler constants (`compiler/crystal/program.cr`, 1.22.0), the full
list of `Const.new` in the compiler:

| constant | where | value | type |
|---|---|---|---|
| `ARGC_UNSAFE` | `Program#initialize` (253) | `Primitive("argc")` | `Int32` |
| `ARGV_UNSAFE` | (254) | `Primitive("argv")` | `Pointer(Pointer(UInt8))` |
| `Crystal::BUILD_COMMIT` | `define_crystal_constants` (310) | compiler build | `String \| Nil` (Nil for dev builds) |
| `Crystal::BUILD_DATE`, `CACHE_DIR`, `DEFAULT_PATH`, `DESCRIPTION`, `PATH`, `LIBRARY_PATH`, `VERSION`, `LLVM_VERSION`, `HOST_TRIPLE`, `TARGET_TRIPLE` | (320–359) | compiler config / env | `String` |
| `Crystal::USER_FLAGS`, `ALL_FLAGS` | (360–365) | `-D` flags / all flags | `Array(String)` |

**Generic args from class-method calls** (`MyBox(T)` with
`initialize(@v : T)`; compiler column from `typeof`, 1.22.0):

| call | clear-ls | compiler | gap |
|---|---|---|---|
| `Array.new(3) { "x" }`, `Deque.new(3) { 1 }` | `Array`, `Deque` | `Array(String)`, `Deque(Int32)` | A |
| `Pointer.malloc(3) { 1.5 }`, `Iterator.of { 1 }` | `Pointer(?)`, `…SingletonProcIterator(?)` | `Pointer(Float64)`, `…(Int32)` | A |
| `Set.new([1])`, `Deque.new([1])`, `Slice.new(3, 1)` | `Set`, `Deque`, `Slice` | `Set(Int32)`, `Deque(Int32)`, `Slice(Int32)` | B |
| `Pointer.malloc(3, 1)`, `Iterator.of(1)`, `Hash.zip([1], ["a"])` | `Pointer(?)`, `…(?)`, `Hash(?, ?)` | `Pointer(Int32)`, `…(Int32)`, `Hash(Int32, String)` | B |
| `MyBox.wrap(1)` (`def self.wrap(v : T); new(v); end`) | `MyBox(?)` | `MyBox(Int32)` | B |
| `Range.new(1, 2, exclusive: true)`, `P1.new(1, flag: true)` (`initialize(@a : A, @flag = false)`) | `Range`, `P1` | `Range(Int32, Int32)`, `P1(Int32)` | C |
| `Slice.new(3) { 1.5 }` (`&` unrestricted) | `Slice` | `Slice(Float64)` | A via body |
| `Array(typeof(x)).new` | `Array(?)` | typed | D |
| `StaticArray(Int32, 3).new { }` | `StaticArray(Int32, ?)` | `StaticArray(Int32, 3)` | E |

What already works, for contrast: `Array(String).new(3) { }` (args
given), `Array.new(3, "x")` and `MyBox.new(1)` (no explicit
`self.new`: `Infer#instance_from_initialize` unifies `initialize`'s
restrictions against open params), `[1].map { "x" }` (`forall U`
from the block: `free_var_bindings`), `MyBox.make { 1 }` when the
body is `new(yield)` (summary). `Hash.new(0)` → `Hash` is right: the
compiler rejects it (K, V unbound).

Causes:

- **A, B** — one mechanism. With a bare generic metaclass receiver,
  `generic_bindings` binds the owner's params to unknown; `arg_bindings`
  and `free_var_bindings` return early when the def has no `forall`
  (`sig.free_vars.empty?`), so owner params are never unified against
  argument types or the block's value; `declared_return` returns
  `self_t` (bare `Array`) for an unannotated `new` before looking any
  further. `instance_from_initialize` does the right thing, but only
  for implicit `new`.
- **C** — a resolver bug, not generics: `Param#call_name` keeps the
  `@` of `@flag`, so a named argument never matches an ivar parameter
  (`CallResolver#bind`), the candidate is dropped, and the call has no
  resolution: no type, no definition (`Q.new(flag: true)` → `[]`),
  no signature help. 696 stdlib defs have an `@param`.
- **D** — `typeof` in a type argument; Phase 6 decision 3 territory,
  13 of the stdlib's open-arg locals. **E** — numeric params, not
  modelled.

Frequency (types dump of locals, def bodies): stdlib 5177 locals, 91
bare-generic or `?`-arg ones, ~17 from A/B/C, 13 from D; the rest are
unions/macro aliases (Marten's `Hash(String, ?)` come from
`alias Any = Union({{TYPES.splat}})`, a macro-built alias, not this).
Call sites with a bare generic receiver and arguments: stdlib 222,
Athena 4, Marten 0, clear-ls 1.

16 in all, each with a compiler-side doc string (except the two
`*_UNSAFE`). Not user-visible, so out of scope: `$Regex:n` /
`$Slice:n` (literal expander, main visitor: hidden constants for regex
and slice literals) and enum members from `EnumType#add_constant`
(`@[Flags]` `None`/`All`, already handled in `Infer#const_type`).

**Design decisions:**

1. **Constant hover: type first, value second.** A `TypeInfo#const_hover`
   ahead of `Analysis#hover` in the hover chain, for a constant
   reference or declaration name that resolves to a constant (not a
   type): `NAME : T` from inference, then the value expression as a
   secondary line, then the doc. Unknown type: today's `NAME = value`.
   Value text is shown as is up to one line / ~80 chars, else
   truncated with `…` (data tables are thousands of bytes). Enum
   members keep their enum type. Aliases and types are unaffected.
   Shape:

   ````md
   ```crystal
   ARGV : Array(String)
   ```

   = `Array.new(ARGC_UNSAFE - 1) { |i| String.new(ARGV_UNSAFE[1 + i]) }`

   An array of arguments passed to the program.
   ````
2. **Built-in compiler constants table.** `IDE::CompilerConstants`,
   like `IDE::Annotations::BUILTINS` (Phase 17): name, owner (top
   level or `Crystal`), type text, doc. The doc is the compiler's own
   (copied from `define_crystal_constants`); `ARGC_UNSAFE` /
   `ARGV_UNSAFE` get a written one (the argc/argv given to `main`,
   read by `ARGV` and `PROGRAM_NAME`; prefer those). Each entry notes
   "defined by the compiler (`compiler/crystal/program.cr`), no source".
   The module header documents where the list comes from, why it
   exists (no declaration in any `.cr` file the DefMap indexes) and how
   to refresh it on a Crystal upgrade (`rg 'Const.new|define_crystal_'
   compiler/crystal/program.cr`). Used by inference (`const_type`
   falls back to it after the scope chain), hover (no definition
   location, as built-in annotations) and completion (`Crystal::`,
   top-level constants). A source declaration of the same name wins.
   Values are not shown: they are the analysing compiler's, and only
   compiler facts could know the build's (`-D` flags).
3. **Owner type params from class-method calls (A, B).** With a
   bare generic metaclass receiver (`Array`, not `Array(X)`), the
   candidate's owner params start open (`type_param`, as
   `instance_from_initialize` does) instead of unknown; `arg_bindings`
   unifies owner params as well as `forall` vars from argument
   restrictions, then `free_var_bindings` from the block's value
   (`& : Int32 -> T`); `declared_return` applies them to `self`, a
   declared return (`Pointer(T)`) or a summary. Params still open
   afterwards become unknown (`still_open?`), so nothing worse than
   today leaks out. Explicit args (`Array(String).new`) are never
   overridden. "A via body" (`Slice.new(n) { }`) may follow from the
   summary once A works; verify, don't target. D and E out of scope.
   Not its own phase: one mechanism in `infer.cr` (three methods),
   but its own step with the inference regression workflow
   (`types_dump` + `types_diff.py` on stdlib, Marten, Athena;
   `book_diff.py`).
3a. **Named arguments to `@ivar` params (C).** `call_name` drops the
   `@`/`@@` (the compiler's external name for `@flag` is `flag`).
   Fixes resolution, not just types; first step of the phase (also
   affects definition, references, signature help).
4. **Doc directives**, resolved where docs are read (one helper used
   by hover, completion documentation, signature help):
   - `:ditto:` (alone or followed by text): the doc of the previous
     documented item in the same file and namespace in source order,
     as `check_ditto` (its `@last_doc` is the last doc seen in
     visiting order, so a `:ditto:` chain resolves to the first real
     doc); the extra text appended after a blank line. Unresolvable:
     drop the directive, show nothing.
   - `:inherit:` line: the doc of the same-name method in the nearest
     ancestor (`DefMap#ancestors`), matched by name and arity (not the
     compiler's full restriction strictness); unresolved: the line is
     dropped.
   - No doc at all on a def: the previous overload's doc in the same
     owner (`previous_def_docs`), else the ancestor's, marked
     "_Description copied from `Owner`_" as `crystal docs` does.
   - `:nodoc:`: the doc is not shown at all (hover shows the
     signature only, no note); completion keeps hiding these.
   - `:showdoc:`: stripped.

**Open:** whether the doc helper caches resolved docs (285 dittos;
cost is a sibling scan per hover, probably negligible).

Steps (to split before starting): named args to `@ivar` params (3a);
owner params from class-method calls (3, inference regression
workflow, no regressions allowed); constant hover (1); compiler
constants table + inference/hover/completion (2); doc directives (4).
3 before 1 so `ARGV` hovers as `Array(String)` when 1 lands.
Verification: specs per step; the table above as a fixture (each row
matches the compiler or stays a listed gap); LSP probe on `ARGV`,
`STDIN`, `PROGRAM_NAME`, `ARGC_UNSAFE`, `Crystal::VERSION`, the
`sprintf` pair; `make nvim-check` hover float.

## Testing approach

- Snapshot tests for representations (`dump-cst`, later items and HIR).
- Property tests for incremental parsing and position conversion.
- Differential tests against the compiler on complete fixtures; record
  disagreements as approximation, unsupported, bug, or version difference.
- `make grammar-check` tracks grammar coverage of the stdlib.
