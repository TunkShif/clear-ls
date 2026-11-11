#!/bin/sh
# Grammar coverage gate (Phase 19): files that fail to parse (ERROR or
# MISSING) in the stdlib (`make grammar-check`) and in lib/ +
# tools/external (`make grammar-check-ext`), as sorted lists.
#
#   tools/grammar/coverage.sh save    write the baseline (build/grammar-baseline-*.txt)
#   tools/grammar/coverage.sh check   compare with the baseline; exit 1 if a file was lost
#
# Run `save` on the old GRAMMAR_REV, bump it (`make grammar-update`),
# then `check`.
set -eu
cd "$(dirname "$0")/../.."
mode=${1:-check}
mkdir -p build
for set in std ext; do
  target=grammar-check
  [ "$set" = ext ] && target=grammar-check-ext
  make -s "$target" 2>&1 | grep -E 'ERROR|MISSING' | awk '{print $1}' | sort > "build/grammar-now-$set.txt"
done
if [ "$mode" = save ]; then
  for set in std ext; do mv "build/grammar-now-$set.txt" "build/grammar-baseline-$set.txt"; done
  wc -l build/grammar-baseline-*.txt
  exit 0
fi
lost=0
for set in std ext; do
  base="build/grammar-baseline-$set.txt"
  [ -f "$base" ] || { echo "no baseline $base: run '$0 save' first" >&2; exit 2; }
  now="build/grammar-now-$set.txt"
  echo "== $set: $(wc -l < "$base") -> $(wc -l < "$now") failing files"
  fixed=$(comm -23 "$base" "$now")
  broken=$(comm -13 "$base" "$now")
  [ -n "$fixed" ] && echo "fixed:" && echo "$fixed" | sed 's/^/  /'
  if [ -n "$broken" ]; then
    echo "LOST:" && echo "$broken" | sed 's/^/  /'
    lost=1
  fi
done
exit $lost
