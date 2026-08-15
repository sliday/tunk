# Resuming

Everything is committed and pushed. 311 tests pass. Working tree clean.

## Where the bar stands

Held-out, graded in critic mode, `strictDetectionRate` equal to the contract
rate on every surface (zero loose credits — see the referee audit below):

| Criterion | Bar | desk | soft | lap |
|---|---|---|---|---|
| Detection rate | ≥ 98 % | **100 %** (20/20) ✅ | **100 %** (20/20) ✅ | 80 % (16/20) ✗ |
| ...of which credits landing on a different transient | — | 0 | 0 | **2 of 16** |
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
chassis into the data. Ctrl-C flushes the current session, writes it valid, and
stops the script — capture exits 130 and `set -e` halts the run.

An audit of the capture path ran before this script was trusted with 28 minutes,
and it would not have worked. Four defects, all fixed and covered:

- **`say` blocked forever.** `/usr/bin/say` and `afplay` hang on this machine
  (virtual audio drivers). `doctor --seconds 3` ran until the 2-minute timeout;
  it now returns in 11.4 s, because speech is bounded at 8 s and gives up once.
- **The beep mark was stamped before the beep.** Beeps stalled about 16 s, so
  ground truth sat 16 s ahead of anything the operator heard, every gesture fell
  outside the labeller's 2600 ms window, and `tunk-label` would have written 60
  prompt-window labels at moments when nothing happened. The beep now precedes
  the mark and reports its own start latency; over 250 ms prints a stop-and-fix.
- **Ctrl-C exited 0**, so the shell walked into the next phase and recorded an
  empty room as the next surface. Measured, not hypothesised: 22 s into phase A.
- **An inert confound session was credited as evidence.** See below.

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

## Why lap is stuck — now measured, and it is not the detector

Every one of the 20 held-out lap gestures lives in a single session. Split them
by whether the LABEL puts the two taps inside the detector's 220 ms pairing
ceiling:

| | groups | detected | onset agreement with the label |
|---|---|---|---|
| label span ≤ 220 ms | 15 | **15 — every one** | median ~5 ms |
| label span > 220 ms | 5 | 4, all loosely | 41-61 ms |

**The detector strictly detects 100 % of the lap gestures it is permitted to
fire on, to about 5 ms.** The single miss and all four loose credits are exactly
the five gestures whose labels pair onsets 223-249 ms apart, beyond the ceiling.

The obvious fix does not work, and this is the important negative: raising the
ceiling to 260 ms changes nothing. Those four still disagree by 41-61 ms and the
miss stays missed. So it was never a window problem. On a lap one strike makes
4-7 lobes over 250-300 ms (D9), the labeller picked lobes A and D, the detector
picked A and B, and both are looking at the same real gesture. The remaining
miss is a second tap the front end never saw at all.

Widening the window is now measured shut properly, which it had not been. A
sweep of `maxInterTapMs` alone clamps at `confirmWindowNs` and returns identical
rows — the harness says so in its own output, but a conclusion had been drawn
from that flat tail anyway. Sweeping BOTH windows: train lap gains 2 gestures at
240 ms then saturates; held-out gains **zero** at every value from 230 to 300 ms.
A critic also found the plateau starts at 220, where the config already sits, and
that 220 is 10 ms above a 5-point cliff.

The deafness route is exhausted. `rejected/rearm-valley-rise` cured the deafness
(lap deaf 12 → 2) and recovered ZERO gestures; four separate "lower the bar for
the second tap" variants were rejected in round 1; D9 records that a lower bar
takes soft from 100 % to 55 %, because it admits the second lobe.

So the honest position: **held-out lap is 19/20, and at n = 20 the 98 % bar
requires 20/20.** One gesture is five points. The 60-gesture lap deck in
`record-for-the-bar.sh` is what makes the bar expressible at all.

## The referee now names labels it cannot be satisfied by

A labelled gesture whose own onsets sit further apart than `maxInterTapNs` is one
no detector may fire on. It is a guaranteed miss, and any trigger the detector
does produce inside the real gesture is charged as a false trigger on top — one
physical event, two penalties, neither earned. Every run now says so:

