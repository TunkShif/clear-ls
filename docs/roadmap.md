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

Not yet: references search one root (Phase 13 multi-root); reference
search is on demand (no persistent index; first search over a large
program infers its candidate bodies); method references inside macro
bodies and `{{...}}` are not found; rename of a method reached through a
`responds_to?`/duck-typed call is refused rather than guessed.

### Phase 10 — responsiveness

The original "hardening" phase is split into three: responsiveness
(here), startup and warm caches (Phase 11), multi-root (Phase 13).

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

### Phase 14 — keyword snippets and require completion

From usage feedback on 0.12.2: built-in snippets for common structures
(definitions, control flow, `do ... end`) and completion inside
`require "..."`. Runs before Phase 13 (multi-root), which moves to last.

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
2. **`do ... end`.** Decision 4. Specs: block method with named
   `yield` args, block method with placeholders, non-block method (no
   item), unresolved call (plain form), `foo arg d|`, after `{` (no
   item), setting off.
3. **Exhaustive case.** Decision 5, each subject kind from the checks
   above, partial `case` (missing branches only), `when` vs `in`,
   Flags enum and unknown type (no item). A spec compiles each
   generated `case ... in` with the compiler (fixtures for enum,
   nilable enum, union, Bool, abstract class) and expects no
   exhaustiveness error.
4. **Definition and control-flow snippets.** Decision 3 forms
   (`class ${1:Name}\n\t$0\nend`, `def ${1:name}\n\t$0\nend`,
   `if ${1:cond}\n\t$0\nend`, `begin\n\t$1\nrescue ${2:ex}\n\t$0\nend`,
   ...), off by default; gating specs (no `if` snippet in modifier
   position, no `class` inside a def).
5. **Require paths (R1, R2).** Context detection (including
   unterminated strings), local/stdlib/shard listing per the rules
   above, trigger characters. Specs over a fixture with `lib/` shards
   (direct and transitive, a `lib/x/lib` symlink loop, a shard named
   like a stdlib file): only direct names offered, no subpaths, no
   globs, internals hidden, bare directories not offered. A round trip
   over every stdlib directory: each offered string resolves to its
   file. A regression spec that hover/definition still resolve
   `marten/cli`-style subpaths, transitive shards and globs.
6. **Require details (R3).** Top-level declarations and leading doc;
   shard version/description from its `shard.yml`; skip files outside
   the index (no detail rather than a parse per
   item).
7. **Verification and docs.** Neovim `editing` check: accept
   `xs.each do` (block params selected), an exhaustive `in` on an enum
   and a union, `require "./` → a file, `require "js` → `json`; with
   endwise-style auto `end` documented. README features, settings doc,
   status, architecture (Editing UX).

Exit criteria: with default settings only `do ... end` and case
snippets appear; every generated `case ... in` compiles without an
exhaustiveness error on the fixtures; no structural snippet in
modifier position; every require suggestion resolves to the file it
names (stdlib round trip), shards appear by direct name only and no
glob is offered; completion outside require strings is
unchanged (existing specs, Neovim check).

### Phase 13 — multi-root (deferred, last)

Moved after Phase 14: the last planned phase, still deferred until asked
for.

- One index per workspace folder sharing stdlib/shard entries (cheap
  with the Phase 11 cache); `workspace/didChangeWorkspaceFolders`.
- Diagnostics and compiler facts per project, in its own directory
  (nested projects use the root's toolchain today).

Exit criterion: two folders open in one client, each with correct
definitions and diagnostics.

## Testing approach

- Snapshot tests for representations (`dump-cst`, later items and HIR).
- Property tests for incremental parsing and position conversion.
- Differential tests against the compiler on complete fixtures; record
  disagreements as approximation, unsupported, bug, or version difference.
- `make grammar-check` tracks grammar coverage of the stdlib.
