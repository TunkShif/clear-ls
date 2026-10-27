#!/bin/sh
# Prints the build id baked into ClearLS::Cache::BUILD_ID at compile time:
#   <commit>[.dirty-<digest of uncommitted src/ changes>]+ts-<grammar commit>
# Without git (source tarball) the commit part is "nogit".
cd "$(dirname "$0")/.." || exit 0
if commit=$(git rev-parse --short=12 HEAD 2>/dev/null); then
  dirty=$( { git diff HEAD -- src; git ls-files --others --exclude-standard src | xargs -r cat; } 2>/dev/null | cksum | cut -d' ' -f1)
  if [ -n "$(git status --porcelain -- src 2>/dev/null)" ]; then
    commit="$commit.dirty-$dirty"
  fi
else
  commit=nogit
fi
grammar=$(git -C vendor/tree-sitter-crystal rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
printf '%s+ts-%s' "$commit" "$grammar"
