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

### Phase 3 — basic types

- `TypeId`, `TypeSet` with certainty and provenance.
- Literals, annotations, `.new`, assignments, declared returns, ivars,
  accessor types.
- Features: typed hover, receiver/path/ivar completion, type inlay hints.

### Phase 4 — control-flow analysis

- Per-body CFG; joins; narrowing by `is_a?`, `nil?`, truthiness, `&&`/`||`,
  `case`/`in`; loop fixed points; rescue/ensure; unreachability.
- Features: flow-sensitive hover/completion; type at cursor.

### Phase 5 — call resolution

- Argument binding (defaults, named, splats, blocks), three-valued
  compatibility, bounded specificity; `IO#gets` regression family.
- Features: signature help, overload-aware definition, implementation,
  outgoing call hierarchy.

### Phase 6 — generics and summaries

- Generic substitution, on-demand return summaries, call-site-keyed method
  instances, recursion and widening budgets, block/collection contracts.
- Features: typed collection chains, block parameter types, more inlay hints.

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
