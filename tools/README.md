# tools

Scripts used during development. None of them are needed to build or run
clear-ls.

## Probes (`tools/probes/`)

Crystal programs that use the library directly. Build all of them with
`make probes` (release mode, into `bin/probes/`). Each file starts with a
usage comment.

| Probe | Use |
|---|---|
| `coverage ROOT PREFIX` | inference coverage of locals/block args in indexed files under PREFIX; slow defs. `SHOW=1`, `N=` |
| `types_dump ROOT PREFIX` | every local's type as `file:line name type`; input for `types_diff.py` |
| `unknown_reasons ROOT PREFIX` | why locals stay unknown (unknown receiver, def without return type, ...) with samples |
| `hover_probe ROOT FILE` | hovers every named token of FILE through a real server; misses grouped by CST kind. `ALL=1`, `SHOW=1` |
| `cfg_all DIR` | builds the CFG of every def (crash check + timing) |
| `dump_cst_all FILE` | CST including anonymous tokens and field names |
| `type_marks ROOT FILE...` | clear-ls type of every `__t(expr)` marker, spelled like the compiler; used by `book_diff.py` |

Example: `bin/probes/coverage $PWD $PWD/src`, or with the stdlib as PREFIX
(`crystal env CRYSTAL_PATH`).

## Scripts

| Script | Use |
|---|---|
| `types_diff.py BEFORE AFTER [N]` | regressions/improvements between two `types_dump` outputs |
| `lsp_bench.py` | stdio session against `bin/clear-ls` on this repo: semantic tokens, local definition/references/rename, hover timings |
| `book_diff.py [FILE...]` | compiler `typeof` vs clear-ls for the `__t` markers in `fixtures/book/` (examples from the Crystal 1.22 syntax & semantics book) |
| `gen_syntax.cr` | generates `src/clear_ls/syntax/kinds.cr` (`make syntax-gen`) |

## Headless Neovim checks (`tools/nvim/`, `tools/fixtures/`)

`make nvim-check` builds the release binary and runs each check in turn.
Run a single one with `tools/nvim/run.sh NAME` or `make nvim-check
NVIM_CHECKS=NAME`. `run.sh` copies `tools/fixtures/NAME/` to a temp dir, so
checks may edit and save files there, then runs `tools/nvim/NAME.lua` with
`nvim --clean --headless -n`. Checks print what they observe and don't
assert; read the output against the expectations below.

| Check | Fixture | Expect |
|---|---|---|
| `smoke` | `smoke/src/demo.cr` | typed hovers of locals/block args; member completion on inferred receivers; inlay hints; stdlib definition |
| `calls` | `calls/src/demo.cr` | `IO#gets` overload narrowing (1 vs 4), signature help, named-arg completion, implementation, outgoing calls |
| `chains` | `chains/src/c.cr` | every collection-chain local typed (no `nil`); inferred return in def hover |
| `compiler` | `compiler/` (shard with target) | hover before the check, async diagnostic at 15:8, generated methods/ivars typed after it, cleared after fix+save, `compiler:` types for `twice`, `getter` expansion, formatting edit |

Shared helpers (`start`, `req`, `hover`, `set_line`, `finish`) are in
`tools/nvim/common.lua`. A new phase adds a fixture directory and a script
with the same name.
