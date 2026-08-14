#!/bin/bash
# Records exactly what the PRD bar still needs, and nothing else.
#
# `tunk-score --data data/holdout` currently returns INCOMPLETE rather than a
# verdict, because eight checks have no data behind them: typing and confound
# sessions are missing on all three surfaces. Detection is measured out of
# sample; the make-or-break metric never has been.
#
# It also records a larger lap tap deck. At twenty gestures a surface, 98 % can
# only be met by 20/20, so one gesture is five points and the set cannot tell a
# real fix from luck.
#
# Headphones on. The tool speaks and beeps, and through speakers both of those
# shake the chassis into the data.
#
# Around 28 minutes of recording plus repositioning. Ctrl-C at any point flushes
# the stream and writes a valid session, so stopping early costs only what has
# not been recorded yet.
set -euo pipefail
cd "$(dirname "$0")/.."

CAPTURE=./bin/tunk-capture
OUT=data/holdout
SPLIT=test

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [ "${1:-}" = "--dry-run" ]; then
    say "Plan (nothing will be recorded)"
    for s in desk soft lap; do
        echo "  $s: typing 300 s, then confound_music and confound_handling at 90 s each"
    done
    echo "  lap: an extra 60-gesture tap deck"
    echo
    echo "  Total: about 28 minutes of recording."
    exit 0
fi

$CAPTURE doctor --seconds 3

for surface in desk soft lap; do
    say "=== $surface : put the machine on the $surface, then follow the prompts ==="

    # The make-or-break metric, out of sample. Five minutes each, because the
    # input gate mutes the detector for about 86 % of typing time and the
    # honest exposure is what is left.
    $CAPTURE guide --surface "$surface" --only typing --typing-sec 300 \
             --out "$OUT" --split "$SPLIT" \
             --notes "held-out typing, for the zero-false-triggers bar"

    # confound_handling has never been recorded on any surface, and it is the
    # one that prices the lap false-trigger question: four of the six lap false
    # triggers look like the machine being shifted rather than tapped.
    $CAPTURE guide --surface "$surface" --only confound_handling,confound_music \
             --confound-sec 90 --out "$OUT" --split "$SPLIT" \
             --notes "held-out confounds; handling prices the lap false triggers"
done

say "=== lap, larger tap deck : sixty gestures ==="
$CAPTURE guide --surface lap --only tap_deck --taps 60 \
         --out "$OUT" --split "$SPLIT" \
         --notes "larger held-out lap deck so 98 % is expressible"

say "Done. Now grade it:"
echo "  ./analyse.sh --holdout"
