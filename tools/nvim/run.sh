#!/bin/sh
# Runs one headless Neovim check: tools/nvim/NAME.lua against a fresh copy of
# tools/fixtures/NAME in a temp dir.
#
#   tools/nvim/run.sh NAME          (or: make nvim-check NVIM_CHECKS=NAME)
#
# Scripts read CLEAR_LS_ROOT (repo), CLEAR_LS_WORK (fixture copy),
# CLEAR_LS_LOG (server log) and CLEAR_LS_PASS (1, or 2 for the second
# run of the `cache` check), print what they observed, and quit.
set -eu
name=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture="$repo/tools/fixtures/$name"
script="$repo/tools/nvim/$name.lua"
[ -d "$fixture" ] && [ -f "$script" ] || { echo "unknown check: $name" >&2; exit 2; }
# Real path: on macOS $TMPDIR is under the /var -> /private/var symlink and
# ends in `/`, and Neovim names buffers by real path while folders keep the
# given one.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/clear-ls-$name.XXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT
cp -R "$fixture/." "$work/"
cd "$work"
# Checks get their own global cache dir (the `cache` check runs twice on
# one copy to see a warm start; the others see an empty cache).
export CLEAR_LS_CACHE_DIR="$work/.global-cache"
# GNU timeout; macOS has none by default (coreutils' gtimeout, else perl:
# the alarm survives exec).
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$@"
  else perl -e 'alarm shift; exec @ARGV' "$@"
  fi
}
passes=1
[ "$name" = cache ] && passes=2
pass=1
while [ "$pass" -le "$passes" ]; do
  CLEAR_LS_PASS=$pass CLEAR_LS_ROOT=$repo CLEAR_LS_WORK=$work CLEAR_LS_LOG=$work/clear-ls.$pass.log \
    with_timeout "${NVIM_TIMEOUT:-120}" "${NVIM:-nvim}" --clean --headless -n -c "luafile $script" 2>&1
  echo
  pass=$((pass + 1))
done
