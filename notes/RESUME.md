# Resuming

Everything is committed and pushed. 290 tests pass. Working tree clean.

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

## The two recordings that are still missing

Neither is fixable in code. Both block the bar.

```bash
cd /Users/stas/Playground/tunk

# 1. The make-or-break metric, out of sample. It has NEVER been graded on
#    held-out data. ~5 min each. Headphones on — the tool speaks and beeps.
./bin/tunk-capture guide --surface desk --only typing --typing-sec 300 --out data/holdout --split test
./bin/tunk-capture guide --surface soft --only typing --typing-sec 300 --out data/holdout --split test
./bin/tunk-capture guide --surface lap  --only typing --typing-sec 300 --out data/holdout --split test

# 2. A larger held-out lap deck. At n=20, 98 % can only be met by 20/20 and one
#    gesture is five points, so the set cannot tell a real fix from luck.
./bin/tunk-capture guide --surface lap --only tap_deck --taps 60 --out data/holdout --split test
```

Worth adding, because posture is a measured hidden variable — one lap session
scores below chance on three separate statistics while the others score
0.87–1.00, and the operator reports resting a hand on the chassis in some:

```bash
./bin/tunk-capture guide --surface lap --only tap_deck --taps 40 --note hand-on-chassis
./bin/tunk-capture guide --surface lap --only tap_deck --taps 40 --note hand-off
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

Fourteen mechanisms have been built and independently graded, each by a critic
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
