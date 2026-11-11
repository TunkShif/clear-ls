# Tree-sitter grammar notes

Grammar: clear-ls's own `tree-sitter-crystal`: upstream
[crystal-lang-tools/tree-sitter-crystal](https://github.com/crystal-lang-tools/tree-sitter-crystal)
`50ca9e6` plus the commits on branch `clear-ls`, pinned in the Makefile
(`GRAMMAR_REPO`, `GRAMMAR_REV`). Tree-sitter CLI and runtime 0.26.9.
Until the remote fork exists, `GRAMMAR_REPO` is the local clone
`../tree-sitter-crystal`.

## Changing the grammar

Needs Node and the tree-sitter CLI 0.26.9 (building clear-ls needs
neither: `src/parser.c` is committed in the grammar repository).

1. `tools/grammar/coverage.sh save` (baseline of failing stdlib and
   external files; external = `lib/` and `tools/external.sh` projects).
2. In `../tree-sitter-crystal` (branch `clear-ls`): edit `grammar.js`
   (or `src/scanner.c`), add a corpus case under `test/corpus/`, then
   `tree-sitter generate` (~35 s) and `tree-sitter test` (all pass);
   commit grammar, generated `src/` and the test together. The CLI caches
   the compiled parser in `~/.cache/tree-sitter/lib/crystal.so` per
   grammar name, not path: pass `-r` (the make targets do) when switching
   checkouts.
3. Here: `GRAMMAR_REV` to the new commit, `make grammar-update` (fetches
   it into `vendor/`, rebuilds the archive), `make` relinks.
4. `make syntax-gen`; review the `kinds.cr` diff (a renamed or removed
   `Kind`/`Field` is fixed in clear-ls in the same commit).
5. `tools/grammar/coverage.sh check`: no file lost (exit 1 otherwise);
   `make grammar-test`, `make spec`, and a types dump over repo and
   stdlib (`tools/types_diff.py`).
6. Bump the patch version (grammar pin, development.md). Item caches
   are keyed by the grammar commit (`BUILD_ID`), so packs rebuild.

## Coverage

Parsing the Crystal 1.22.0 standard library (`share/crystal/src`, 1646 files,
~9 MB) gives 1635 error-free files (99.33%) at about 4.3 MB/s on one thread.
`make grammar-check` re-runs this and lists failures. Crystal 1.22.2
(macOS, CLI 0.27.1; the vendored 0.26.9 runtime fails the same files):
1634, the new failure being `crystal/event_loop/libevent/event.cr`,
which 1.22.1/1.22.2 changed to use a setter call in a short block (below).

## Known gaps

| Construct | Example (stdlib location) |
|---|---|
| Short block with index-query | `filters1.try(&.pos[name]?)` (`semantic/filters.cr`) |
| Underscore block-call argument | `each_abbrev(bytes, _) do \|abbrev\|` (`crystal/dwarf/abbrev.cr`) |
| Unnamed proc-type `fun` parameter | `fun BIO_meth_set_create(BioMethod*, (Bio*) -> Int)` (`openssl/lib_crypto.cr`) |
| Escaped macro inside macro | `\{% if Int{{n}} == LibGMP::SI %}` (`big/big_int.cr`) |

## Error recovery on incomplete code

Observed on half-typed code inside `class A … end` with a following
`def bar; end`:

| Input inside `def foo` | Result |
|---|---|
| `x.` / `if x` / `y = ` | Both defs survive, but the enclosing `class_def` degrades to an `ERROR` node containing `(constant)` and the `method_def`s. |
| Unclosed `def foo(` | `MISSING ")"`; following lines are absorbed as parameters/body, and `def bar` is lost. |

Item lowering must therefore recognise declarations inside `ERROR` nodes
(e.g. `ERROR` starting with `class`/`module` keyword + `constant`), and use
the previous good item tree for regions swallowed by recovery.

## Impact on clear-ls

Small. Tree-sitter recovers locally, so a gap usually produces one `ERROR`
node inside an otherwise intact tree. Lowering treats `ERROR`/`MISSING` nodes
as placeholders, so surrounding declarations and bodies are still indexed.
Parse errors are not published as diagnostics by default; the compiler owns
diagnostics.

Grammar fixes go into clear-ls's grammar (Phase 19): see "Changing the
grammar". Upstream PRs are not offered for now.

## Threading notes

- A `TSParser` must never be shared between threads. In Crystal, a local
  first assigned at method level (e.g. `parser = ...` in an early-return
  branch) is captured *by reference* by every block in that method, so
  `ctx.spawn { parser = Parser.new ... }` in the same method silently shares
  one parser across all workers. Put worker bodies in their own methods.
- Optimised builds can collect a `Tree` while native code still walks it;
  `Syntax.keep_alive` guards cursor loops and native calls.

## Lowering quirks

- Splats inside collection literals (`[1, *xs]`, `{*t, 1}`, `Set{*xs}`)
  parse as an `ERROR` node holding only `*`, followed by the operand.
  Body lowering rejoins the pair into a `Splat` element. When the operand
  starts with `i`, `m` or `x`, the lexer reads those letters as regex
  modifiers: `*xs` becomes `ERROR("*", regex_modifier "x")` followed by
  `identifier "s"` (or no identifier for `*x`, `*mix`); lowering rejoins
  the name. A literal operand (`{1, *{"a", 'b'}}`) is not recoverable:
  the `{` goes into the ERROR node and the rest is mis-parsed.

- In `x || return` and `x || return 1`, `return` parses as an `identifier`
  or a `call` named `return` (statement-level `return` is fine). Body
  lowering maps these back to `return`/`next`/`break`.

- `&.name = v` and `&.name += v` (short-block assignment, valid Crystal)
  parse as `implicit_object_call` with the operator in an `ERROR` node and
  the value as its `arguments`. Body lowering turns them into the setter
  call `name=`.
