# Gotchas

Pitfalls that cost real debugging time. Read the section for an area before
changing it. Grammar quirks are in
[tree-sitter-grammar-notes.md](tree-sitter-grammar-notes.md).

## Native memory and threads

1. **Keep native owners alive.** `TSNode`/`TSTreeCursor`/`TSParser*` don't
   keep their Crystal wrapper alive; optimised multi-threaded builds
   finalised trees mid-walk. Call `Syntax.keep_alive(obj)` after the last
   raw use (see `node.cr`, `tree.cr`).
2. **Crystal blocks capture method-level locals.** A `parser = ...`
   anywhere in a method is one variable for every `ctx.spawn` block in it,
   i.e. one TSParser used by all threads (crashed every parallel load).
   Worker bodies live in separate methods (`Index#parse_worker`).
3. `ts_language_version` was removed in Tree-sitter 0.26; the binding's
   `Language#abi_version` fails to link if called. Use
   `Syntax::Grammar.abi_version`.

4. **libc arenas keep freed Tree-sitter memory.** Trees parsed on
   parallel workers are freed into those threads' malloc arenas, which
   glibc doesn't return to the OS: RSS stays at the peak. `Memory.trim`
   (`malloc_trim(0)`, ~20 ms) after indexing and after long jobs.

## Grammar

- Punctuation is tagged with fields: use `Node#field`, which skips
  anonymous nodes.
- `class_def` degrades to `ERROR (constant) ...` around half-typed code.
- An unclosed `def foo(` (or `io.gets(` before `end`) swallows the
  enclosing/following defs.
- `x || return` parses `return` as an identifier/call.
- `{% %}` bodies are opaque `macro_content`.
- `index_call` method text is `[` (normalised to `[]`, `[]?`, `[]=`).

## Crystal language and specs

- `abstract`, `out`, `lib`, `fun` are reserved words: they can't be param/var names.
- `include` in a spec file leaks into every spec file. Shared spec helpers
  must not be `private`, and they live in `spec/support/`.
- `make spec` / `crystal run` need `CRYSTAL_CACHE_DIR` and
  `PKG_CONFIG_PATH=build/pkgconfig` (the Makefile exports both). For ad-hoc
  scripts, see [development.md](development.md#ad-hoc-scripts).

## Inference

- `lib` and `out` are reserved words in Crystal code too (not just as
  params): `lib = ...`, `out = [] of X` fail to parse in clear-ls's own
  source.
- Summary shapes: over the per-def cap, return summaries must keep the
  caller's block value (else `yield` is Pending and `if v; yield v; end`
  becomes Nil) and yield summaries the argument types (Phase 8, O4).
- The book fixtures reuse class names across files; `book_diff.py`
  indexes each one alone. Ad-hoc probes that put several in one project
  merge their members.

- Closure blocks re-enter `Enter` each iteration and reset block locals;
  `own_scope?` distinguishes `&.foo` blocks (no scope) from real ones.
- Completion/signature help analyse patched copies that reuse the file
  id with a derived revision: call `Typing#infer_at(..., cache: false)`
  for them, or two different patches of one revision share results.
- `&.a.b` lowers to `b` with receiver `a`, both implicit-object calls;
  only the outermost call's parent is the block.
- The compiler narrows only locals (`if @a` leaves `@a` nilable); clear-ls
  does the same on purpose.
- Rebuild probe binaries after source changes before comparing numbers.
- A file body spans every namespace of its file: use the program as its
  namespace and look constants up at the expression (`type_body_ns`);
  `namespace_at(file, 0)` is inside a type declared on the first line.
- `DefMap#lookup_path` follows aliases (what inference wants);
  navigation uses `lookup_path_raw` so `Env` stays `alias Env = ...`.
- The program has ancestors (top-level `include`): resolve the include
  paths with `program_path`, not `lookup_path` from the program, which
  would consult the very list being built.
- Probes need a Typing per program view (`Index#def_map_for(file)`): a
  stdlib file outside the project's closure is seen through the library
  view (all indexed files), a script through its own.

## Editors and LSP tests

- Neovim debounces `didChange` by 150 ms; headless scripts must wait longer
  than that after `nvim_buf_set_lines` before a request
  (`tools/nvim/common.lua` `set_line` waits 400 ms). The smoke check
  waited exactly 150 ms until Phase 9 and sometimes completed the
  unedited line.
- Honour LSP result shapes exactly (`outgoingCalls` items have `to` and
  `fromRanges`).
- Run headless Neovim with `-n`, or a crashed run leaves swap files that
  block the next one.
- Neovim's `:e` is didClose + didOpen and drops the server's
  diagnostics on close; the server must publish them again on didOpen
  even when it doesn't rerun the compiler.
- Clients don't re-request inlay hints/semantic tokens by themselves
  when server-side knowledge changes (compiler facts); send
  `workspace/*/refresh` (only if `refreshSupport` was advertised).

## Compiler integration

- Errors are JSON on **stderr**; warnings stay text even with `-f json`.
  Columns are codepoints. "expanding macro" frames point to the call site.
  Exporter `puts` output goes to stdout.
- `--stdin-filename` replaces only the main file, so compiler results
  describe saved files.
- `tool expand`/`tool context` ignore cursors in required files unless the
  file is also passed as a source. `tool expand` never finds hook
  expansions. `tool context` returns top-level variables for
  uninstantiated defs.
- Macro variables don't survive between `{% %}` tags inside a def body, and
  naming a private type in macro code fails. Keep exporter logic in one
  tag.
- `TypeNode#instance_vars` only works inside a method body (ivars are typed
  late); calling it in a top-level macro is an error.
- Without a `shard.yml` every file is its own program: spec fixtures
  that need cross-file lookups must `require` each other or add a
  `shard.yml` with a target.
