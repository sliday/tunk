#!/usr/bin/env bash
# One command from raw recordings to a graded pass line.
#
#   ./analyse.sh                    grade data/raw
#   ./analyse.sh --holdout          grade data/holdout (critics only)
#   ./analyse.sh --watch            re-run whenever a new session appears
#
# Exists so that recording is the only manual step. Everything after it —
# checking the taps landed, writing ground truth, scoring, and updating the
# progress page — happens in one pass, in the right order, with the failure
# modes that have already bitten this project checked on the way through.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DATA="data/raw"
CRITIC_FLAG=""
WATCH=0
for arg in "$@"; do
  case "$arg" in
    --holdout) DATA="data/holdout"; CRITIC_FLAG="--i-am-a-critic" ;;
    --watch)   WATCH=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

bar()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

run_once() {
  # 0. Never grade with stale tools. A stale bin/ has misled someone three times
  #    here, and `swift build --product A --product B` silently builds only the
  #    last one.
  bar "0. binaries"
  ./bin/refresh.sh 2>&1 | sed 's/^/  /' || { echo "  refresh failed" >&2; return 1; }

  local sessions
  sessions=$(find "$DATA" -maxdepth 2 -name meta.json 2>/dev/null | wc -l | tr -d ' ')
  if [ "$sessions" = "0" ]; then
    bar "no sessions in $DATA"
    note "Record one first:"
    note "  ./bin/tunk-capture guide --surface desk --only tap_deck --taps 20"
    return 1
  fi
  bar "$sessions session(s) in $DATA"

  # 1. Did the taps actually land? This runs BEFORE labelling on purpose: a
  #    session where nobody's taps registered must be caught while the operator
  #    is still set up, not after it has quietly become a denominator.
  bar "1. did the taps land"
  ./bin/tunk-label check "$DATA" 2>&1 | sed 's/^/  /'
  local landed=$?
  [ $landed -ne 0 ] && note "^ some prompted taps did not register; those groups will not be labelled"

  # 2. Ground truth. Only touches tap categories; everything else has none.
  bar "2. ground truth"
  ./bin/tunk-label run "$DATA" --write 2>&1 | sed 's/^/  /'

  # 3. The referee.
  bar "3. pass line"
  ./bin/tunk-score run --data "$DATA" $CRITIC_FLAG \
      --json /tmp/tunk-run.json --check-determinism 2>&1 | sed 's/^/  /'
  local verdict=$?

  # 4. The page, so a phone can watch without interrupting the run.
  bar "4. progress page"
  if [ -f /tmp/tunk-run.json ]; then
    python3 web/ingest.py --from-score /tmp/tunk-run.json \
      --label "$(date '+%H:%M') · $sessions session(s)" 2>&1 | sed 's/^/  /'
    python3 web/schema.py web/progress.json 2>&1 | sed 's/^/  /'
  fi

  bar "next"
  if [ "$DATA" = "data/raw" ]; then
    # This used to suggest a desk tap_palmrest deck, which was the gap when it
    # was written and has not been the gap for a long time. Held-out now has
    # twenty tap gestures on each of the three surfaces; what it has none of is
    # typing or confound sessions, so eight checks read "no data" and the
    # harness cannot return anything but INCOMPLETE however good detection gets.
    note "Held-out decides pass or fail, and it is missing the sessions that"
    note "grade the make-or-break metric. Eight checks currently read no data:"
    note "  ./bin/record-for-the-bar.sh --dry-run   # see the plan, record nothing"
    note "  ./bin/record-for-the-bar.sh             # about 28 minutes"
    note "  ./analyse.sh --holdout"
  else
    note "This is the set that decides. Do not tune against it."
  fi
  return $verdict
}

if [ "$WATCH" = "1" ]; then
  bar "watching $DATA — record a session and this re-runs"
  last=""
  while true; do
    now=$(find "$DATA" -maxdepth 2 -name meta.json 2>/dev/null | sort | md5 2>/dev/null || echo "")
    if [ "$now" != "$last" ]; then
      last="$now"
      run_once
    fi
    sleep 5
  done
else
  run_once
fi
