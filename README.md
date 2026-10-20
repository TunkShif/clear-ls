# clear-ls

Experimental Crystal language server written in Crystal, built on
Tree-sitter with an editor-oriented semantic model. Status: Phase 3 —

- completion: members of inferred receivers, `Foo::` paths, constants,
  `@ivars`, locals, methods, keywords;
- hover with inferred types for locals and resolved method signatures;
- inlay type hints for locals and block arguments;
- document and workspace symbols, folding, selection ranges;
- goto-definition for types, constants, locals, and method calls;
- references, highlights, and rename for local variables and parameters;
- semantic tokens (params, locals, ivars, types, declarations);
- links and goto-definition for `require` paths.

See [docs/roadmap.md](docs/roadmap.md) for the plan and design docs.

## Build

Requires Crystal ≥ 1.22, a C compiler, `git`, and `make`.

```sh
make            # fetch pinned deps into vendor/, build bin/clear-ls (debug)
make release    # optimised build; use this one in the editor
make spec       # run specs
make verify-static
```

The Tree-sitter runtime (v0.26.9) and `tree-sitter-crystal` grammar are
compiled from source and linked statically. `make grammar-check` (needs the
`tree-sitter` CLI) parses the Crystal stdlib and lists grammar failures.
After a grammar bump, run `make syntax-gen` to regenerate
`src/clear_ls/syntax/kinds.cr`.

## Usage

```sh
bin/clear-ls lsp [--log-level debug] [--log-file PATH]   # stdio server
bin/clear-ls dump-cst [--ranges] FILE                    # print the CST
bin/clear-ls dump-items FILE                             # print declarations
bin/clear-ls dump-hir FILE LINE                          # print a def's body HIR
```

The server reads `CRYSTAL_PATH`, version, and target from `crystal env` /
`crystal --version` (override the executable with `CRYSTAL=...`) and indexes
the prelude's require closure, required shards, and all `.cr` files under
the workspace root.

Neovim (0.11+):

```lua
vim.lsp.config("clear_ls", {
  cmd = { "/path/to/clear-ls/bin/clear-ls", "lsp", "--log-file", "/tmp/clear-ls.log", "--log-level", "debug" },
  filetypes = { "crystal" },
  root_markers = { "shard.yml", ".git" },
})
vim.lsp.enable("clear_ls")
```

Debug request: `clearLs/syntaxTree {textDocument: {uri}}` returns the CST as
an S-expression.
