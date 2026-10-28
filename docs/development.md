# Development

## Setup

Crystal 1.22 (1.21.0 crashed at startup), a C compiler, `git`, `make`;
Neovim ≥ 0.11 and Python 3 for the checks in `tools/`.

```sh
make && make spec      # all green; ~9 s (some specs run the real compiler)
make verify-static     # Tree-sitter runtime and grammar linked statically
make release           # optimised binary; use it in the editor and for timings
```

The first build after `make distclean` clones Tree-sitter v0.26.9 and
tree-sitter-crystal `50ca9e6` into `vendor/` (gitignored) and installs the
shard into `lib/`.

## Workflow

Work proceeds phase by phase ([roadmap.md](roadmap.md)):

1. **Before a phase:** measure what blocks it (probes, compiler tools), then
   split it into steps in the roadmap and commit that plan
   (`docs: split phase N into steps`).
2. **Each step is one commit.** Use conventional commits: a short subject,
   and a body that says *why* (e.g. `feat(lsp): async compiler
   diagnostics`).
3. **Verify in a real client** before calling a phase done: `make
   nvim-check`, plus a new check under `tools/nvim/` for the phase's
   features.
4. **Bump the version** with the change that needs it
   ([Versions](#versions)).
5. **End of phase:** update the phase's *Status* and *Measurements* in the
   roadmap and the feature list in `README.md`. Record new pitfalls in
   [gotchas.md](gotchas.md) and structural changes in
   [architecture.md](architecture.md).
6. Stop and report at phase boundaries. Don't push.

## Versions

`ClearLS::VERSION` (`src/clear_ls/version.cr`) and `shard.yml`'s
`version` stay equal. The version is reported in `serverInfo` and by
`clear-ls version`. It is also part of the persistent cache's build key
([persistent-cache.md](design/persistent-cache.md#invalidation-key)), so
a wrong version can make a new binary read caches written by an old one.

While pre-1.0, `0.<phase>.<patch>`:

- **Minor** = the last completed phase: set in the commit that closes the
  phase (`chore: release 0.11.0`), patch reset to 0.
- **Patch** bumped in any commit that changes what is cached or how it
  is read: item lowering (`src/clear_ls/items/`), the grammar pin, the
  cache codec, the stable hash, or the compiler facts exporter. Also once
  per fix round. The bump goes in the same commit as the change.
- Bumping the cache `SCHEMA` (format change) also bumps the patch.

## Tests

`spec/` holds unit specs per layer and LSP-level feature specs driven by
`spec/support/feature_client.cr`. Each feature spec gets a temp project and
a scripted JSON-RPC session, optionally with the fake stdlib from
`spec/support/prelude.cr` (`PRELUDE` / `PRELUDE_FILES`). Property tests
cover incremental reparse vs fresh parse (600 random edits) and LineIndex
round-trips. Compiler specs (`spec/compiler/`, `features_phase7_spec.cr`)
run the installed `crystal`.

## Tools

See [tools/README.md](../tools/README.md): analysis probes (`make probes`),
headless Neovim checks (`make nvim-check`), an LSP timing script, and a
type-regression diff.

**Language parity:** `make bin/probes/type_marks && tools/book_diff.py`
compares clear-ls with the compiler on the book fixtures; it prints
nothing but per-file counts when there is no mismatch. Run it next to the
regression diff below when changing inference.

**Inference regression workflow** (it caught most bugs). Build
`types_dump` at the old commit in a separate `git worktree`, never with
`git checkout REV -- src`. Dump the repo and the stdlib before and after
the change, then run `tools/types_diff.py`. A local that goes from known
to unknown is a regression.

**Large-project checks** (Phase 10): `tools/external.sh` once, then
`python3 tools/soak.py` (prints `EXIT ok/FAIL` per criterion) and
`python3 tools/sweep.py` (exit 1 on internal errors or timeouts). Run them
after changes to views, jobs, the reference search, or caches, and
`python3 tools/warm.py` (Phase 11 criteria) after changes to the cache,
indexing, or warm-up.

## Ad-hoc scripts

Throwaway scripts in the repo root named `*_tmp.cr` are gitignored:

```sh
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache PKG_CONFIG_PATH=$PWD/build/pkgconfig \
  crystal run -Dcrystal_tree_sitter_no_init x_tmp.cr
```

A script that turns out useful moves to `tools/probes/` with a usage
header (it then builds with `make probes`).

## Baselines

Release build, this repository; compare against these when changing hot
paths. Per-phase numbers are in the roadmap.

| What | Value |
|---|---|
| Startup index | cold 0.4–0.63 s (≈490 files: prelude closure + shards + workspace); warm from the cache: Marten ~0.24 s to the first answer (`tools/warm.py`) |
| Stdlib | 1646 files parse in 2.3 s single-thread; items 0.35 s; 15k defs to HIR 0.33 s |
| Inference coverage (`coverage`) | ~94% this repo, ~72% stdlib; repo defs 0.75 s cold, stdlib sample 3.4 s; worst stdlib def ~70 ms cold |
| Completion / hover | 1–3 ms / 0.1–0.3 ms warm; semantic tokens ~4 ms on a 520-line file |
| Compiler check | ~1.9 s this repo, ~0.7 s small project; hover during a check: median 0.2 ms |
| DefMap rebuild | ~4 ms; with compiler facts 5–7 ms |
| Grammar (`make grammar-check`) | 1635/1646 stdlib files parse cleanly |
| Spec suite (`make spec`) | 287 examples, ~40 s |
| Block form round trip (full stdlib) | 5195 blocks: 5109 convert, 86 refused, ~4 min with `BLOCK_FILES=9999 BLOCKS_PER_FILE=9999` |
| Book parity (`tools/book_diff.py`) | 552 markers: 527 match, 25 accepted, 0 mismatches |
| Marten soak (`tools/soak.py`) | index 0.82–0.84 s cold (`CLEAR_LS_ARGS=--no-cache`) / ~130 MB RSS; 100 specs + 10 searches 234–244 MB; hover p99 during a search 38–80 ms |
| Marten warm-up (`tools/warm.py`) | ~7.5 s idle, RSS 300 MB; first references after it 88 ms (cold 1.3 s, warm 36–44 ms) |
| Marten sweep (`tools/sweep.py`, 120 s) | 64,696 requests, 0 errors, 1 answer over 300 ms |
