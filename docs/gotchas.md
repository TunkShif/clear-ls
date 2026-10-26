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

- `abstract`, `out`, `lib` are reserved words: they can't be param/var names.
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

## Editors and LSP tests

- Neovim debounces `didChange` by 150 ms; headless scripts must wait longer
  than that after `nvim_buf_set_lines` before a request
  (`tools/nvim/common.lua` `set_line` waits 400 ms).
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
- `VFS#id_for` costs ~9 µs (URI normalisation): cache it in loops.
- The real compiler rejects some fixtures that the fake spec prelude
  accepts (a class named `Box` collides with stdlib `Box(T)`).
- `FeatureClient` defaults to `compiler: {enabled: false}`. `request` waits
  for deferred responses, and `cleanup` sends `shutdown`, which removes the
  exporter temp file.
