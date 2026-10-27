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
- [Tree-sitter grammar notes](tree-sitter-grammar-notes.md): known parse gaps.

Those design docs were written for the earlier "Opal" prototype; the names
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
allocator choice is revisited in Phase 11.

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

Not yet: references search one root (Phase 12 multi-root); reference
search is on demand (no persistent index; first search over a large
program infers its candidate bodies); method references inside macro
bodies and `{{...}}` are not found; rename of a method reached through a
`responds_to?`/duck-typed call is refused rather than guessed.

### Phase 10 — responsiveness

The original "hardening" phase is split into three: responsiveness
(here), startup and warm caches (Phase 11), multi-root (Phase 12).

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
4. **Cancellable jobs.** References, rename, incoming calls (and later
   warm-up) run as jobs with a checkpoint per candidate file and per
   body; `$/cancelRequest` answers `RequestCancelled`; an edit of a file
   a job has read cancels it with `ContentModified`. Interactive
   requests run between checkpoints. Specs with a fake slow finder;
   Neovim check: hover during references.
5. **Budgets.** Per-request time budgets (references/rename/incoming
   calls 5 s, configurable via `initializationOptions.budgets`) and a
   candidate-file cap; failures say what was covered.
6. **Verification and docs.** Probe numbers before/after, `make
   nvim-check`, README.

Exit criteria (Marten, measured by the step 1 probe): hover answers in
< 100 ms p99 while a references search runs; RSS stays under ~400 MB
after opening 100 specs and running 10 searches; no request exceeds its
budget without a clear error; the sweep has 0 internal errors.

### Phase 11 — startup and warm caches

- **Parallel work-queue indexing.** Workers pick up newly discovered
  requires instead of waiting for each round. Measured ceiling on
  Marten: 1044 ms (8 workers, rounds) → 505 ms (one flat batch).
- **Persistent cache** under the project: `.clear-ls/cache/` with its
  own `.gitignore` (`*`), so it never shows in `git status`. Item
  trees, requires and word sets per file, keyed by path, mtime, size and
  content hash, plus the clear-ls version, grammar ABI and `crystal env`.
  `--no-cache` and a `clearLs/clearCache` command. The stdlib part is
  duplicated per project (size to be measured, est. 5–10 MB).
- **Background warm-up** (idle, lowest priority, cancellable via the
  Phase 10 jobs): infer workspace bodies once so the first references
  search is warm.
- **Allocator measurement** (open since Phase 0): Boehm heap vs RSS vs
  libc for Tree-sitter under the Marten soak; keep or change
  `-Dcrystal_tree_sitter_no_init`.

Exit criteria: Marten warm start < 300 ms; the first references search
after warm-up matches warm time; cache invalidation specs (file edit,
Crystal upgrade, clear-ls upgrade, deleted file).

### Phase 12 — multi-root (deferred)

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
