# Persistent index cache (Phase 11)

Design for the cache that lets clear-ls skip parsing and lowering on
start. Measured before writing it (October 2026, release build, Crystal
1.22.0); the plan and its outcome are in the
[roadmap](../roadmap.md#phase-11--startup-and-warm-caches).

**As built** (differences from the design below):

- Local entries are validated by size + mtime (ns) only, so a hit
  doesn't read the file; global entries by size + content hash.
- Resolved requires are not stored: they are resolved on every load
  (~7 ms on Marten across workers), which keeps glob requires and new
  files correct without invalidating dependents.
- The build key is `VERSION` + `BUILD_ID` (`tools/build_id.sh`: commit,
  digest of uncommitted `src/` changes, grammar commit) + `SCHEMA` in the
  header; the grammar ABI is implied by the grammar commit.
- Local packs are keyed by Crystal version, target and `CRYSTAL_PATH`.
- Commands: `clear-ls cache info|clear [ROOT]`; no `--no-cache` for the
  other CLI commands (they don't use the cache).
- Packs aren't decoded lazily per file in practice: every indexed file is
  decoded at start (23–27 ms for Marten's 5.9 MB).

## Measurements

Marten (`tools/external.sh`), 1955 indexed files; today `Index#load`
takes ~1.1 s on 8 workers.

| layer | files | source | encoded item trees | gzip | parse+lower (1 thread) | read+hash |
|---|---|---|---|---|---|---|
| stdlib (prelude closure) | 460 | 4.8 MB | 3.6 MB | 1.0 MB | 1.5 s | 6 ms |
| shards (`lib/`) | 149 | 0.8 MB | 0.85 MB | 0.19 MB | 0.24 s | 2 ms |
| project | 1346 | 4.8 MB | 1.5 MB | 0.3 MB | 1.4 s | 6–84 ms |

- Decoding all 1955 trees from one 6 MB binary file: 15–25 ms. Stat of
  every file: ~10 ms. `crystal env` + `crystal --version`: ~27 ms.
- Word sets: ~110k hashes for the Marten workspace (~0.9 MB as `u64`).
- This repo: 489 files, 3.6 MB encoded, load 0.73 s.

So a warm start fits well under the 300 ms target; the remaining cost
is DefMap building and require resolution, which step 1 measures.

## What a cached entry depends on

An `Items::ItemTree` depends only on the file's **text** and on the
clear-ls build (grammar, lowering code):

- `{% if flag?(...) %}` is kept as `Cond`s and evaluated later (require
  resolution, DefMap), so target flags don't enter the tree.
- Ranges are byte offsets, so the file's path doesn't enter it either.
- Requires are stored as written (`Require#path`); resolving them depends
  on `CRYSTAL_PATH`, flags and the requiring file's location, so the
  resolved list (`Index::Entry#requires`) belongs to the project.

That is why trees of the stdlib and of shards can be shared between
projects, while resolved requires and word sets cannot.

## Two layers

| | global | project-local |
|---|---|---|
| where | `$XDG_CACHE_HOME/clear-ls/` (else `~/.cache/clear-ls/`); macOS `~/Library/Caches/clear-ls/`; Windows `%LOCALAPPDATA%\clear-ls\`; override `CLEAR_LS_CACHE_DIR` / `initializationOptions.cache.dir` | `<root>/.clear-ls/cache/`, with `.clear-ls/.gitignore` containing `*` |
| contents | item trees of the stdlib and of each shard version | item trees of project files, path dependencies and extra `CRYSTAL_PATH` entries; resolved requires; word sets; the list of global packs used; compiler facts (below) |
| pack key | stdlib: `stdlib-<crystal version>-<hash of the stdlib's real path>`; shard: `shard-<name>-<version>` from `lib/.shards.info` | one manifest per project |

- **Entries are validated by content, not by key.** Every entry records
  size, mtime and a content hash. Shards are cloned per project (each
  `lib/` has its own mtimes) and people do patch files in `lib/`, so a
  global entry is used only if the size and content hash match. mtime is
  only a shortcut for the local layer: same size and mtime → trust it
  without hashing.
- **Path dependencies** (`path:` in `shard.yml`; `lib/<name>` is a
  symlink) change like project code: they go into the local layer.
- **The stdlib pack grows.** Projects require different parts of the
  stdlib (json, http, ...). A pack is extended with new entries when a
  project needs files it lacks (merge → new pack → rename). Indexing the
  whole stdlib (1646 files) once in the background is a later option.
- **Eviction.** Packs record their last use; `clearLs/clearCache` and
  start-up housekeeping drop packs that weren't used for 30 days, and
  stdlib packs of Crystal installations that no longer exist.

## Invalidation key

Every pack header holds a build key; a mismatch means the pack is
ignored and rewritten, never an error.

- `ClearLS::VERSION`: bumped as part of the workflow
  ([development.md](../development.md#versions)).
- `Cache::SCHEMA`: an integer bumped when the file format changes.
- `Syntax::Grammar.abi_version` and the tree-sitter-crystal commit.
- Dirty-tree builds (uncommitted changes, detected by the Makefile) add
  the build time, so a work-in-progress binary never reads packs written
  by an older one. Their packs are evicted like any other.

Crystal upgrades need no key: they change the stdlib path and version,
so the pack name changes. Specs use a temp cache directory.

## Hashes must be stable

Crystal's `String#hash` is seeded randomly per process (two runs of
`p "hello".hash` print different values). `ItemTree#fingerprint`,
`Index.words` and `CompilerFacts#digests` all use it, so as written they
can't be stored. They move to a fixed 64-bit hash written in clear-ls,
such as FNV-1a or xxHash64. Not `Digest::CRC32` (adds libz) or
`Digest::SHA256` (adds OpenSSL): the binary links neither today.

## File format

Custom binary with `IO#write_bytes` (little-endian). JSON was rejected
because it is several times larger and slower to decode; MessagePack would
need a shard.

```text
header     magic "CLSC" | schema u32 | build key str | kind u8 (stdlib/shard/local)
           | pack key str | created / last-used time
strings    string table: count, then length-prefixed UTF-8 (names, restrictions,
           docs and types repeat heavily; payloads refer to indices)
directory  per file: relative path, size u64, mtime i64, content hash u64,
           payload offset u32, length u32
payloads   per file: ItemTree — items (kind, visibility, origin, name, ranges,
           doc, detail, annotations, Cond tree, header, signature, includes,
           extends, children), requires as written (+ conditions), mixins,
           recovered flag; local layer adds resolved requires and the word set
trailer    checksum u64 of everything above
```

- The directory allows decoding files lazily, one at a time.
- Packs are never modified in place. A writer writes `<name>.tmp.<pid>`
  and renames it over the pack, so readers (another editor, another
  clear-ls) always see a whole file. A bad checksum or a short read
  means the pack is treated as missing.
- The codec is written by hand for every record. A round-trip spec
  (encode, then decode the stdlib and a fixture project, and compare
  fingerprints and `dump-items` output) catches a field added to `Item`
  but not to the codec.

## Compiler facts

Facts are what the exporter prints after a `crystal build --no-codegen`
of an entry point. They include methods generated by macros and the
types of undeclared ivars, for types with code under the project root,
which includes `lib/` shards but not the stdlib.

**Facts are a property of the whole program, not of a library.** An
experiment with a shard `libx` in `lib/` and a project using it (the
exporter source from `Exporter.source`, `crystal build --no-codegen`,
Crystal 1.22) showed:

- `macro included` in the shard, with `include Libx` in project class
  `Foo`, gives the fact `Foo#generated_foo`, located in the project
  file.
- `macro finished` with `@type.all_subclasses` in shard class
  `Libx::Base`, after the project adds `class Widget < Libx::Base`,
  gives `Libx::Base.make_widget`. The location is in the **shard's**
  file, but it exists only because of the project.
- When the project reopens a shard class (`class Libx::Counter; def
  reset; ...`), new members and ivar assignments are added to the
  shard's type, and its ivar types are unions over every assignment in
  the program.
- Ivar types did not depend on call sites: an unrestricted `@x` that
  can only be typed from calls is a compile error asking for an
  annotation. Calls with different argument types didn't change facts.
- Target flags, `-D` defines, `compare_versions(Crystal::VERSION, ...)`
  and which files are required at all (a shard file outside the closure
  has no facts) all change the output.

So facts are **never stored in the global layer**. They are stored in the
project-local layer as the merged snapshot per entry point
(`Diagnostics#@entry_facts`), keyed by entry, Crystal version, flags and
build key, together with the per-file digests they already carry
(switched to the stable hash).

On a warm start the snapshot is applied immediately, under the existing
rule: facts of a file whose saved text no longer matches its digest are
skipped. The first check replaces the snapshot. This covers edits to the
file that contains the fact's location. It does **not** cover a fact
caused by another file, like `make_widget` after `Widget` was deleted
while the server was not running: such a fact stays until the first
check finishes. That is acceptable for best-effort semantics, and still
better than no macro-generated members until the first check (Marten
models' fields and `JSON::Serializable` methods come from facts).

## Commands and options

- `clear-ls lsp --no-cache` and `initializationOptions.cache.enabled =
  false`: neither read nor write.
- `clearLs/clearCache` (`workspace/executeCommand`): drops the project's
  local layer and the global packs it uses, then re-indexes.
- `clear-ls cache info` / `cache clear` CLI for inspection.

## Open questions

- DefMap building and require resolution on a warm start are not
  measured yet. If they dominate, a later step can cache resolved
  views, but that needs invalidation over the whole require closure.
- Whether to index the full stdlib in the background so every project
  shares one complete stdlib pack.
