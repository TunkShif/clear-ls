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
| base | `base/text_range.cr`, `line_index.cr`, `stable_hash.cr`, `memory.cr` | `TextRange`, `FileId`; byte ↔ point ↔ LSP position (utf-8/16/32), invalid UTF-8 safe; XXH64 for persisted hashes; `malloc_trim` |
| syntax | `syntax/grammar.cr`, `kinds.cr` (generated), `node.cr`, `tree.cr` | static grammar FFI, `Kind`/`Field` enums by symbol id, `Node` wrapper, incremental `reparse`, `parse_ranges` (included ranges) |
| vfs | `vfs.cr` | `FileId` interning, overlays over disk, immutable `Snapshot`, `FileState` (revision, tree) |
| items | `items/item.cr`, `cond.cr`, `lower.cr`, `dump.cr` | CST → per-file `ItemTree` (declarations only); `{% if flag? %}` via reparsed ranges + `Cond`; ERROR recovery; accessor/record macros; `fingerprint` |
| cache | `cache/pack.cr`, `store.cr`, `local.cr` | binary packs of item trees (string table, checksum, atomic write); global stdlib/shard packs; project-local packs with word sets and compiler facts |
| semantics | `semantics/def_map.cr` | merged types (reopenings), compiler-style `lookup_path`, ancestors (includes before superclass), members, `namespace_at`, `add_synthetic` |
| workspace | `workspace/project.cr`, `require_resolver.cr`, `index.cr`, `compiler_facts.cr` | `crystal env` detection, `CrystalPath`-compatible requires, parallel indexing of prelude closure + workspace, one DefMap per program view (`Index::View`), rebuilt only on fingerprint/facts change |
| hir | `hir/expr.cr`, `body.cr`, `lower_body.cr`, `dump.cr` | def/file body → arena HIR with scopes, bindings, read/write refs |
| flow | `flow/builder.cr`, `cfg.cr` | HIR → CFG of evaluation-ordered ops, branches, merges, rescue edges |
| types | `types/ty.cr`, `type_expr.cr`, `infer.cr`, `call_resolver.cr`, `summaries.cr` | interned `Ty`, restriction parser, `Subst`, dataflow `Infer`, overload resolution, per-call-shape return summaries |
| compiler | `compiler/job.cr`, `output.cr`, `toolchain.cr`, `checker.cr`, `exporter.cr` | `crystal` subprocesses and their output (no LSP types) |
| ide | `ide/*.cr` | protocol-free features: analysis, locals, typing, completion, type info, tokens, signature help, navigation, references/rename |
| lsp | `lsp/transport.cr`, `json_rpc.cr`, `server.cr`, `features.cr`, `diagnostics.cr`, `formatting.cr`, `expand.cr`, `context.cr`, `code_actions.cr`, `job.cr`, `warmup.cr` | stdio server, one index per workspace root; `features.cr` and the others reopen `Server` |

`compiler/` sits beside `types/`: it does not depend on analysis, and
`workspace/compiler_facts.cr` turns its output into DefMap members.

CLI (`src/main.cr`): `lsp [--no-cache]`, `dump-cst [--ranges] FILE`,
`dump-items FILE`, `dump-hir FILE LINE`, `dump-cfg FILE LINE`,
`cache info|clear [ROOT]`, `version`. Requests beyond LSP:
`clearLs/syntaxTree`, `clearLs/expandMacro`, `clearLs/clearCache` (see
README).

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
  project, each spec program, and each other workspace file (scripts,
  loose files: prelude + own closure). `Index#def_map_for(file)`; the
  server keys Typing by map and keeps it while the map is live.
- **Tree-sitter allocator is libc malloc** (`-Dcrystal_tree_sitter_no_init`
  in `CRYSTAL_FLAGS`): 17 MB vs 282 MB GC heap and 4.7× faster parallel
  parsing; re-measured in Phase 11 (Boehm 2.5× slower to index Marten,
  higher RSS after searches). Native strings from Tree-sitter are freed
  with `Syntax.free_native`.
- **Caches are an optimisation, never a source of truth.** A pack that
  fails to read, has another build key, or doesn't match a file's
  size/hash is ignored; the file is parsed. Persisted hashes use
  `StableHash`, never `#hash` (seeded per process).
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
  spec programs (spec files grouped by their top `spec_helper`, like
  `crystal spec`; support files under `spec/` join the program that
  requires them), per-file views for scripts/loose files, a library
  view (all indexed files) for stdlib/shard files outside the project. One DefMap and one
  `IDE::Typing` per view.
- `Semantics::DefId` = file + item index path. `Item#move_to` keeps it
  and the DefMap's sites valid across body edits.
