#!/usr/bin/env bash
# Rebuild every shipped CLI into bin/ and prove each one is newer than its source.
#
# Exists because a stale bin/ has misled someone three times in this project:
# once shipping the flag-swallowing argument parser after it was fixed, once
# reporting roughly twice the true sample rate after that was fixed, and once
# because of the trap below.
#
# THE TRAP: `swift build --product A --product B --product C` honours only the
# LAST --product. It builds one binary, prints one success line, and exits 0. No
# error, no warning. Two of the three copies then come from whatever was in the
# scratch directory beforehand, which can be hours old.
#
#   ./bin/refresh.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$ROOT/.build-lead"
cd "$ROOT"

declare -a PRODUCTS=(tunk-capture tunk-label tunk-score)

for p in "${PRODUCTS[@]}"; do
  # One product per invocation. See THE TRAP above.
  swift build -c release --product "$p" --scratch-path "$SCRATCH" >/dev/null
  cp "$SCRATCH/release/$p" "$ROOT/bin/$p"
  printf '  built %s\n' "$p"
done

# Newest source in the whole tree, against the oldest binary we just installed.
newest_source=$(find "$ROOT/Sources" -name '*.swift' -exec stat -f '%m' {} + | sort -n | tail -1)
[ -n "$newest_source" ] || { echo "found no sources to compare against" >&2; exit 1; }
fail=0
for p in "${PRODUCTS[@]}"; do
  bin_time=$(stat -f '%m' "$ROOT/bin/$p")
  if [ "$bin_time" -lt "$newest_source" ]; then
    printf '  STALE: bin/%s is older than the newest source file\n' "$p" >&2
    fail=1
  fi
done
[ "$fail" -eq 0 ] || { echo "refresh failed" >&2; exit 1; }

printf '\n  all %d binaries newer than every source file\n' "${#PRODUCTS[@]}"
