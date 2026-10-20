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

## Impact on clear-ls

Small. Tree-sitter recovers locally, so a gap usually produces one `ERROR`
node inside an otherwise intact tree. Lowering treats `ERROR`/`MISSING` nodes
as placeholders, so surrounding declarations and bodies are still indexed.
Parse errors are not published as diagnostics by default; the compiler owns
diagnostics.

Fixes belong upstream in the grammar; clear-ls does not patch it locally.
