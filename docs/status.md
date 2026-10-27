# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–10 (through responsiveness: long requests are
  cancellable jobs with budgets, specs share one program view, freed
  parser memory is returned; before that, workspace identity:
  references, rename, incoming calls, type hierarchy and quick fixes by
  resolved identity; earlier: every Crystal book
  example matches the compiler or is a recorded deviation,
  [book-gaps.md](book-gaps.md)), plus the post-Phase-8 usage-feedback
  fixes C1–C4, C7 ([roadmap.md](roadmap.md#usage-feedback-after-phase-8-done)).
- **Also done:** fix round after Phase 10 — top-level `include` and the
  file-body namespace ([roadmap.md](roadmap.md#fix-round-after-phase-10-top-level-include-done)).
- **Next:** Phase 11 — startup and warm caches: work-queue indexing,
  a two-layer persistent cache (global stdlib/shard packs, project-local
  `.clear-ls/cache/`), background warm-up, allocator measurement.
  Measured and split into steps
  ([roadmap.md](roadmap.md#phase-11--startup-and-warm-caches), design in
  [persistent-cache.md](design/persistent-cache.md)); start at step 1.
- **In progress:** nothing.

## Resume

```sh
git log --oneline | head -3
tools/external.sh             # Marten for soak.py / sweep.py
crystal --version             # 1.22.x
make && make spec             # all green
make verify-static
make release && make nvim-check
```

Then read [architecture.md](architecture.md) for the code map and
[gotchas.md](gotchas.md) before touching an area.

## Open threads

Known gaps relevant to the next phases (full lists under each phase in the
roadmap and in [architecture.md](architecture.md#known-limitations)):

- Language parity: `tools/book_diff.py` must stay free of mismatches;
  new deviations need a `# cls:` marker and a book-gaps.md entry.
- Diagnostics describe saved files only (compiler limitation).
- No persistent index cache (Phase 11); single root (Phase 12).
- `String#hash` is seeded per process: fingerprints, word sets and fact
  digests can't be persisted until Phase 11 step 2.
- `ClearLS::VERSION` is still 0.1.0; the version workflow starts with
  Phase 11 step 1 ([development.md](development.md#versions)).
