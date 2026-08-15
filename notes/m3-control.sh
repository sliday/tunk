#!/usr/bin/env bash
# Control for mechanism 3: does a plain inter-onset floor buy the same thing the
# decay prediction does? The decay test rejects when
#   s2 < margin * s1 * exp(-dt/tau),  i.e.  dt < tau * ln(margin * s1/s2),
# which is an interval cut with an amplitude-ratio wobble on it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CFG=notes/m3-control-point.json
printf '%-14s %-28s %s\n' minInterTapMs 'lap det rate trig FP FP/20m p95' 'pooled det rate FP'
for ms in "$@"; do
  cat > "$CFG" <<EOF
{"resonatorHz": 40, "resonatorQ": 2, "defaultThreshold": 0.011,
 "calibratedThreshold": 0.011, "minThresholdG": 0.002,
 "minInterTapMs": $ms}
EOF
  out=$(./bin/tunk-score run --data data/raw --config "$CFG")
  lap=$(printf '%s\n' "$out" | awk '$1=="lap" && NF>10 {printf "%s %s%% %s %s %s %s", $4,$5,$7,$8,$9,$12; exit}')
  pooled=$(printf '%s\n' "$out" | awk '$1=="pooled" && NF>10 {printf "%s %s%% %s", $4,$5,$8; exit}')
  printf '%-14s %-28s %s\n' "$ms" "$lap" "$pooled"
done
rm -f "$CFG"
