#!/usr/bin/env bash
# Per-trigger trace on every lap session at a given decay-prediction margin.
#   bash notes/m3-explain.sh <margin>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
M="$1"
CFG=notes/m3-explain-point.json
cat > "$CFG" <<EOF
{"resonatorHz": 40, "resonatorQ": 2, "defaultThreshold": 0.011,
 "calibratedThreshold": 0.011, "minThresholdG": 0.002,
 "decayPredictionMargin": $M}
EOF
for d in data/raw/tap_deck__lap__*; do
  echo "### $(basename "$d")"
  ./bin/tunk-score explain "$d" --config "$CFG" | awk '/^\| [0-9]+ \| +[0-9]/ && /s \|/'
done
rm -f "$CFG"
