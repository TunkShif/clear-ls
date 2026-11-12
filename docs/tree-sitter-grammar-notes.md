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

Crystal 1.22.2 standard library (`share/crystal/src`, 1646 files, ~9 MB):
1645 error-free files (99.94%) at about 3.8 MB/s on one thread. External
set (`make grammar-check-ext`: `lib/`, Marten, Athena with specs): 2068 of
2068. Before Phase 19 (upstream `50ca9e6`): 1635 and 2040.
`make grammar-check` / `grammar-check-ext` re-run these and list failures;
`tools/grammar/coverage.sh save|check` compares failing files across a
grammar change.

## Known gaps

What fails today (the deferred list C of Phase 19 in
[roadmap.md](roadmap.md#phase-19--own-tree-sitter-crystal)):

| Construct | Example | Why deferred |
|---|---|---|
| Escaped macro tag with a nested macro expression (C3) | `\{% if Int{{n}} == LibGMP::SI %}` (`big/big_int.cr`, the one stdlib failure) | `\{%` is literal text to Crystal's macro lexer, but the grammar reads `{%` as a macro statement; a scanner try (consume `\{%` as content) broke the corpus's "escaped macro expression" tree and still left the `{% end %}` pairs unbalanced. Needs a model of escaped tags in the macro grammar |
| Keywords as names outside accessors (C5) | `def select`, `x.end`, named args `begin:` | upstream #132's scanner route; A3 covers `getter begin : T`. No failing file in the stdlib or external set |
| Error recovery for half-typed code (C6) | `@[` alone, `@[JSON::` eating the next `def`, unclosed `def foo(` | recovery tuning; clear-ls works around (below) |

Not grammar bugs (the compiler rejects them too): mixed hash/named-tuple
keys `{1 => 2, b: 3}` (C1), `{{` as two tuple braces (C2),
`{0 => f "a", 1 => 2}` (a parenless call swallows the next entry).

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

- In `x || return` and `x || return 1`, `return` parses as an `identifier`
  or a `call` named `return` (statement-level `return` is fine). Body
  lowering maps these back to `return`/`next`/`break`.

- `&.name = v` / `&.name += v` parse as `assign` / `op_assign` with an
  `implicit_object_call` lhs; body lowering calls the setter `name=`.

- `&.[i]` and `&.pos[i]?` parse as an `implicit_object_call` wrapping an
  `index_call` (with the `pos` call as its receiver); body lowering makes
  the `index_call` itself the implicit object call (`[]` / `[]?`).

- Keyword accessor names (`getter begin : T`) arrive as one `var` token
  `begin : ` (keyword and separator); lowering trims it.
