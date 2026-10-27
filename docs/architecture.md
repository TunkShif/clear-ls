# clear-ls architecture

How the code is organised and why. Phase plans and status live in
[roadmap.md](roadmap.md); pitfalls in [gotchas.md](gotchas.md); known
differences from the language reference in [book-gaps.md](book-gaps.md). The design
background is in [design/](design/) (written for the earlier "Opal"
prototype; names differ, architecture applies).

## Layers

`src/clear_ls/`, dependencies point downward (a layer only uses the ones
above it in this table):

| Layer | Files | Role |
|---|---|---|
| base | `base/text_range.cr`, `line_index.cr` | `TextRange`, `FileId`; byte ↔ point ↔ LSP position (utf-8/16/32), invalid UTF-8 safe |
| syntax | `syntax/grammar.cr`, `kinds.cr` (generated), `node.cr`, `tree.cr` | static grammar FFI, `Kind`/`Field` enums by symbol id, `Node` wrapper, incremental `reparse`, `parse_ranges` (included ranges) |
| vfs | `vfs.cr` | `FileId` interning, overlays over disk, immutable `Snapshot`, `FileState` (revision, tree) |
| items | `items/item.cr`, `cond.cr`, `lower.cr`, `dump.cr` | CST → per-file `ItemTree` (declarations only); `{% if flag? %}` via reparsed ranges + `Cond`; ERROR recovery; accessor/record macros; `fingerprint` |
| semantics | `semantics/def_map.cr` | merged types (reopenings), compiler-style `lookup_path`, ancestors (includes before superclass), members, `namespace_at`, `add_synthetic` |
| workspace | `workspace/project.cr`, `require_resolver.cr`, `index.cr`, `compiler_facts.cr` | `crystal env` detection, `CrystalPath`-compatible requires, parallel indexing of prelude closure + workspace, one DefMap per program view (`Index::View`), rebuilt only on fingerprint/facts change |
| hir | `hir/expr.cr`, `body.cr`, `lower_body.cr`, `dump.cr` | def/file body → arena HIR with scopes, bindings, read/write refs |
| flow | `flow/builder.cr`, `cfg.cr` | HIR → CFG of evaluation-ordered ops, branches, merges, rescue edges |
| types | `types/ty.cr`, `type_expr.cr`, `infer.cr`, `call_resolver.cr`, `summaries.cr` | interned `Ty`, restriction parser, `Subst`, dataflow `Infer`, overload resolution, per-call-shape return summaries |
| compiler | `compiler/job.cr`, `output.cr`, `toolchain.cr`, `checker.cr`, `exporter.cr` | `crystal` subprocesses and their output (no LSP types) |
| ide | `ide/*.cr` | protocol-free features: analysis, locals, typing, completion, type info, tokens, signature help, navigation, references/rename |
| lsp | `lsp/transport.cr`, `json_rpc.cr`, `server.cr`, `features.cr`, `diagnostics.cr`, `formatting.cr`, `expand.cr`, `context.cr`, `code_actions.cr` | stdio server; `features.cr` and the others reopen `Server` |

`compiler/` sits beside `types/`: it does not depend on analysis, and
`workspace/compiler_facts.cr` turns its output into DefMap members.

CLI (`src/main.cr`): `lsp`, `dump-cst [--ranges] FILE`, `dump-items FILE`,
`dump-hir FILE LINE`, `dump-cfg FILE LINE`, `version`. Debug requests:
`clearLs/syntaxTree`, `clearLs/expandMacro` (see README).

## Pipeline

```text
VFS (disk + overlays) → snapshot → Tree-sitter CST
   ├── item lowering → ItemTree → DefMap (+ compiler facts) / Index
   └── body lowering (on demand) → HIR → CFG → Infer → CallResolver
                                                ↑ Summaries (other defs' bodies)
crystal build/tool (background fibers) → diagnostics, facts, expansions, contexts
```

## Design decisions

- **Tree-sitter only in `syntax/`.** Everything above uses `Kind`/`Field`
  enums or HIR. Kinds are generated (`make syntax-gen`, `tools/gen_syntax.cr`)
  from `vendor/tree-sitter-crystal/src/node-types.json`; reserved names get
  a `Node` suffix (`Kind::StringNode`, `Field::ClassNode`).
- **Two trees.** Declarations (`ItemTree`/`DefMap`) and bodies
  (`HIR::Body`, lowered on demand, cached per file revision in
  `IDE::BodyCache`).
- **Body-only edits do not rebuild the DefMap** (`ItemTree#fingerprint`;
  `Index#rebuilds` is asserted in specs). The DefMap shares the file's
  `Item`s, which take the new positions in place (`Item#move_to`).
- **A file sees what its program sees.** One DefMap per view: the
  project (prelude + closure of shard targets, else `src/`), each nested
  project, and each workspace file outside them (scripts, specs, loose
  files: prelude + own closure). `Index#def_map_for(file)`; the server
  keys Typing by map.
- **Tree-sitter allocator is libc malloc** (`-Dcrystal_tree_sitter_no_init`
  in `CRYSTAL_FLAGS`): 17 MB vs 282 MB GC heap and 4.7× faster parallel
  parsing. Native strings from Tree-sitter are freed with
  `Syntax.free_native`.
- **Unknown stays unknown.** No name-based guessing; unions over 8 members
  widen to unknown; unknown arguments never eliminate an overload.
- **Completion analyses a patched copy** of the buffer with `__cl__` at the
  cursor (incomplete code parses badly otherwise). Signature help patches in
  a placeholder plus `)`.
- **Typing state** (`IDE::Typing`: TypeTable + caches) is recreated when the
  DefMap object changes (`Server#typing`).
