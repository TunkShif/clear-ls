# clear-ls

Experimental Crystal language server written in Crystal, built on
Tree-sitter with an editor-oriented semantic model. Status: Phase 0
(foundations) — text sync and incremental parsing, no language features yet.

See [docs/roadmap.md](docs/roadmap.md) for the plan and design docs.

## Build

Requires Crystal ≥ 1.22, a C compiler, `git`, and `make`.

```sh
make            # fetch pinned deps into vendor/, build bin/clear-ls
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
```

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
