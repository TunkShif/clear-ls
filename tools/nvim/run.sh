#!/bin/sh
# Runs one headless Neovim check: tools/nvim/NAME.lua against a fresh copy of
# tools/fixtures/NAME in a temp dir.
#
#   tools/nvim/run.sh NAME          (or: make nvim-check NVIM_CHECKS=NAME)
#
# Scripts read CLEAR_LS_ROOT (repo), CLEAR_LS_WORK (fixture copy) and
# CLEAR_LS_LOG (server log), print what they observed, and quit.
set -eu
name=$1
repo=$(cd "$(dirname "$0")/../.." && pwd)
fixture="$repo/tools/fixtures/$name"
script="$repo/tools/nvim/$name.lua"
[ -d "$fixture" ] && [ -f "$script" ] || { echo "unknown check: $name" >&2; exit 2; }
work=$(mktemp -d "${TMPDIR:-/tmp}/clear-ls-$name.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp -R "$fixture/." "$work/"
cd "$work"
CLEAR_LS_ROOT=$repo CLEAR_LS_WORK=$work CLEAR_LS_LOG=$work/clear-ls.log \
  timeout "${NVIM_TIMEOUT:-120}" "${NVIM:-nvim}" --clean --headless -n -c "luafile $script" 2>&1
echo
