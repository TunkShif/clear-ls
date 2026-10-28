# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–11 (through startup and warm caches: a two-layer
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
- **Next:** Phase 12 — editing UX and feature gaps from usage feedback
  (accessor references/rename, completion shapes and block snippets,
  settings schema, alias names in hints, `{}` ↔ `do end`, CLI errors)
  ([roadmap.md](roadmap.md#phase-12--editing-ux-and-feature-gaps)).
  Design decisions there need confirming before steps 3–7. Multi-root
  moved to Phase 13.
- **In progress:** nothing.

## Resume

```sh
git log --oneline | head -3
tools/external.sh             # Marten for soak.py / sweep.py
crystal --version             # 1.22.x
make && make spec             # all green
make verify-static
make release && make nvim-check
python3 tools/warm.py         # Phase 11 criteria on Marten
```

Then read [architecture.md](architecture.md) for the code map and
[gotchas.md](gotchas.md) before touching an area.

## Open threads

Known gaps relevant to the next phases (full lists under each phase in the
roadmap and in [architecture.md](architecture.md#known-limitations)):

- Language parity: `tools/book_diff.py` must stay free of mismatches;
  new deviations need a `# cls:` marker and a book-gaps.md entry.
- Diagnostics describe saved files only (compiler limitation).
- Single root (Phase 13). Requires are resolved on every start; cached
  compiler facts may be stale until the first check (see
  [architecture.md](architecture.md#known-limitations)).
