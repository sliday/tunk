#!/usr/bin/env bash
# List every lap false trigger at a given decay-prediction margin.
#   bash notes/m3-fps.sh <margin>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
M="$1"
CFG=notes/m3-fps-point.json
cat > "$CFG" <<EOF
{"resonatorHz": 40, "resonatorQ": 2, "defaultThreshold": 0.011,
 "calibratedThreshold": 0.011, "minThresholdG": 0.002,
 "decayPredictionMargin": $M}
EOF
for d in data/raw/tap_deck__lap__*; do
  s=$(basename "$d" | sed 's/.*__//')
  ./bin/tunk-score explain "$d" --config "$CFG" \
    | grep 'FALSE TRIGGER' \
    | sed "s/^/$s /" \
    | cut -c1-110
done
rm -f "$CFG"
