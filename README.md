# clear-ls

Experimental Crystal language server written in Crystal, built on
Tree-sitter with an editor-oriented semantic model. Status: Phase 6 —

- return types of unannotated methods inferred per call (summaries), so
  collection chains (`map`, `compact_map`, `find`, `reduce`, `group_by`,
  `to_h`, hash and tuple indexing) keep concrete types; inferred returns
  in hover and inlay hints;
- flow-sensitive local types: branch joins, narrowing by `if x`, `nil?`,
  `is_a?`, `&&`/`||`/`!`, `case`/`in`, early exits, loops, rescue;
- completion: members of inferred receivers, `Foo::` paths, constants,
  `@ivars`, locals, methods, keywords;
- overload resolution: hover, definition, and signature help show the
  overloads that fit the call's arguments; named-argument completion;
- implementation (overrides, abstract def implementers, subtypes) and
  outgoing call hierarchy;
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
bin/clear-ls dump-cfg FILE LINE                          # print a def's control-flow graph
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

### Compiler integration

Diagnostics come only from the compiler. In the background, clear-ls runs
`crystal build --no-codegen` for each program that contains the file: the
`shard.yml` targets that require it, or the file itself. These checks run at
startup, when a file is opened, and when a file is saved. The compiler reads
files from disk, so diagnostics describe the saved text. Formatting runs
`crystal tool format` on the buffer text. Settings go under
`initializationOptions.compiler`:

```lua
init_options = { compiler = {
  enabled = true,          -- background checks (formatting/expansion always available)
  path = "crystal",        -- executable (default $CRYSTAL or crystal)
  entries = { "src/app.cr" }, -- programs to check instead of shard targets
  debounceMs = 150,
} },
```

Macro expansion preview: `clearLs/expandMacro {textDocument, position}` runs
`crystal tool expand` on the saved file and returns
`{status, message, expansions: [{original, steps: [{source, macros}]}]}`.
Hook macros (`inherited`, `included`) can't be expanded this way. In Neovim:

```lua
vim.api.nvim_create_user_command("CrystalExpand", function()
  local params = vim.lsp.util.make_position_params(0, "utf-16")
  vim.lsp.buf_request(0, "clearLs/expandMacro", params, function(err, res)
    if err then return vim.notify(err.message, vim.log.levels.WARN) end
    local lines = { "# " .. res.message }
    for _, e in ipairs(res.expansions) do
      table.insert(lines, "# " .. e.original)
      for _, s in ipairs(e.steps) do vim.list_extend(lines, vim.split(s.source, "\n")) end
    end
    vim.lsp.util.open_floating_preview(lines, "crystal")
  end)
end, {})
```