- `Index#files_with_word`: hashed identifier words of workspace files.
- `IDE::References`: target at cursor (def header, call, constant
  path, ivar) → candidate files (word index ∩ program) → exact or
  possible references; `rename_plan` (override family, refusals);
  incoming calls group exact references by enclosing def.
- `lsp/code_actions.cr`: quick fixes from compiler diagnostics only.
- `lsp/job.cr` (Phase 10): references/rename/incoming calls run as
  jobs on fibers; `References` calls a checkpoint per candidate file and
  body (cancel, budget, `Fiber.yield`). Cancelled by `$/cancelRequest`,
  by edits of files the job read, and by any declaration edit.

### Multi-root (Phase 14)

- `Server#indexes`: one `Workspace::Index` per workspace root (folders
  mapped to their project; the primary one first). `Server#index` is
  the index of the current fiber's scope (`with_index`), else the
  primary one: `request` scopes document requests with
  `index_for(file)` (longest root containing the file; else the last
  index a workspace document used, when it has the file; else the first
  that has it). Jobs and deferred blocks keep the scope of their fiber.
- Edits, closes and watched files update every index concerned
  (`indexes_touching`). `Index#seed`: library item trees of the earlier
  indexes, reused while size and mtime match (`seeded`/`parsed`).
- Compiler: `compile_dir(path)` (nearest `shard.yml`, climbing out of
  `lib/<shard>`; else the root) picks the toolchain, entry points and
  facts exporter; `Checker` takes a toolchain per entry. Facts are kept
  per entry and merged into the index whose root holds the entry.
- `didChangeWorkspaceFolders`: `add_root` (+ facts, checks, warm-up),
  `remove_root` (index, typings, jobs, `forget_root`:
  `Checker#forget` clears diagnostics only that root reported).
- Other names of a root's files (Phase 15): a root keeps the client's
  name; `VFS#alias_dir` maps its real path to it (`add_root`), and
  `alias_file` one document opened through a symlink into a root
  (`Server#alias_document`, on `didOpen`). `VFS#canonical_uri` applies
  them in `id_for`/`file?`; `Server#canonicalize` rewrites
  `textDocument.uri` once per message (`dispatch`). Files interned
  before their alias keep their id (re-keyed). Aliases outlive their
  folder; `VFS#claim` turns one around when the folder comes back under
  its other name. Compiler diagnostics are published under canonical
  URIs; `@published_uris` clears a file's old URI when its name changes.

### Snippets and require completion (Phase 13)

- `IDE::StatementSite` (`statement_site.cr`): is the word at a statement
  start, and in which scope (top level, type, enum, def, dynamic)? On a
  parse with the word replaced by a placeholder; nil after any earlier
  parse error.
- `Completion` (`completion.cr`): `do_snippet` (block parameters of the
  call the parser attaches `do` to), `case_snippet` / `case_branches`
  (subject type of the `case` around a patched `in <placeholder>`),
  `structure_snippets` (`DEFINITION_SNIPPETS` with allowed scopes,
  `CONTROL_FLOW_SNIPPETS`). Multi-line snippets are written relative to
  the line with `\t` and sent with `insertTextMode: adjustIndentation`.
- `IDE::RequireCompletion` (`require_completion.cr`): context from the
  line text; local/stdlib/shard listings; every item resolved back
  through `RequireResolver`. `Completion#file_summary` describes indexed
  files only.

### Editing UX (Phase 12)

- `LSP::Settings` (`lsp/settings.cr`): one key table → defaults, type
  checks, `didChangeConfiguration`, `docs/settings.md`.
- `IDE::AccessorTarget` (`references.cr`): members one accessor macro
  argument generates, searched/renamed as one symbol. Setter calls
  resolve through `Infer#setter_value`; `&.name = v` is lowered to a
  `name=` call; `Infer#initialize_resolution` links `Foo.new(k: v)` to
  `initialize` (record fields).
- Completion shapes (`completion.cr`): `shape_member` (setters,
  operators), `with_block` (`Typing#block_param_names`). Items omit
  optional fields rather than sending `null`.
- `IDE::TypeParams`: type params and `forall` variables at a constant
  (CST scoping like the compiler), checked before constant resolution.
- `IDE::AliasDisplay`: alias spellings for hints/hover, from written
  types through flow; never part of inference.

### Startup and caches (Phase 11)

- `Index#load` → `index_files`: a work queue over a parallel execution
  context; workers read, look up the cache (`Store#lookup_unchanged` by
  size + mtime, else `Store#lookup` by size + content hash for
  stdlib/shard files; `Local#lookup` by size + mtime for the rest), else
  parse and lower, then resolve requires and collect word sets. The
  source walk lists directories through `Project#children`
  (`Local#children`: `dirs.pack`, names by directory mtime). The indexing fiber adds entries, queues new requires and
  hands misses to their layer; `flush_cache` writes packs after `load`
  and at shutdown.
