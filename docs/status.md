# Status

Where development stands; update at every phase boundary (and when work
stops mid-phase). History and per-phase details are in
[roadmap.md](roadmap.md).

- **Done:** Phases 0–7 (through compiler integration).
- **Next:** Phase 8 — language-semantics parity: fix the gaps that the
  Crystal book's examples exposed ([book-gaps.md](book-gaps.md), harness
  `tools/book_diff.py`). Steps are in the roadmap; design decisions are
  in book-gaps.md. After it: Phase 9, workspace identity.
- **In progress:** Phase 8, steps 1–9 done (all *wrong* book entries fixed,
  ivar rules, narrowing, union shape); next step 10 (C bindings).

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

- No wrong book-example types left; unknown/wider ones remain
  (book-gaps.md, Phase 8 step 10).
- References/rename are local-only; incoming calls return `[]` (Phase 9).
- Diagnostics describe saved files only (compiler limitation).
- No persistent index cache, no request cancellation, single root
  (Phase 10).
