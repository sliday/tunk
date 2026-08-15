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

## Why lap is stuck — the answer is a re-arm defect

**A claim published here an hour ago was wrong and is withdrawn.** It said the
detector already detects every gesture it is permitted to fire on, and that the
remaining lap gap is therefore in the corpus rather than the code. Three
skeptics were commissioned to destroy it. Two returned REFUTED and the third
found the actual defect. What follows replaces it.

The withdrawn claim rested on splitting labelled groups at the detector's own
220 ms pairing ceiling. Move the ceiling and the split moves with it — that is
the circularity, and it is fatal:

| ceiling | 180 | 200 | **220** | 240 | 260 | 620 |
|---|---|---|---|---|---|---|
| lap "fireable" credited | 86.4 % | 96.8 % | **100 %** | 98.5 % | 98.6 % | 92.5 % |

100 % happens at exactly 220 ms and nowhere else. And with the ceiling opened to
620 ms, so that nothing at all is excluded, lap still tops out at 92.50 % train
and 95.00 % held-out. **Lap never reaches 98 % at any ceiling**, so the gap was
never explained by the labels alone. Three more corrections to that entry: the
result held only at the resonator point (on the shipped default, 13 of 63
fireable train lap gestures are missed); "63 lap fireable" should have been 62,
since one group spans 91.3 ms and is unfireable by `minInterTapNs` instead; and
it ignored that lap also fails false triggers at that operating point.

### What is actually wrong

Held-out `959d90` group 6, the only held-out lap miss, is neither a quiet tap nor
a labelling disagreement:

- the labelled first tap peaks at 0.87× threshold, so it is never declared
- the detector crosses instead on a 1.03× precursor 140 ms later
- the real strike lands 105 ms after that at **1.38× threshold — the largest
  transient in the gesture, and 1.34× the onset that blanked it**
- it is refused purely by **release hysteresis**: the valley between them bottomed
  at 0.00506 g against a 0.00440 g re-arm level

The detector heard a dominant strike and discarded it. `explain` reports this as
"only 1 ungated onset ... a 2-tap needs 2", which reads like deafness, and that
mis-reading is why the entire amplitude family looked closed.

It has an in-sample counterpart, exactly one: train `13e15a` group 1, a peak at
1.52× threshold and 1.28× the onset that blanked it, 115 ms later. The harness
already says so — `explain` calls it "above threshold but rejected by the
detector's own logic". It sits inside a 597 ms label, so recovering it cannot be
credited, **which is precisely why `rejected/rearm-valley-rise` measured
"recovers ZERO gestures"**. That old negative was real and its interpretation was
wrong.

### The fix for it was built, and it is `rejected/rearm-dominant-transient`

The argument was that a ring lobe is always weaker than its own strike, so a
transient *stronger* than the one holding the arm state cannot be that strike's
decay and must be a new contact. Built, and rejected by both critics.

The builder found the flaw in the diagnosis above. That "1.34× / 1.28× stronger
than the onset that blanked it" was measured against the blanking onset's
**crossing sample**, not its peak. Against the peak the candidate reads **0.889×**
— it is a lobe after all. A crossing sample records where the threshold sits, not
how hard the chassis was hit, so the premise never licensed the recovery. Both
references were then graded rather than argued:

| held-out, peak reference | desk | soft | lap | p95 | g6 |
|---|---|---|---|---|---|
| 0 (shipped) | 20/20 | 20/20 | **19/20** | 211.4 ms | missed |
| 1.0 | 16/20 | 20/20 | 15/20 | 236.4 ms | loose credit |
| 1.3 | 20/20 | 20/20 | 19/20 | 236.4 ms | loose credit |
| 1.4 | 20/20 | 20/20 | 19/20 | 211.4 ms | inert |

Where g6 flips it is a credit on the wrong physical transient and p95 rises 25 ms
for nothing. The crossing reference is catastrophic out of sample — desk 1/20.
On train at the only setting that recovers the named transient, each admitted
onset turns a 2-tap group into an un-armed 3-tap group: desk 22 → 14, soft
20 → 18, lap 73 → 67. The safety critic then built a real false trigger out of it,
on an idle desk session, from a single rising disturbance.

And the instance was never rare. At margin 1.0 the peak reference admits **88**
supra-threshold dominant transients across `data/raw`, 58 of them in one desk
session, against the 1 the diagnosis named.

### The lap gap, finally decomposed

Twenty-three rounds argued about lap without ever separating its failure modes.
A measurement agent did it, using a Swift probe that streams samples through the
**real** `TapDetector` and records its own envelope and active threshold per
sample — validated by reconstructing all 166 published onset strengths
bit-exactly, so no chain-replica or gain-mixing error is possible.

For every one of the 80 labelled train lap gestures, two numbers: the peak
envelope at the labelled second onset as a multiple of the live threshold, and
the offset from that onset to the nearest onset the detector had already
declared, against `onsetDebounceNs` = 100 ms.

| | A: sub-threshold | B: swallowed by debounce | both | neither |
|---|---|---|---|---|
| all 80 gestures | 3 | 9 | 3 | 65 |
| the 20 failures | 3 | 9 | 3 | 5 |

**All 60 clean gestures are NEITHER**, minimum ratio 1.05 and minimum offset
125 ms. The separation is total, which is what makes the split trustworthy.

**Both families are large, so neither fix alone can work.** That is the result.
Six gestures can never be admitted at 0.011 g by any onset policy — every
`rejected/rearm-*` and `rejected/amplitude-*` round was doomed for those by
construction. Twelve are swallowed, and in **9 of the 12 the swallowing onset is
a mid-gesture lobe, not the labelled first tap** — so recovering them needs lobe
versus strike discrimination, which D9 records the current front end cannot do
(the 3-sample sliding maximum flattens the leading edge). In the other 3 the
operator simply tapped faster than `minInterTapNs` = 100 ms, at 91-101 ms.

Two details worth acting on:

- `ad3fd3` g5 is a failure **by 1.5 ms**: labelled inter-tap 221.5 ms against a
  220 ms ceiling, with both taps loud (1.91×) and both detected.
- `13e15a` g12 was disarmed 151 ms after the previous onset, so the debounce had
  already expired and the **release-fraction latch** held it. The re-arm blocker
  is not only the 100 ms constant.

And the corpus warning again, now from a fourth direction: `13e15a` has
**14 of 20 labelled inter-tap intervals outside the legal [100, 220] ms band**,
and 16 of the 20 lap failures live in that one session.

### The PRD's two bars are in tension on lap, and that part stands

Latency tracks the confirm window 1:1 (p95 = window + 6.5 ms), because a group
fires at a deadline: `Detector.swift:490`, `groupDeadlineNs = tNs +
confirmWindowNs`. A 250 ms p95 bar therefore caps the window near 243 ms, and any
gesture whose two taps sit further apart than that cannot be both fired on and
inside budget. Labelled spans above 243 ms: **13 of 80 train lap, 1 of 20
held-out lap, 1 of 23 train desk.**

So 98 % detection and 250 ms p95 are jointly unsatisfiable on lap as labelled.
That is a consequence of firing at a deadline rather than of physics — firing as
soon as the armed tap count is reached would decouple the two, and triple-tap is
built but unwired (D6), so nothing currently needs the wait.

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
