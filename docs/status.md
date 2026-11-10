# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–17 (last: annotations: completion inside `@[`
  and its arguments, hover on built-in annotations and arguments,
  aliases inside type paths; before that, type definition from inferred types,
  declaration, range formatting from the formatter's hunks; before that,
  macOS: every tool, spec and Neovim
  check runs unchanged on Linux and macOS, folders and documents named
  through symlinks or with `//`, directory listings and unchanged
  stdlib/shard files taken from the cache by mtime, concurrent compiler
  detection; Marten warm start on an M3 Pro 280–363 → 174–237 ms, on
  Linux 235–254 → 209–239 ms; before that, multi-root workspaces: one index per
  workspace folder sharing stdlib/shard trees, each program compiled in
  its project's directory, folders added/removed live; before that,
  snippets and require completion:
  `do ... end` with block parameters, exhaustive `case` branches,
  opt-in definition/control-flow snippets gated by where the compiler
  accepts them, require path completion for local files, stdlib and
  direct shards; before that, editing UX: accessor symbols for
  references/rename, setter/operator/block completion, alias names in
  hints, block form code action, one settings schema; before that,
  startup and warm caches: a two-layer
  persistent index cache, warm start on Marten ~240 ms, compiler facts
  from the last session, a background warm-up that makes the first
  references search warm; before that, responsiveness: long requests are
  cancellable jobs with budgets, specs share one program view, freed
  parser memory is returned; before that, workspace identity:
  references, rename, incoming calls, type hierarchy and quick fixes by
  resolved identity; earlier: every Crystal book
  example matches the compiler or is a recorded deviation,
  [book-gaps.md](book-gaps.md)), plus the post-Phase-8 usage-feedback
  fixes C1–C4, C7 ([roadmap.md](roadmap.md#usage-feedback-after-phase-8-done)).
- **Also done:** fix round after Phase 10 — top-level `include` and the
  file-body namespace ([roadmap.md](roadmap.md#fix-round-after-phase-10-top-level-include-done)).
- **Also done:** hover/definition/highlight/tokens on type parameters
  and `forall` variables
  ([roadmap.md](roadmap.md#hover-and-definition-on-type-parameters-done)).
- **Next:** Phase 18 — C bindings
  ([roadmap.md](roadmap.md#phase-18--c-bindings-lib-fun)), then Phase 19 —
  own tree-sitter-crystal.
- **In progress:** nothing (0.17.1: annotation arguments from tables
  only); Phases 16–17 on `dev/next`, not merged into
  `main`.

## Resume

```sh
git log --oneline | head -3
tools/external.sh             # Marten for soak.py / sweep.py
crystal --version             # 1.22.x
make && make spec             # all green
make verify-static
make release && make nvim-check
python3 tools/warm.py         # Phase 11 criteria on Marten
bin/clear-ls settings-doc > docs/settings.md   # after changing settings.cr
```

Then read [architecture.md](architecture.md) for the code map and
[gotchas.md](gotchas.md) before touching an area.

## Open threads

Known gaps relevant to the next phases (full lists under each phase in the
roadmap and in [architecture.md](architecture.md#known-limitations)):

- Language parity: `tools/book_diff.py` must stay free of mismatches;
  new deviations need a `# cls:` marker and a book-gaps.md entry.
- Diagnostics describe saved files only (compiler limitation).
- Multi-root: references and rename stay in one project's index (see
  [architecture.md](architecture.md#known-limitations)). Requires are
  resolved on every start; cached
  compiler facts may be stale until the first check (see
  [architecture.md](architecture.md#known-limitations)).
