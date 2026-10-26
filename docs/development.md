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
4. **End of phase:** update the phase's *Status* and *Measurements* in the
   roadmap and the feature list in `README.md`. Record new pitfalls in
   [gotchas.md](gotchas.md) and structural changes in
   [architecture.md](architecture.md).
5. Stop and report at phase boundaries. Don't push.

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
| Startup index | 0.6–0.75 s (≈460 files: prelude closure + shards + workspace) |
| Stdlib | 1646 files parse in 2.3 s single-thread; items 0.35 s; 15k defs to HIR 0.33 s |
| Inference coverage (`coverage`) | ~94% this repo, ~72% stdlib; repo defs 0.75 s cold, stdlib sample 3.4 s; worst stdlib def ~70 ms cold |
| Completion / hover | 1–3 ms / 0.1–0.3 ms warm; semantic tokens ~4 ms on a 520-line file |
| Compiler check | ~1.9 s this repo, ~0.7 s small project; hover during a check: median 0.2 ms |
| DefMap rebuild | ~4 ms; with compiler facts 5–7 ms |
| Grammar (`make grammar-check`) | 1635/1646 stdlib files parse cleanly |
| Book parity (`tools/book_diff.py`) | 552 markers: 527 match, 25 accepted, 0 mismatches |