- **The compiler is authoritative but never blocks.** Diagnostics come only
  from `crystal build --no-codegen`; clear-ls publishes no approximate
  errors. Compiler work runs on fibers. Requests that need it either use
  cached results (facts, contexts) or are answered later (`LSP::Deferred`).
- **Compiler facts only fill gaps.** Generated methods and ivar types are
  added when source declarations lack them, labelled `Origin::Compiler`,
  and dropped for files saved since the check.

## Internals by area

### Flow and inference (Phase 4)

`HIR::LowerBody` gives fixed child shapes: `If` = [cond, then, else] with
`Nop`; `Case` = [subject|Nop, When..., else]; tagged `Rescue` clauses.
`Flow::Builder` → `CFG` with `Eval`/`Enter` ops, `Branch` tests (`Truthy`,
`CaseWhen`), `merges` (value sources of join expressions), rescue
`handler`/`exc_preds`, and a dead-code `fallback`. `Types::Infer#run` =
`solve` (worklist, reverse postorder, widening after 8 changes) +
`solve_dead`; `eval_expr` is the per-op transfer; `refine` applies
`narrowing`/`case_facts` per edge; `env_before`/`env_at` replay a block to
a program point (hover, completion).

### Call resolution (Phase 5)

`Types::CallResolver`: `bind` (structural: positional, named, defaults,
splats, block), `compat`/`matches` (three-valued; `autocast?` has the
number autocasting rules, and `rank` tries an exact pass before a casting
one),
`rank` (union arguments expanded into ≤16 runtime combinations;
`shadows?` drops a candidate only when a definitely matching one is at
least as specific). `Infer#resolve_call`/`method_groups`/`resolutions`;
`Infer#primitive_op` covers number methods that the stdlib generates with `{% for %}`.
IDE: `CallContext` (textual enclosing-call scan), `SignatureHelp`,
`Navigation` (implementation, outgoing calls).

### Summaries and generics (Phase 6)

`Types::Summaries` caches (def, file revision, self, args[, block value])
→ return and yield types. `Infer#summary` binds params (`param_args`) and
the block value (`yield_value`), then runs an inner `Infer` in
`summarising` mode. `Pending` (`ty.cr`) is the fixed-point seed: it
vanishes from unions, doesn't end control flow, and reads as unknown.
Over the shape cap, return summaries keep the block value (a missing one
makes `yield` Pending) and yield summaries keep the argument types.
Summaries also record the `with x yield` receiver (`Summary#with_self`),
which becomes the implicit `self` of the caller's block (`@block_self`,
`Infer#with_self_at` for completion).
Locals used in proc literals or captured blocks (`@captured`) are solved
twice: the second solve gives every assignment their joined type and
skips truthiness narrowing for them. `method_groups` drops defs that a
later same-key def redefines (`Infer.redefines?`); `previous_def`/`super`
resolve through `redef_call` using `current_def`.
`@[Primitive]` defs without a return type are typed by `primitive_return`
instead of their empty bodies; bodies with a `return` inside `{% %}`
summarise to unknown.
Budgets: depth 12, 16 shapes per (def, receiver), 20k summaries per
generation. `Infer#contract` covers stdlib methods whose types come from
macros. Constants: `const_expr_type`; big tables via `truncated_value`.

### Workspace identity (Phase 9)

- `Index::View`: project (shard targets or `src/`), nested projects,
  per-file views for scripts/loose files, a library view (all indexed
  files) for stdlib/shard files outside the project. One DefMap and one
  `IDE::Typing` per view.
- `Semantics::DefId` = file + item index path. `Item#move_to` keeps it
  and the DefMap's sites valid across body edits.
- `Index#files_with_word`: hashed identifier words of workspace files.
- `IDE::References`: target at cursor (def header, call, constant
  path, ivar) → candidate files (word index ∩ program) → exact or
  possible references; `rename_plan` (override family, refusals);
  incoming calls group exact references by enclosing def.
- `lsp/code_actions.cr`: quick fixes from compiler diagnostics only.

### Compiler integration (Phase 7)

- `Compiler::Job`: subprocess with timeout and cancel. `wait` yields, so
  only spawned fibers call it.
- `Output`: JSON error frames on stderr, text warnings.
- `Toolchain`: check/expand/context/format commands; `EntryPoints` from
  shard targets.
- `Checker`: debounces and supersedes per entry point, merges per file,
  and clears files that became clean.
- `Exporter`: the `macro finished` source plus `Facts.parse`.
- `Workspace::CompilerFacts` merges facts into the DefMap
  (`DefMap#add_synthetic`), parsing headers once per facts object.
- LSP side: `diagnostics.cr`, `formatting.cr`, `expand.cr`, `context.cr`.
  didOpen republishes known problems; fact changes send
  `workspace/inlayHint/refresh` and `semanticTokens/refresh`.

## Known limitations

Not tied to a phase (phase-specific gaps are listed under each phase in
the roadmap):

- Items: `delegate`/`def_equals*` not synthesised from source; file-private
  types not scoped. `@x = v` in def bodies and `def f(@x)` params become
  `Origin::Assigned` / `Origin::Param` ivar items (typed by
  `Infer.assigned_ivar_type`), so editing such a line rebuilds the DefMap.
- Locals inside macro bodies are not modelled (lowered as `Missing`).
- Module instance methods: `self` inside a module def is the module type,
  not "any includer".
- Inlay hints don't cover parameters.
- No persistent stdlib index cache; every start re-indexes (~0.6 s).
- Requests are handled one at a time on one fiber; no cancellation.
- Single workspace root (first `workspaceFolders` entry / `rootUri`, or
  the project above it); nested projects get their own views, but
  diagnostics still run in the root's toolchain.
