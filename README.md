# clear-ls

A fast, error-tolerant language server for [Crystal](https://crystal-lang.org),
written in Crystal.

clear-ls gives you completion, hover types, go-to-definition, references,
rename, inlay hints and more while you type, including in unsaved files and
in code that doesn't parse yet. It doesn't wait for the compiler.

## The idea

Crystal's compiler only answers questions about a program once the whole
program compiles. That's too slow and too strict for an editor, where the code
is half-written most of the time. clear-ls splits the work in two:

- **An editor-oriented semantic model answers interactive requests.**
  [Tree-sitter](https://tree-sitter.github.io) parses each file
  incrementally and tolerates errors. clear-ls builds its own index of
  declarations from that parse, then lowers method bodies to a control-flow
  graph and runs flow-sensitive type inference with overload resolution.
  Requests are answered in milliseconds from the current buffer text.
- **The compiler stays the source of truth.** Diagnostics, formatting, macro
  expansion and macro-generated methods come from the real `crystal` compiler.
  It runs in the background and never blocks editing. clear-ls never
  publishes errors of its own.

When clear-ls can't work out a type, it says the type is unknown rather than
guessing from names. Wrong answers do more damage than missing ones.

## Features

### Navigation

- **Go to definition** for types, constants, locals, instance variables,
  method calls and `require` paths. For an overloaded method, it goes to the
  overloads that match the call's arguments.
- **Find references** and **document highlights**, based on resolved
  identity. Overloads, unrelated methods that share a name, and other programs
  are kept apart.
- **Go to implementation**: overrides, implementers of an abstract `def`,
  and subtypes.
- **Go to type definition**: the declaration of the inferred type of a
  local, instance variable, literal or call result (each member of a union,
  `Nil` included). **Go to declaration** is the same as go to definition.
- **Call hierarchy** (incoming and outgoing) and **type hierarchy**
  (supertypes and subtypes).
- **Document and workspace symbols**, and **document links** for `require`
  paths.

### Types and information

- **Hover**: the inferred types of locals, resolved method signatures, and
  inferred return types of methods that don't declare one. On a saved file,
  hover adds local types confirmed by the compiler.
- **Inlay hints**: types of locals, block parameters and inferred return
  types. Each kind can be turned on or off, and types written as an `alias`
  are shown by the alias's name.
- **Signature help** that shows the overloads matching the arguments typed
  so far.
- **Annotations**: hover on the compiler's built-in annotations (which
  have no source) and on the arguments of built-in and stdlib
  annotations (`ldflags:`, `key:`, the `"m"` of `@[Link("m")]`), from
  fixed tables. Arguments of shard and user annotations are not known
  (no fixed doc format; the macros reading them are linked to the use
  site only at expansion time).
- **Semantic tokens** for parameters, locals, instance variables, types and
  declarations.

### Completion

- Members of the inferred receiver type (including unions), `Foo::` paths,
  constants, `@ivars`, locals, methods, keywords and named arguments.
- **Snippets that fit the call:**
  - block-only methods complete with a block: `xs.ma` → `xs.map { |x| }`;
  - setters complete as `x.name = ` and operators as `x + `;
  - typing `do` writes `do |x| ... end` with the method's block parameters.
- **Exhaustive `case`**: typing `in` or `when` inserts every missing branch
  (enum members, union members, `true`/`false`, concrete subclasses).
- **`require` paths**: local files, the standard library and your direct
  shard dependencies. Every suggestion is checked to resolve.
- Optional `class`/`def`/`if`/... skeletons, offered only where Crystal
  accepts them (off by default).
- **Annotations**: inside `@[` only annotations (and the namespaces or
  aliases that hold one, `@[ADI::`) are offered, including the compiler's
  own (`Raises`, `Packed`, ...); inside `@[Name(` the named arguments of
  a built-in or stdlib annotation (`Link`, `JSON::Field`, ...), minus
  those already given.

### Refactoring and code actions

- **Rename** across the program, by identity. Rename refuses to run if any
  use can't be confirmed, and it renames a method's overrides with it. An
  accessor such as `property name` is renamed as one symbol: `name`,
  `name=`, `name?`, `@name` and named `new` arguments.
- **Quick fixes** from compiler diagnostics ("did you mean", missing
  `require`).
- **Rewrite blocks** between `{ ... }` and `do ... end`.

### Compiler integration

- **Diagnostics** from `crystal build --no-codegen`. Checks run in the
  background on open and save, for every program that includes the file.
- **Formatting** with `crystal tool format`, of the document or a range.
  `crystal tool format` has no range option, so range formatting formats the
  whole buffer and applies only the changed hunks that touch the selected
  lines (as conform.nvim does for such formatters). A kept hunk can extend
  past the selection, and the buffer must parse.
- **Macro expansion preview** with `crystal tool expand` (see
  [Neovim](#neovim)).
- **Macro-generated code**: methods generated by hooks, `{% for %}` and other
  macros, and instance variable types, are imported from the last compiler
  check. They're available for completion and navigation.

### Language coverage

- Flow-sensitive local types: branch joins, narrowing by `if x`, `nil?`,
  `is_a?`, `responds_to?`, `&&`/`||`/`!`, `case`/`in`, early exits, loops and
  `rescue`.
- Return types of unannotated methods are inferred for each call, so chains
  like `map`, `compact_map`, `find`, `reduce`, `group_by` and `to_h` keep
  concrete types.
- Generics, splats, named and default arguments, number autocasting, procs and
  closures, `with ... yield`, `previous_def`/`super`, enums, C bindings, and
  `{% if flag?(...) %}` declarations.
- Every example in the Crystal 1.22 *Syntax and semantics* book gets the
  compiler's type, or a documented difference in
  [docs/book-gaps.md](docs/book-gaps.md).

### Workspaces and performance

- **Multi-root workspaces.** Each workspace folder, and each nested project,
  has its own `lib/`, program views and compiler checks. You can add and
  remove folders while the server runs.
- **Each file sees what its program sees.** Shard targets, spec programs,
  scripts and loose files each get their own view of the code.
- **Fast startup.** A persistent index cache shares stdlib and shard
  declarations across projects. A warm start on
  [Marten](https://github.com/martenframework/marten) (1,955 files) takes
  about 200 ms.
- **Responsive on large projects.** References, rename and incoming calls
  run as cancellable background jobs with time budgets. While the editor is
  idle, a background pass warms up inference, so the first references search
  is fast.
- Settings are applied live through `workspace/didChangeConfiguration`.

## Installation

Prebuilt binaries are attached to each [GitHub release](https://github.com/TunkShif/clear-ls/releases)
for Linux (x86_64 and ARM64) and macOS (Apple Silicon):

```sh
# e.g. for macOS on Apple Silicon
tar -xzf clear-ls-*-aarch64-apple-darwin.tar.gz
ln -sf "$PWD/clear-ls" ~/.local/bin/clear-ls
```

Each archive contains the `clear-ls` binary and a short README, with a
`.sha256` checksum file alongside it.

To build from source instead:

**Requirements:** Crystal ≥ 1.22, a C compiler, `git` and `make`. Linux and
macOS are supported.

```sh
git clone https://github.com/TunkShif/clear-ls.git
cd clear-ls
make release
```

This fetches pinned versions of the Tree-sitter runtime and the
`tree-sitter-crystal` grammar, builds them as static libraries, and builds an
optimized `bin/clear-ls`. Put the binary on your `PATH`:

```sh
ln -s "$PWD/bin/clear-ls" ~/.local/bin/clear-ls
clear-ls version
```

At runtime, clear-ls needs the `crystal` executable. It reads `CRYSTAL_PATH`,
the compiler version and the target from `crystal env`. To use a different
executable, set `CRYSTAL=/path/to/crystal` or the `compiler.path` setting.

## Usage

Your editor starts the server on stdio:

```sh
clear-ls lsp [--log-level debug] [--log-file PATH] [--no-cache]
```

Other commands:

| Command | |
|---|---|
| `clear-ls version` | Version, build ID and grammar ABI |
| `clear-ls cache info [ROOT]` | Locations and sizes of the persistent cache |
| `clear-ls cache clear [ROOT]` | Delete a project's cache and the global packs it uses |
| `clear-ls settings-doc` | Print the settings reference |
| `clear-ls dump-cst FILE` / `dump-items FILE` | Print the syntax tree or the declarations of a file |
| `clear-ls dump-hir FILE LINE` / `dump-cfg FILE LINE` | Print the body IR or control-flow graph of the `def` at LINE |

### Set up your project: list programs in `shard.yml`

clear-ls learns which programs a project has from the `targets` in
`shard.yml`. Without them, it falls back to everything under `src/`. A file
that no target includes is compiled on its own, so it can report false errors
when it depends on another file's `require`s. List every program:

```yaml
targets:
  server:
    main: src/server.cr
  manage:
    main: manage.cr
```

Targets don't change dependency resolution. They only define what
`shards build` builds. You can also set the programs with the
`compiler.entries` setting.

The compiler reads files from disk, so diagnostics describe the last saved
version of a file. Everything else uses the text in the buffer.

### Cache

- Stdlib and shard declarations are cached in `~/.cache/clear-ls` (on macOS,
  `~/Library/Caches/clear-ls`; override with `CLEAR_LS_CACHE_DIR`). All
  projects share this cache.
- Project declarations and the last compiler facts are cached in
  `<project>/.clear-ls/cache/`. That directory contains its own `.gitignore`.

When you upgrade clear-ls or Crystal, or change the target, the cache is
rebuilt automatically. A damaged cache file is ignored. To start from scratch,
run `clear-ls cache clear`, or send the `clearLs/clearCache` request from your
editor.

### Configuration

Pass settings as `initializationOptions`, or under `clearLs` with
`workspace/didChangeConfiguration`. Available groups: `compiler.*`,
`completion.*`, `inlayHints.*`, `references.*`, `budgets.*`, `cache.*` and
`warmup.*`. Each setting is documented in
[docs/settings.md](docs/settings.md).

## Neovim

Neovim 0.11 or later, with the built-in LSP client. Neovim already detects
`.cr` files as `crystal`.

Create `~/.config/nvim/lsp/clear_ls.lua`:

```lua
return {
  cmd = { "clear-ls", "lsp" }, -- add "--log-file", "/tmp/clear-ls.log" to debug
  filetypes = { "crystal" },
  root_markers = { "shard.yml", ".git" },
  init_options = {
    completion = { blockStyle = "braces" }, -- or "do"
  },
}
```

Then enable it in your `init.lua`, along with inlay hints, which Neovim turns
off by default:

```lua
vim.lsp.enable("clear_ls")
vim.lsp.inlay_hint.enable(true)
```

**Completion plugins.** clear-ls completes method names without `()`, which
is the usual Crystal style (`puts "hi"`, `user.name`). blink.cmp adds
brackets unless you turn that off for Crystal:

```lua
require("blink.cmp").setup({
  completion = {
    accept = { auto_brackets = { blocked_filetypes = { "crystal" } } },
  },
})
```

If you use nvim-cmp with nvim-autopairs, exclude Crystal there instead:
`cmp_autopairs.on_confirm_done({ filetypes = { crystal = false } })`.

**More than one project.** To add a folder to the running server, run
`:lua vim.lsp.buf.add_workspace_folder("/path/to/other")`. Buffers under that
folder then attach to the same client. References and rename stay within one
project. Workspace symbols cover all of them.

**Macro expansion.** `clearLs/expandMacro` expands the macro call under the
cursor in the saved file. Hook macros such as `inherited` and `included`
can't be expanded this way. This command shows the expansion in a floating
window:

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

### Other editors

Any LSP client that can start a stdio server works. Configure it to run
`clear-ls lsp` for Crystal files and to send settings under the `clearLs`
key. The server also handles these custom requests:

| Request | Params | Result |
|---|---|---|
| `clearLs/expandMacro` | `{textDocument, position}` | `{status, message, expansions: [{original, steps: [{source, macros}]}]}` |
| `clearLs/clearCache` | none | Deletes the caches and re-indexes |
| `clearLs/syntaxTree` | `{textDocument}` | The file's syntax tree as an S-expression (for debugging) |

## Known limitations

- Diagnostics describe the last saved version of a file, because the
  compiler reads from disk.
- References, rename and call/type hierarchy stay within the project that
  the request starts from.
- Locals inside macro bodies are not analyzed. Inlay hints don't cover
  parameters.
- The server runs on one thread. Long requests yield to others, but requests
  run one at a time.
- Windows isn't supported yet.

See [docs/architecture.md](docs/architecture.md#known-limitations) for the
full list.

## How it works

```text
VFS (disk + unsaved buffers) → snapshot → Tree-sitter CST (incremental)
   ├── declarations → ItemTree → DefMap (+ compiler facts) → Index
   └── bodies (on demand) → HIR → CFG → flow-sensitive inference → overload resolution
                                              ↑ per-call return summaries
crystal build / tool (background) → diagnostics, macro facts, expansions, formatting
```

- **Two trees.** Declarations (classes, methods, constants) and method bodies
  are separate representations. Declarations are merged across reopened types
  into a `DefMap` that does lookups the way the compiler does. Bodies are
  lowered on demand and cached per file revision. Editing a method body
  doesn't rebuild the declaration index.
- **Inference.** Each body becomes a control-flow graph. A dataflow solver
  computes the type of every local at every point, narrowing at each branch.
  Calls are resolved against all overloads with three-valued matching
  (yes / no / maybe), so unknown arguments never rule out an overload.
  Return types of unannotated methods are computed per call shape, with
  budgets that keep requests responsive.
- **Program views.** Each program (a shard target, a spec suite, a script)
  gets its own `DefMap` built from its own `require` closure, so a file sees
  the same declarations the compiler would see.
- **Compiler facts fill gaps.** After each background check, an exporter
  collects methods and instance variables that macros generated. These are
  added only where the source has no declaration, labeled as coming from the
  compiler, and dropped for files saved since the check.
- **Static Tree-sitter.** The Tree-sitter runtime and Crystal grammar are
  compiled from pinned sources and linked into the binary. There's no
  dynamic dependency to install.

The code is organized in layers under `src/clear_ls/`: `syntax`, `vfs`,
`items`, `cache`, `semantics`, `workspace`, `hir`, `flow`, `types`,
`compiler`, `ide` and `lsp`. Each layer depends only on the layers below it,
and only `syntax/` uses Tree-sitter directly. The `ide` layer has no protocol
types, and `lsp` maps it to JSON-RPC.

### Further reading

- [Architecture](docs/architecture.md): the code map, design decisions and
  internals by area.
- [Semantic architecture](docs/design/crystal-lsp-semantic-architecture.md):
  the design behind the CST/HIR split, DefMap, CFG, inference and overloads.
- [Cursor position lookup](docs/design/cursor-position-semantic-lookup.md):
  how a cursor position is mapped to semantic data.
- [Persistent cache](docs/design/persistent-cache.md): cache layers,
  invalidation and file format.
- [Book gaps](docs/book-gaps.md): known differences from the language
  reference.
- [Tree-sitter grammar notes](docs/tree-sitter-grammar-notes.md): known
  parse gaps.
- [Settings](docs/settings.md), [Roadmap](docs/roadmap.md),
  [Status](docs/status.md).

## Development

```sh
make            # debug build of bin/clear-ls
make spec       # run the specs
make verify-static
make nvim-check # headless Neovim checks against tools/fixtures/
```

See [docs/development.md](docs/development.md) for the workflow and
[docs/gotchas.md](docs/gotchas.md) before you change an area. The scripts in
`tools/` are described in [tools/README.md](tools/README.md).

## License

[MIT](LICENSE)