- Typing holds the summary cache: dropping one for a still-live map
  makes the next request re-infer everything it touches (a count-based
  eviction did this on every multi-view search). Evicting disk-loaded
  VFS states has the same effect, since re-reading bumps the revision.
- `String#hash` / `Object#hash` are seeded per process: never persist
  them or compare them across processes (Phase 11 cache, compiler fact
  digests). Use `ClearLS::StableHash`.
- **Persistent cache.** Changing `Items::Item` (or any record in
  `items/item.cr`/`cond.cr`) needs the codec in `cache/pack.cr` updated;
  `spec/cache/pack_spec.cr` compares every ivar and fails if not. Bump
  `Cache::SCHEMA` for layout changes, and the patch version.
- Specs that reuse a project directory must not rewrite unchanged files:
  the local cache validates by mtime (`FeatureClient` writes only
  changed files).
- `soak.py`/`sweep.py` measure a cold server: `lsp_client.py` turns the
  warm-up off unless the script asks (`warm.py`); pass `--no-cache` with
  `CLEAR_LS_ARGS` to measure parsing.
- Don't keep `Infer` objects for many bodies (~100 KB each): keep
  `Typing#call_facts` or summaries (the warm-up's 772 MB lesson).
- **LSP JSON: omit optional fields, never send `null`.** Neovim's
  built-in completion indexes `item.textEdit` and fails on
  `vim.NIL`. Build optional fields conditionally
  (`completion_item_json`).
- **Settings:** add keys to `Settings::KEYS` and regenerate
  `docs/settings.md` (`bin/clear-ls settings-doc`); the spec fails
  otherwise. Rebuild `bin/clear-ls` first: the spec compares against
  the source, the command prints from the binary.
- **Setters are `name=` calls with no HIR argument**: the value is the
  parent assignment's (`Infer#setter_value`). Code that looks for `name=`
  by word must search `name` (`References.setter?`).
- **`Node#parent` is O(depth)** (Tree-sitter walks down from the root).
  Per-node ancestor walks inside a whole-file walk are quadratic; keep a
  scope stack during the walk instead (`SemanticTokens#tokens`).
- `VFS#id_for` costs ~9 µs (URI normalisation): cache it in loops.
- The real compiler rejects some fixtures that the fake spec prelude
  accepts (a class named `Box` collides with stdlib `Box(T)`).
- `FeatureClient` defaults to `compiler: {enabled: false}`. `request` waits
  for deferred responses, and `cleanup` sends `shutdown`, which removes the
  exporter temp file.

## macOS

- **Endpoint agents tax `open()`.** On the M3 Pro used for Phase 15
  (endpoint agent installed), `open()` from a freshly built binary costs
  ~110 µs (~15 µs from Python on the same paths) and doesn't get faster
  beyond 2 threads; `stat` and `readdir` stay cheap. The first launch of
  a new binary is ~0.5 s slower. Compare builds interleaved (A, B, A,
  B), never a first run against a warm one, and avoid opening unchanged
  files and directories (the walk and global-layer caches).
- **Memory is the physical footprint, not RSS.** macOS RSS counts
  freed malloc regions the kernel reclaims under pressure (Marten after
  indexing: 153 MB RSS, 103 MB footprint). `lsp_client.py` reports
  `footprint -p` there; `malloc_zone_pressure_relief` (a `malloc_trim`
  equivalent) freed nothing measurable.
- **`/var` and `/tmp` are symlinks** to `/private/...`, and `$TMPDIR`
  ends in `/` (`"$TMPDIR/x"` has `//`). The compiler reports real paths
  (or the given ones, depending on how it was invoked), Neovim names
  buffers by real path but keeps a folder's given path. Compare paths
  through `VFS#canonical_uri`; specs that compare compiler paths use
  `File.realpath` of their temp dir.
- **Don't `Path#normalize` paths.** Homebrew's `CRYSTAL_PATH` is
  `.../crystal/1.22.2/bin/../share/crystal/src`: every stdlib path
  contains `..`, and normalising it in one place (it was tried in
  `VFS.path_for`) splits file identities: references 3× slower, warm-up
  3× longer. `path_for` only collapses `//`.
- **Homebrew ships a shared `libtree-sitter`** (0.27): an ad-hoc build
  without `PKG_CONFIG_PATH=build/pkgconfig` links it silently instead
  of the vendored static 0.26.9. `make verify-static` checks `otool -L`.
- Mach-O symbols start with `_` (`_tree_sitter_crystal`); GNU
  `timeout`, `ldd` and `/proc` don't exist (`tools/` falls back).
- **Release binaries and `make`:** `$(BIN)` used to depend on the phony
  `deps`, so `make spec` and `make verify-static` rebuilt
  `bin/clear-ls` as a debug build even right after `make release` (a
  3× "regression" in a timing). Fixed in Phase 15; still, `make spec`
  rebuilds it (debug) whenever sources changed: run `make release` last
  before timing.
- **mtime shortcuts and coarse timestamps** (Linux too): files written
  back to back often share one mtime (93 of 100 on ext4 on the EPYC),
  so specs that rely on two copies having different mtimes must set
  them (`File.touch(path, time)`). The caches trust size + mtime (and a
  directory's mtime for its listing), like `make` and git's index: a
  same-size edit within one timestamp tick of the cached stat is
  missed until the file changes again.
- **Flaky compiler specs (open):** twice in ~10 full runs a
  multi-folder spec that runs the real compiler failed (`checks each
  folder's programs in its own directory`, `keeps compiler facts in
  the index of the entry's root`); 2 of 25 repeated runs once, then 0 of
  140 (with and without debug logs). Not explained yet.
