# Tree-sitter grammar notes

Grammar: `tree-sitter-crystal` at `50ca9e6`, tree-sitter CLI 0.26.9.

## Coverage

Parsing the Crystal 1.22.0 standard library (`share/crystal/src`, 1646 files,
~9 MB) gives 1635 error-free files (99.33%) at about 4.3 MB/s on one thread.
`make grammar-check` re-runs this and lists failures.

## Known gaps

| Construct | Example (stdlib location) |
|---|---|
| Keyword as accessor name | `getter begin : B` (`range.cr`), `property end : Bool` (`compiler/crystal/codegen/crystal_llvm_builder.cr`) |
| Short block with setter | `.tap &.keyword = keyword` (`compiler/crystal/syntax/ast.cr`), `value.tap(&.ensure = ensure_body)` (`syntax/parser.cr`) |
| Short block with setter call syntax | `.tap(&.flush_on_newline=(true))` (`crystal/system/unix/file_descriptor.cr`), `inner.try &.color=(color)` (`semantic/exception.cr`) |
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

Fixes belong upstream in the grammar; clear-ls does not patch it locally.

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
