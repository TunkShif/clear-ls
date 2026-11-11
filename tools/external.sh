#!/bin/sh
# Clones the pinned external projects used by soak.py / sweep.py into
# tools/external/ (gitignored) and installs their shards.
#
#   tools/external.sh            (prints the path of each project)
set -eu
repo=$(cd "$(dirname "$0")/.." && pwd)
dest="$repo/tools/external"
mkdir -p "$dest"

fetch() { # name url commit
  dir="$dest/$1"
  if [ ! -d "$dir/.git" ]; then
    git clone -q --filter=blob:none "$2" "$dir" >&2
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$3" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$3" >&2 || true
    git -C "$dir" checkout -q "$3" >&2
  fi
  if [ ! -d "$dir/lib" ]; then
    (cd "$dir" && shards install --skip-postinstall >&2)
  fi
  echo "$dir"
}

# Marten: a large web framework (1366 own files, 457 specs sharing one
# spec_helper).
fetch marten https://github.com/martenframework/marten.git 9c29576b0259e39940017aace50ba1fcbdea5938

# Athena: annotation-heavy components (DI, serializer, console, ORM,
# routing); grammar coverage only (no shards installed: a monorepo).
fetch_src() { # name url commit
  dir="$dest/$1"
  if [ ! -d "$dir/.git" ]; then
    git clone -q --filter=blob:none "$2" "$dir" >&2
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$3" ]; then
    git -C "$dir" fetch -q --depth 1 origin "$3" >&2 || true
    git -C "$dir" checkout -q "$3" >&2
  fi
  echo "$dir"
}
fetch_src athena https://github.com/athena-framework/athena.git d6b704cfb762c6d31cc740eeb99925c2aa9dc652
