# clear-ls roadmap

clear-ls is an experimental Crystal language server written in Crystal. It
parses with Tree-sitter and answers editor queries from an approximate,
editor-oriented semantic model. The Crystal compiler stays authoritative for
diagnostics and final semantics.

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
allocator choice is revisited in Phase 9.

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
design (deferred to Phase 4), references/rename for non-locals (Phase 8).

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
   references (Phase 8).
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

Not yet: incoming calls (Phase 8), return inference for unannotated defs
such as `Enumerable#sum`, `Hash#[]?` (Phase 6). Signature help needs the
call's line to parse: an unclosed `(` before `end` makes Tree-sitter
swallow the enclosing def, so the call is only found after a `)` is
inserted on the same line (handled) or typed.

### Phase 6 — generics and summaries

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

### Phase 7 — compiler integration

- Async `crystal build --no-codegen -f json` diagnostics.
- `crystal tool expand` for explicit macros; a separate exporter for macro
  hooks (`tool expand` cannot locate hook expansions).
- Features: compiler diagnostics, expansion preview, formatting via
  `crystal tool format`, compiler-confirmed types.

### Phase 8 — workspace identity

- `DefId`-keyed reference index, incrementally maintained.
- Features: workspace references and rename (exact identity only), type
  hierarchy, incoming calls, code actions.

### Phase 9 — hardening

- Persistent stdlib/shard index cache, parallel indexing, cancellation and
  budgets, GC vs libc allocator measurement, multi-root workspaces.

## Testing approach

- Snapshot tests for representations (`dump-cst`, later items and HIR).
- Property tests for incremental parsing and position conversion.
- Differential tests against the compiler on complete fixtures; record
  disagreements as approximation, unsupported, bug, or version difference.
- `make grammar-check` tracks grammar coverage of the stdlib.
