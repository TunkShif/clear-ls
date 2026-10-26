# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–8 (through language-semantics parity: every Crystal
  book example matches the compiler or is a recorded deviation,
  [book-gaps.md](book-gaps.md)), plus the post-Phase-8 usage-feedback
  fixes C1–C4, C7 ([roadmap.md](roadmap.md#usage-feedback-after-phase-8-done)).
- **Next:** Phase 9 — workspace identity. Start with workspace scope (C6)
  and ivar definitions (C5), both planned in the roadmap, then the
  `DefId`-keyed reference index (workspace references/rename, type
  hierarchy, incoming calls, code actions). Measure first, then split
  into steps ([development.md](development.md#workflow)).
- **In progress:** nothing.

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
- References/rename are local-only; incoming calls return `[]` (Phase 9).
- Definition on `@ivar` returns nothing (C5, Phase 9).
- Every `.cr` under the root shares one DefMap, even unrelated projects
  and loose files (C6, Phase 9).
- Diagnostics describe saved files only (compiler limitation).
- No persistent index cache, no request cancellation, single root
  (Phase 10).
