#!/bin/sh
# Build and run the offline counter lab against the production counting sources.
#   scripts/offline-counter-lab.sh ground <trace> <frame>...
#   scripts/offline-counter-lab.sh hand   <trace> <frame>...
#   scripts/offline-counter-lab.sh list   <trace> [accepted|rejected]
#   scripts/offline-counter-lab.sh replay [--v18] [--grip-v2] <trace>...
# Traces are *-after.plist / *-before.plist from a replay folder, or counter.json from a recording review.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/offline-counter-lab"
mkdir -p "$OUT"
STAMP="$OUT/sources.sha"
NEW="$(cat "$ROOT"/kicklab/Counting/*.swift "$ROOT"/scripts/offline-counter-lab/main.swift | shasum | cut -c1-16)"
if [ ! -x "$OUT/counterlab" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$NEW" ]; then
  echo "building counterlab from kicklab/Counting ..." >&2
  swiftc -O -parse-as-library "$ROOT"/kicklab/Counting/*.swift "$ROOT"/scripts/offline-counter-lab/main.swift -o "$OUT/counterlab"
  echo "$NEW" > "$STAMP"
fi
exec "$OUT/counterlab" "$@"