- `Cache::Pack` layout and `Cache::BUILD_ID` (commit, dirty digest,
  grammar commit via `tools/build_id.sh`): see
  [persistent-cache.md](design/persistent-cache.md).
- Compiler facts per entry point go to `.clear-ls/cache/facts.pack` after
  every check and are applied on `initialized` (`restore_facts`) before
  the first one; the per-file digests still drop facts of changed files.
- `lsp/warmup.cr`: after indexing, a fiber infers every workspace body
  while the server is idle (300 ms without messages, no job), restarting
  on declaration changes. It fills summaries and `Typing#call_facts`
  (name range, resolution kind, target keys per call), which
  `References#method_refs` reads instead of keeping each body's `Infer`
  (460 MB on Marten).

### Type definition and range formatting (Phase 16)

- `IDE::TypeInfo#type_at`: the type under the cursor through the hover
  paths (`local_type`, `ivar_type`, `self_type_at`, `literal_type`,
  `call_at`). `Navigation#type_definitions` maps it to sites: unions per
  member, metaclass to its instance, tuple/named tuple/proc to their
  structs, generic arguments not followed; a type's first site plus the
  first in each other workspace file (library reopenings skipped).
  `declaration` is answered by `definition`.
- `lsp/formatting.cr`: `rangeFormatting` formats the whole buffer;
  `Server.line_hunks` (Myers line diff) gives every hunk and
  `hunks_in_range` keeps those touching the requested lines, growing the
  window over each kept hunk. `formatting` still sends one
  prefix/suffix edit (`line_diff`).

### Annotations (Phase 17)

- `IDE::Annotations` (`annotations.cr`): the compiler's annotations
  (doc, targets, arguments with type and position). `Analysis` hovers a
  built-in from it (a declared one keeps its source doc), and resolves
  `@[Primitive]`/`@[Flags]` at the top level like the compiler.
- `IDE::AnnotationContext` (`annotation_context.cr`): name or argument
  position of the cursor inside `@[…]`, by scanning the text back to
  `@[` (half-typed annotations are `ERROR` nodes).
- `IDE::AnnotationArgs` (`annotation_args.cr`): arguments of an
  annotation type from tables only: `Annotations::BUILTINS` (top-level
  compiler annotations) and `Annotations::STDLIB_ARGS` (`JSON::Field`,
  `YAML::Field`, `URI::Params::Field`, `*::Serializable::Options`,
  applied only when every declaration is in the stdlib). Docs are not
  parsed. Used by `Completion#annotation_args` and
  `Analysis#annotation_arg_hover`.
- `DefMap#lookup_path_raw` follows an alias in the middle of a path
  (`ADI::Register`), as the compiler does.

### C bindings (Phase 18)

- `Project.with_target_path` / `lib_c_target`: `lib_c/<arch>-<os>` on
  `crystal_path`, as the compiler's `CrystalPath#add_target_path`.
- `Items::Lower#lower_top`: `{% skip_file %}` guards the rest of a file
  with the negated condition.
- `Infer#lib_member_call` records the matched fun / `$var` / field as
  the call's `Unique` resolution (`record_c_target`), so `call_at`,
  call facts, references, rename and signature help treat it as a
  method. `TypeInfo#c_decl_markdown` / `c_decl_hover` format C
  declarations; `Completion#c_member_items` lists a lib's funs and
  globals or a C struct's fields.
- `IDE::PseudoDocs` (`pseudo_docs.cr`): pseudo-method and `Void` /
  `NoReturn` docs read from the stdlib's `docs_pseudo_methods.cr`.
  `TyKind::Void` for an undeclared `Void`.

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
- The first start of a project, and starts after a clear-ls or Crystal
  upgrade, parse everything (~0.6 s, ~0.85 s on Marten); requires are
  resolved on every start.
- Compiler facts from the cache can be stale when the file that caused
  them changed while the server was off (e.g. a subclass that a
  `macro finished` in another file iterates); the first check fixes them.
- One thread: long requests (references, rename, incoming calls) are
  `LSP::Job`s that yield at checkpoints; other requests still run one
  at a time.
- References, rename and call/type hierarchy stay within the index of
  the file they start from: a path dependency opened as its own folder
  is a library file in the app's index (renames into it are refused).
  `crystal env` runs in each root (a version manager's per-project
  Crystal is used for its index and `CRYSTAL_PATH`); `compiler.path` is
  one setting for all.
