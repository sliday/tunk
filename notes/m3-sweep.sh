#!/usr/bin/env bash
# Mechanism 3 sweep: resonator decay-prediction margin, log-spaced.
# The prediction falls by exp(-dt/15.92 ms), and the earliest legal second onset
# is 100 ms after the first, so the interesting range spans two orders of
# magnitude either side of 1/exp(-100/15.92) = 535.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CFG=notes/m3-sweep-point.json
printf '%-12s %-28s %s\n' margin 'lap det rate trig FP FP/20m p95' 'pooled det rate FP'
for m in "$@"; do
  cat > "$CFG" <<EOF
{"resonatorHz": 40, "resonatorQ": 2, "defaultThreshold": 0.011,
 "calibratedThreshold": 0.011, "minThresholdG": 0.002,
 "decayPredictionMargin": $m}
EOF
  out=$(./bin/tunk-score run --data data/raw --config "$CFG")
  lap=$(printf '%s\n' "$out" | awk '$1=="lap" && NF>10 {printf "%s %s%% %s %s %s %s", $4,$5,$7,$8,$9,$12; exit}')
  pooled=$(printf '%s\n' "$out" | awk '$1=="pooled" && NF>10 {printf "%s %s%% %s", $4,$5,$8; exit}')
  printf '%-12s %-28s %s\n' "$m" "$lap" "$pooled"
done
rm -f "$CFG"
