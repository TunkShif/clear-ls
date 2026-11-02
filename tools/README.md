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
| `refs_probe ROOT PREFIX` | call-resolution kinds over every body (what a reference index would contain), full-inference time, and name-filtered lookup cost (`NAMES=a,b`); `SHOW=Kind` samples |
| `startup ROOT [RUNS]` | startup split: detect, `Index#load` (walk / parse rounds / require resolution / word sets / trim), DefMap build. `WORKERS=n` |
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

## Load probes on an external project

`tools/external.sh` clones pinned external projects (Marten, 1955 indexed
files) into `tools/external/` (gitignored) and installs their shards.
The scripts use `tools/lsp_client.py` (warm-up off unless asked) and `bin/clear-ls` (`make
release` first; `CLEAR_LS_BIN` overrides). Memory is RSS on Linux and
physical footprint on macOS (`footprint -p`; RSS printed next to it).

| Script | Use |
|---|---|
| `soak.py [--specs N] [--searches N]` | index time and memory, memory after opening N specs, references cold/warm, hover p50/p99 while a references search runs, `$/cancelRequest`; prints `EXIT ok/FAIL` for the Phase 10 exit criteria |
| `warm.py` | Phase 11 criteria: cold vs warm start (persistent cache, temp global dir), first references after the background warm-up vs warm, memory; prints `EXIT ok/FAIL` |
| `sweep.py [--seconds S]` | random-position hover/definition/completion/... over source files: internal errors and timeouts (exit 1), p50/p99/max per method, answers over 300 ms |

## Headless Neovim checks (`tools/nvim/`, `tools/fixtures/`)

`make nvim-check` builds the release binary and runs each check in turn
(each with its own temp global cache, `CLEAR_LS_CACHE_DIR`).
Run a single one with `tools/nvim/run.sh NAME` or `make nvim-check
NVIM_CHECKS=NAME`. `run.sh` copies `tools/fixtures/NAME/` to a temp dir, so
checks may edit and save files there, then runs `tools/nvim/NAME.lua` with
`nvim --clean --headless -n`. Checks print what they observe and don't
assert; read the output against the expectations below.

| Check | Fixture | Expect |
|---|---|---|
| `smoke` | `smoke/src/demo.cr` | typed hovers of locals/block args; member completion on inferred receivers; inlay hints (`11:40 : String?` after the `)`); stdlib definition; glob require hover lists `parts/a.cr parts/b.cr` |
| `calls` | `calls/src/demo.cr` | `IO#gets` overload narrowing (1 vs 4), signature help, named-arg completion, implementation, outgoing calls |
| `chains` | `chains/src/c.cr` | every collection-chain local typed (no `nil`); inferred return in def hover; `&.\|` completes `Item`'s methods (`discounted label name price` first) |
| `workspace` | `workspace/` (project + script + spec + nested project) | references of `sq.area` = `scripts/try.cr:3 spec/shapes_spec.cr:6 src/app.cr:8 src/shapes.cr:13`; `Square` definition in `src/shapes.cr` only (not `other/`); incoming `area_of`; subtypes `Circle Square`; `@side` rename; `area` rename edits app×3, shapes×3, try×1, shapes_spec×1; `puts` refused; hover during references answered first; cancelled job in the log; spec DSL hover (`Spec::Methods#describe`, `#it`, `Spec::Expectations#eq`) and `be_` completion; definition of alias `Shapes` at its use = `src/shapes.cr:24`; `Add require "../src/widget"` |
| `cache` | `cache/` (shard with a `{% for %}` method), run twice on one copy | pass 1 `cache: global 0/N, local 0/2, dirs 0/2`, then `compiler facts: 3 methods`; pass 2 `global N/N, local 2/2, dirs 1/2` (pass 1 added `.clear-ls/` to the root) and index under ~100 ms, facts restored before any check, hover `w : Int32` |
| `editing` | `editing/` (accessor, operator) | completions converted by Neovim's `vim.lsp.completion` and applied: `item.name`, `item.name = `, `items.each &.name = `, `item + `, `puts` (no `()`), `items.map { \|x\|  }` (cursor on `x`), `items.select` |
| `compiler` | `compiler/` (shard with target) | hover before the check, `@label : String` before the check (assignment rule), async diagnostic at 15:8, inlay hints `12: Int32 13: String` refreshed after the check, 1 diagnostic after `:e`, generated methods/ivars typed after it, cleared after fix+save, `compiler:` types for `twice`, `getter` expansion, formatting edit |

Shared helpers (`start`, `req`, `hover`, `set_line`, `finish`) are in
`tools/nvim/common.lua`. A new phase adds a fixture directory and a script
with the same name.
