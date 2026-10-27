# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–8 (through language-semantics parity: every Crystal
  book example matches the compiler or is a recorded deviation,
  [book-gaps.md](book-gaps.md)), plus the post-Phase-8 usage-feedback
  fixes C1–C4, C7 ([roadmap.md](roadmap.md#usage-feedback-after-phase-8-done)).
- **Next:** Phase 9 — workspace identity, split into nine steps in
  [roadmap.md](roadmap.md#phase-9--workspace-identity) (measurements and
  decisions there). Step 1 fixes stale DefMap positions after body edits.
- **In progress:** Phase 9, step 7 (steps 1–6 done).

## Resume

```sh
git log --oneline | head -3
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
- Incoming calls return `[]`; no type hierarchy (Phase 9, step 7).
- Diagnostics describe saved files only (compiler limitation).
- No persistent index cache, no request cancellation, single root
  (Phase 10).
