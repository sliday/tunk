# Resuming

Everything is committed and pushed. 306 tests pass. Working tree clean.

## Where the bar stands

Held-out, graded in critic mode, `strictDetectionRate` equal to the contract
rate on every surface (zero loose credits — see the referee audit below):

| Criterion | Bar | desk | soft | lap |
|---|---|---|---|---|
| Detection rate | ≥ 98 % | **100 %** (20/20) ✅ | **100 %** (20/20) ✅ | 80 % (16/20) ✗ |
| Latency p95 | ≤ 250 ms | **198.9 ms** ✅ | **207.6 ms** ✅ | **208.9 ms** ✅ |
| False triggers | < 1 / 20 min | **0** ✅ | **0** ✅ | **0** ✅ |
| False triggers, typing | 0 | no data | no data | no data |

Harness verdict: **FAIL**, on lap detection. It would read INCOMPLETE even if
lap passed, because held-out has no typing sessions.

## The recordings that are still missing — one command

Nothing here is fixable in code, and all of it blocks the bar.

```bash
cd /Users/stas/Playground/tunk
./bin/record-for-the-bar.sh --dry-run     # see the plan, record nothing
./bin/record-for-the-bar.sh               # about 28 minutes
```

Headphones on: the tool speaks and beeps, and through speakers both shake the
chassis into the data. Ctrl-C at any point flushes the stream and writes a valid
session, so stopping early costs only what has not been recorded yet.

It records three things:

1. **Typing, all three surfaces, held out.** Eight checks currently read
   `[ ---- ] no typing sessions` / `no confound sessions`, which is why the
   harness returns INCOMPLETE rather than a verdict. Detection is measured out
   of sample; the make-or-break metric never has been.
2. **`confound_handling` and `confound_music`, all three surfaces.** Handling has
   never been recorded on any surface and it is the one that prices the lap
   false-trigger question — four of the six lap false triggers look like the
   machine being shifted rather than tapped, and the corpus holds zero seconds
   of a laptop on a lap while nobody is tapping it.
3. **A sixty-gesture held-out lap deck.** At twenty, 98 % can only be met by
   20/20, so one gesture is five points.

Every command in that script is re-run with `--dry-run` by
`CaptureCLITests.testEveryCommandInTheBarScriptRuns`, because a plan of mine
once carried flags the CLI silently swallowed and cost an hour of recording.

Worth adding, because posture is a measured hidden variable — one lap session
scores below chance on three separate statistics while the others score
0.87–1.00, and the operator reports resting a hand on the chassis in some:

```bash
./bin/tunk-capture guide --surface lap --only tap_deck --taps 40 --notes hand-on-chassis
./bin/tunk-capture guide --surface lap --only tap_deck --taps 40 --notes hand-off
```

Then:

```bash
./analyse.sh              # grades data/raw end to end
./analyse.sh --holdout    # the numbers that decide pass or fail
```

## Why lap is stuck, in one paragraph

The sensor is band-limited near 50 Hz. It reports at 796 Hz — a hard cap, and
`ReportInterval` does not move the bandwidth — but carries nothing above about
50 Hz, with power in 100–398 Hz sitting nine to ten orders down at numerical
noise. A knuckle strike on aluminium is broadband to several kHz, so the content
that would distinguish a strike from the chassis ringing afterwards never reaches
the file. On a lap the second strike and the first strike's ring are therefore
the same size in the envelope. `notes/BAR_ASSESSMENT.md` has the full ledger.

Twenty mechanisms have been built and independently graded, each by a critic
with fresh context who rebuilt from source and graded on data the builder could
not see. None reached the bar on lap. The latency-budget escape is measured shut
(the join window saturates at 280 ms and 77.5 %), and so is the sensor-bandwidth
escape.

## The referee has been audited

Three auditors attacked the scorer; a skeptic reproduced the worst finding.
Held-out came out clean. Fixed in the process:

- Matching tested only the trigger's LAST onset against the label's last, so a
  first-strike-plus-ring-lobe pair could be credited. `strictDetectionRate` now
  reports beside the contract rate. Held-out 0 loose credits; train 7.
- The typing check now reports its real exposure: `0 in 3 session(s), 11.7 min
  (1.6 min un-gated)`. The zero is real — strip `input.jsonl` and the same
  detector fires 110 times — but 86 % of typing time is gated.
- `must-not-fire` judged all triggers in the window rather than unclaimed ones.

## Still open, and small

- **`--collect-taps`** is wired and receives every sample; the onset-to-snippet
  path has never fired because it needs a real tap. One tap settles it.
- **The site's call to action** points at a private repo and 404s.
- **The motion gate** ships disabled. It needs `confound_handling` recordings.
- **Per-surface calibration profiles** would help (lap tops at 82.5 % at its own
  best) but the surface is not detectable, so any switching must be deliberate.

## The decision that is not mine

Desk and soft meet the PRD bar. Lap does not, and the reason is the sensor.
Either ship lap as best-effort with the measured number stated, or mark it
unsupported. Both are honest; neither is an engineering question.