```
!! tap_deck__lap__...: group 1 pairs onsets 597 ms apart, beyond the 220 ms
   maxInterTap ceiling. No detector may fire on this pairing...
```

Counted: **17 of 80 train lap, 5 of 20 held-out lap, 1 desk, 0 soft.** This
changes no label and no verdict. It states arithmetic that was previously
invisible and read as a detector defect.

Twenty-one mechanisms have been built and independently graded, each by a critic
with fresh context who rebuilt from source and graded on data the builder could
not see. None reached the bar on lap. The latency-budget escape is measured shut
(the join window saturates at 280 ms and 77.5 %), and so is the sensor-bandwidth
escape.

## One confound session in `data/raw` is a recording of nothing

`confound_music__desk__20260813-213400__93cb8f` is quieter than an empty room.
Peak sample-to-sample step at p99.9, in g:

| session | p99.9 |
|---|---|
| `confound_music ...93cb8f` | **0.0007** |
| `idle ...7da427` | 0.0014 |
| `idle ...75bdf7` | 0.0026 |
| `confound_music ...84bfc0` | 0.0076 |

It ran its 0.6 minutes and bought a green "0 false triggers in 2 confound
sessions". The harness now measures that number on the raw samples — a first
difference, so it cannot depend on any threshold the detector is graded on — and
drops any confound session below 0.004 g from the count, naming it in the text.
The desk check reads `0 in 1 session(s), 0.6 min — 1 inert session(s) excluded`.
All-inert reads `no usable confound sessions`, not a pass.

This is the second time the same hole was patched. First it was empty
directories, closed with a minimum duration; a full-length recording of silence
walked straight through that. `Tests/TunkScoreTests/InertConfoundTests.swift`
holds both cases, and the scorer now has a test target at all — `TunkScoreTests`
was never declared in `Package.swift`.

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

## Rebuild the app bundle before trusting anything it measures

```bash
./dist/build-app.sh     # now refuses to finish if the bundle ends up stale
```

`dist/Tunk.app` was found four hours behind its sources — missing the
ring-to-strike calibration measure and both fixes to the acceptance test. Running
fifty prompted taps against that bundle would have measured yesterday's detector
while looking exactly like a fresh result. The build script now makes the same
assertion `bin/refresh.sh` makes about the CLI binaries, and fails loudly rather
than printing "built:" over a binary that did not change.

## The live acceptance test works

`./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300` is the PRD's live
driving test and had never been executed. Running it with a tiny count settles
that it works end to end — it prompts, counts, grades against the bar, exits
non-zero on failure, and deliberately does not post the bound action.

Running it also found two defects that only appear when you run it: a short
rehearsal announced "Type normally for 0 minutes", and the countdown printed
"-7 s left". Both fixed. Worth knowing before spending fifty taps on it.

## Still open, and small

- ~~`--collect-taps` onset-to-snippet path never exercised.~~ **Closed.** It was
  never a data problem: the detector makes real onsets from synthetic samples,
  and the file simply lived in an executable target no test can import. Moved to
  `TunkFormat`, covered by `PassiveCaptureEndToEndTests`. What still needs a real
  tap is whether ordinary use produces onsets worth collecting, which is a claim
  about the world rather than about the code.
- **The site's call to action** points at a private repo and 404s.
- **The motion gate** ships disabled. Re-measured at the resonator operating
  point it removes one lap false trigger of six at no detection cost, across a
  wide plateau — but that is one event, in the one lap session whose ground truth
  is known to be defective. It needs the `confound_handling` recordings that
  `record-for-the-bar.sh` now captures.
- **Every mechanism ever built is a tag.** `git tag -l 'rejected/*' 'shipped/*'`
  lists them with their verdicts in the tag messages; `git show` any of them for
  the measured outcome, `git diff main...<tag>` for the code. The worktrees they
  were built in are gone; the commits are not.
- **Per-surface calibration profiles** would help (lap tops at 82.5 % at its own
  best) but the surface is not detectable, so any switching must be deliberate.

## The decision that is not mine

Desk and soft meet the PRD bar. Lap does not, and the reason is the sensor.
Either ship lap as best-effort with the measured number stated, or mark it
unsupported. Both are honest; neither is an engineering question.
