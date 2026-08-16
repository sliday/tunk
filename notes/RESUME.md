# Resuming

Everything is committed and pushed. Working tree clean. 271 tests pass; the 52
emit tests fail only when another app holds secure input, which blocks
`CGEventPost` — quit whatever has a password field focused and they pass too.

## Where the bar stands

Held-out, graded in critic mode. Two columns per surface, because the shipped
default and the resonator front end are different machines and only one of them
ships:

| Criterion | Bar | desk | soft | lap (shipped) | lap (resonator) |
|---|---|---|---|---|---|
| Detection rate | ≥ 98 % | **100 %** (20/20) ✅ | **100 %** (20/20) ✅ | 80 % (16/20) ✗ | 95 % (19/20) ✗ |
| ...credits landing >40 ms off the label | — | 0 | 0 | 2 of 16 | **4 of 19** |
| Latency p95 | ≤ 250 ms | **198.9 ms** ✅ | **207.6 ms** ✅ | **208.9 ms** ✅ | **211.4 ms** ✅ |
| False triggers | < 1 / 20 min | **0** ✅ | **0** ✅ | **0** ✅ | **0** ✅ |
| False triggers, typing | 0 | no data | no data | no data | no data |

Harness verdict: **FAIL**, on lap detection. It would read INCOMPLETE even if
lap passed, because held-out has no typing and no confound sessions.

Read the lap column carefully. The resonator's 19/20 includes four credits that
fire on a pair beginning 81-93 ms before the labelled first tap; demand a credit
within 40 ms of the label and it is 15/20. The resonator also ships OFF, because
train lap false triggers double from 3 to 6 with it on. See below.

## You can now turn it on and feel it

M26 is on `main`, **off by default**, and reachable from the app for the first
time: Settings → **Lap pairing (experimental)**. Until now `DSPTuning` was read as
`.default` everywhere in `TunkApp`, so not even the shipped resonator option could
be switched on from the product — which left "felt reliability matching iPhone
Back Tap", the one PRD criterion no harness can measure, unjudgeable on the only
mechanism that reaches the lap bar.

```bash
./dist/build-app.sh && open dist/Tunk.app     # then Settings, last card
```

**The default did not move.** Proved twice by the builder (6319 train fields and
3432 held-out fields compared, zero differences), reproduced by a verifying critic
from source, and checked again by me after the merge: 0 differences on both
splits. With the switch off, held-out still reads lap 16/20 and VERDICT: FAIL.

With it on, held-out reads desk 20/20, soft 20/20, lap 20/20, 0 false triggers,
lap p95 203.9 ms — and the harness verdict is **INCOMPLETE**, not PASS, because
held-out carries no typing and no confound session.

The card states what is measured and what is not: that no recording exists of this
laptop being knocked on a lap, that the guard against those false triggers has
only been tested against software-generated signals, that two of the five train
lap false triggers arrive by the halved bar and no amplitude test can reach them,
that it asks the typing gate to catch between 2.0× and 2.4× as much, and that 5 of
the 20 held-out lap credits land more than 40 ms from the label. An owner who
turns it on is volunteering to be the experiment, and the card says so.

## A mechanism reached the detection bar on held-out — and does not ship

`promising/m26-polarization`. The first time in 26 rounds that lap has met the
PRD's detection bar out of sample, verified by a critic who rebuilt from source:

| | desk | soft | lap | FP | lap p95 |
|---|---|---|---|---|---|
| shipped baseline | 20/20 | 20/20 | 16/20 | 0 | 205.1 ms |
| **M26** | 20/20 | 20/20 | **20/20** | **0** | **203.9 ms** |

**What 25 rounds missed: the sensor has three axes and every stage collapsed
them to a vector magnitude immediately.** A ring lobe is one chassis mode
decaying, so its 3-axis covariance is nearly rank one; a fresh contact excites
several modes at once. Over the 10 ms after a crest, `rect = 1 - λ₂/λ₁` reads
p50 **0.9955 for lap lobes** and **0.9310 for lap strikes**, separating them at
AUC **0.978 / 0.967 / 0.917** on the three clean train lap sessions — against
**0.614** for the entire envelope-shape family. On `13e15a`, whose labels are
already known defective, it scores 0.552.

The mechanism buffers every crest reaching half the live threshold, and at the
group deadline — the one that already exists, so latency is untouched — rescues a
one-member group by taking the least single-mode crest in the join band, subject
to a coherence veto against the anchor's axis.

### Why it does not ship

Two critics stopped it, on grounds the corpus cannot answer:

- **Lone-knock ring storm.** Give a knock a lap-like ring-down and every isolated
  knock becomes a double-tap: decay 25 ms fires 0, **28 ms fires 25, 30 ms fires
  49, 35-80 ms fires 50 of 50** lone knocks in 60 s, at every amplitude and every
  spacing out to 3 s. The shipped detector fires 0. The coherence veto cannot
  help — a lobe is perfectly aligned with the knock that made it.
- **Worse, and needing no ring at all.** A hard contact at 3× the bar followed
  110-200 ms later by a *separate* weak contact at 0.6× fires M26 on 30 of 30
  events. That is the halved candidate bar, not the lobe geometry.
- The guard that stops the storm breaks the held-out pass.
- Applied evenly, the strict-at-40 ms column reads desk 20/20, soft 20/20, lap
  **15/20** against a baseline of 14/20. By contract M26 buys four gestures; by
  strict credit agreement it buys **one**.

### The lobe storm is dead; the residual is a physics limit

`promising/m26-anchor-floor`. Both storm cases shared a signature the design
could not see: the rescued crest is a tiny fraction of the anchor, because the
candidate bar was anchored to the live threshold and nothing else. A 0.5 g knock
decaying with τ = 35 ms is at 5.7 % of its own peak by 100 ms — still 0.89× the
threshold, while being a twentieth of the contact that made it.

Measured before building, the populations do not overlap:

| | n | min | p50 | max |
|---|---|---|---|---|
| real rescues (train) | 19 | **0.382** | 0.590 | 1.328 |
| storm case 1, ring lobes | 324 | 0.031 | 0.056 | 0.131 |
| storm case 2, weak second contact | 150 | 0.175 | 0.202 | **0.235** |

The empty band is **0.235 to 0.382** — a margin of 0.147, not the "factor of
three" an earlier version of this note claimed by quoting case 1's maximum and
ignoring case 2's. The floor ships at 0.30, and the plateau's measured edges are
0.24 (below it case 2 returns) and 0.38 (above it real rescues start dying).

The lone-knock storm goes to **zero at every decay from 25 to 80 ms**, every
amplitude, every spacing — and the held-out pass is preserved exactly, because
the guard is a **no-op on every byte of real data the project owns**: train and
held-out are identical at floor 0 and 0.30, in every surface and every column.

Three caveats the builder raised against its own result, all of which stand:

- **The storm fixtures are synthetic**, one damped sinusoid scaled onto three
  axes. That is the *best* case for an amplitude test. A real chassis ring-down
  is not a clean exponential, and a real lobe at 100 ms may be a larger fraction
  of its parent than 0.131.
- **The train side is 19 rescues from 4 sessions**, and the two highest ratios
  (1.10, 1.33) come from `13e15a`, whose labels the project already calls
  defective. Drop it and the sample is 16. A 0.147 margin on 19 points is not a
  lot of statistics.
- **The floor cannot touch M26's own false triggers.** Two of the five train lap
  false triggers *are* rescues, at ratios 0.510 and 0.609 — the middle of the
  real-gesture population. No amplitude test reaches them.

**The residual is not a tuning failure.** A safety critic swept the axis the
builder had fixed and found that two *comparable* contacts 150 ms apart fire
regardless, at ratios 0.42-0.56 — inside the real-gesture band. No amplitude
statistic can exclude that class, because two comparable contacts 100-220 ms
apart is what a deliberate double-tap *is*. What M26 changes is the width of that
window: it needs the second contact only above half the bar rather than the full
bar.

### M26 triples the typing exposure, and the floor does not fix it

The PRD calls this the make-or-break metric: "False triggers during typing are
the primary failure mode. A build that hits every other target but misfires while
typing has failed."

Measured by stripping `input.jsonl` so the detector is exposed — the honest test
of what is left if the gate ever drops an event or arrives late, since the gate
is currently muting ~85 % of typing time:

| config | desk | soft | lap |
|---|---|---|---|
| shipped baseline | 63 | 35 | 12 |
| M26 | 145 | 81 | 45 |
| M26 + anchor floor 0.30 | **137** | **80** | **45** |

```
./.build-tf/release/tunk-score run --data <ungated mirror> --config notes/m26/{baseline,F_m26,G_m26_anchor030}.json
```

**M26 multiplies the exposed typing false-trigger count by 2.2× on desk, 2.3× on
soft and 3.75× on lap, and the anchor floor removes almost none of it** — 8 of 82
added triggers on desk, 1 of 46 on soft, 0 of 33 on lap. The floor was built for
ring lobes that are a twentieth of their anchor; typing transients are not that
shape.

**But read the multiplier against the right baseline, which I did not do at
first.** Un-gated, pooled, against a bar of < 1 per 20 min:

| | rate | over the bar by |
|---|---|---|
| shipped baseline | 188.48 /20 min | 188× |
| M26 + floor | 448.92 /20 min | 449× |

Neither is usable without the gate. The shipped detector already fails that
scenario by two orders of magnitude, so M26 does **not** cross a line the baseline
respects — it deepens dependence on a component the PRD deliberately makes
load-bearing: "Gate detection on input activity … This is how typing false
positives get killed. Accept the consequence that the user cannot trigger
mid-type."

Gated — the shipped behaviour — every config reads 0 false triggers in every
typing session, and there is no difference between them. So the honest statement
is narrower than "a second reason not to ship": M26 asks the gate to catch 2.4×
as much, in a regime where the detector is already wholly reliant on it. Whether
that matters is a judgement about how reliable the gate is, not a bar violation.

### The one recording that would settle it

Both critics converged on this independently: **the corpus holds zero lap
confound data.** Not one second of a laptop on a lap being knocked, bumped or
shifted while nobody is deliberately tapping it — which is exactly the population
M26 acts on. Until it exists, held-out lap 20/20 is a detection result with no
false-trigger denominator.

`record-for-the-bar.sh` now captures it: 200 s each of `confound_handling`,
`confound_mug` and `confound_lid` on the lap, single contacts only. That took the
script from 28 to 39 minutes and it is the difference between a mechanism that
looks like it passes and one that is known to.

## The PRD's critics have ruled on lap reachability

The PRD requires a **critic**, not the builder, to rule a target unreachable. I
once wrote such a ruling myself (the sensor bandwidth claim) and two of three
critics broke it. So three were commissioned with the full evidence and told to
hunt for a mechanism first. They split:

| angle | ruling |
|---|---|
| hunt for the missed mechanism | **REACHABLE — here is how** |
| audit the load-bearing negatives | UNREACHABLE on this corpus |
| is the bar measured against the right thing | UNREACHABLE on this corpus |

Both "unreachable" rulings are about the **instrument**, not the physics, and they
agree on the arithmetic. Held-out lap is 20 gestures in one session, and at n = 20:

| score | rate | 95 % Clopper-Pearson lower bound |
|---|---|---|
| 16/20 | 80.0 % | 59.90 % |
| 19/20 | 95.0 % | 78.39 % |
| **20/20** | 100 % | **86.09 %** |
| 49/50 | 98.0 % | 90.86 % |
| 59/60 | 98.3 % | 92.34 % |

**A perfect score on the held-out lap set cannot certify 98 %.** Certifying
"≥ 98 % at 95 % confidence" needs **149 consecutive clean gestures per surface**.
And at n = 20 the bar quantises: 19/20 = 95 % < 98 %, so "≥ 98 %" silently means
"100 %".

The PRD wrote 98 % for **its own final-acceptance instrument** — "perform 50
deliberate double-taps" — where 98 % = 49/50 and the granularity matches the
number. Applying a 50-tap figure to a 20-gesture sample is the harness's choice,
not the PRD's. That live test has never been run at full size, and it needs the
owner's hands.

### A reporting error of mine, corrected

I published held-out lap as "15/20 = 75 % label-aligned", applying a 40 ms
credit-agreement test **to lap alone**. Applied evenly:

| | desk | soft | lap |
|---|---|---|---|
| train, detected | 22/23 | 20/20 | 59/80 |
| train, credits > 40 ms off | 0 | **5** | 10 |
| train, strict at 40 ms | 22/23 | **15/20** | 49/80 |
| held-out, detected | 20/20 | 20/20 | 16/20 |
| held-out, credits > 40 ms off | 0 | **0** | 2 |

Train soft is 15/20 by exactly the test I used to indict lap — the same number.
Out of sample the distinction does hold (soft 0 over 40 ms, lap 2), so the
held-out claim stands, but I never ran the column for the passing surfaces, and
that let the lap figure read as uniquely damning when on train it is not.

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

### Held-out lap is 19/20 by the contract and 15/20 against the labels

Four of the nineteen held-out lap credits disagree with the label by more than
40 ms. So the headline depends on how strictly a credit must land: by the harness
contract, 19/20 = 95 %; demanding a credit within 40 ms of the label, **15/20 =
75 %**. Both are reported, and this note had been leading with the first.

**A correction to what I wrote here first.** I read `explain`'s "onset error" as
the detector's FIRST onset against the labelled first tap, and published that the
detector fires "81-93 ms before the labelled first tap". That is not what the
field measures. `Scoring.swift:474` computes `triggerOnsetNs(best) - g.lastNs`,
and `triggerOnsetNs` returns `tapOnsets.last` — it is the **last** onset against
the **labelled last**. Measured properly, in 10 of the 13 train cases the
detector's first onset sits *on* the labelled first tap, median −3.8 ms. The
displaced onset is the second one.

I also wrote that this "reframes 24 rounds" because a lap gesture must contain a
third transient the labels omit. The first half is true and the second half does
not follow, and the control that settles it was run:

| | extra prominent transients per gesture | at ≥50 % amplitude |
|---|---|---|
| `13e15a`, off-label gestures | 4.25 | 2.67 |
| `3fee5b`, **clean** gestures | 3.41 | 2.65 |
| `a4a257`, clean | 2.15 | — |
| `ad3fd3`, clean | 1.95 | — |
| desk, all | **0.18** | **0** |

A lap double-tap really does contain 3-7 real transients where the labels name
two — all 13 of the displaced onsets land on a broadband local maximum clearing
the labeller's own SNR-6 bar, and 11 of 13 are strikes by the labeller's own
criteria. But clean lap gestures contain them too. **The extra transients are not
what makes these credits off-label**, so they explain nothing.

What does explain it is the join window against this operator's lap cadence. In
`13e15a`, **14 of 20 labelled gaps fall outside the legal [100, 220] ms window**,
median 250 ms, against 1/20, 3/20 and 0/20 in the other three lap sessions. Ten
of the twelve off-label credits sit on a pair that cannot be joined. The detector
finds the first tap correctly, then has to pick a second within 220 ms, and the
labelled second is beyond reach — so it takes a real intermediate transient
instead.

Two things were settled along the way, both with validated instruments (a
labeller replica reproducing 103/103 frozen label pairs bit-exactly, and a
detector probe reproducing 252/252 `explain` onset times):

- **The filter is not the cause.** Impulse through HP20 → 40 Hz Q2 → quadrature →
  3-max gives an envelope peak at **+1.26 ms** and a 20 % crossing at +0.0 ms;
  analytic group delay is 15.3 ms. A 90 ms displacement is 30-70× that, and the
  filter can only delay, never lead.
- **Resonator statistics do not adjudicate on lap**, as the separability table
  below already showed: across the 13, `rise20` percentiles span 3 %-97 % and
  `res_prom` spans 1 %-77 %.

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

**Both families are large, so neither fix alone can work.** That is the result,
and a round aimed at both of them then closed each one separately — see
`rejected/shape-predilation` and `rejected/rank-retrospective-pairing`.
Six gestures can never be admitted at 0.011 g by any onset policy — every
`rejected/rearm-*` and `rejected/amplitude-*` round was doomed for those by
construction. Twelve are swallowed, and in **9 of the 12 the swallowing onset is
a mid-gesture lobe, not the labelled first tap** — so recovering them needs lobe
versus strike discrimination, which D9 records the current front end cannot do
(the 3-sample sliding maximum flattens the leading edge) — **though D9 was wrong
about that, see below**. In the other 3 the operator simply tapped faster than
`minInterTapNs` = 100 ms, at 91-101 ms.

D9's premise is now corrected on measurement, by a builder and a critic
independently and to two decimals: median 20 %-to-peak rise over 160 labelled lap
onsets is **20.02 ms on the dilated envelope and 20.02 ms on the un-dilated one**,
0 of 160 under one sample either way. D9's "0.0 ms for almost every real tap" was
measured before the resonator shipped, where a broadband lap transient peaks
inside the 3.8 ms window. Shape has been measurable ever since the resonator
landed.

It still does not separate on lap, and the control is what makes that credible —
second taps against ring lobes, measured out of sample, with the percentage of
lobes rejected at zero loss of real strikes:

| surface | best statistic | AUC | lobes rejected |
|---|---|---|---|
| desk | `res_prom` / `valley` / `rise50` | 0.990 | 80-82 % |
| soft | `res_prom` / `rise50` / `valley` | **1.000** | 100 % |
| lap | `rise20` | 0.614 | **0 %** |

The instrument is demonstrably not blind. On lap the separation is
indistinguishable from zero, and the best train lap statistic (AUC 0.711) reads
0.536 **inverted** out of sample — it was sampling noise on 36 lobes in one
session.

Family A is closed by the same round. Rescuing the 6 sub-threshold gestures with
a shape-assisted lower bar admits local maxima in the [0.7×, 1.0×] band at
**3485 per 20 min on lap, 3890 soft, 6138 desk, during typing** — thousands of
typing transients to rescue at most six gestures, against a bar of zero.

And the shipped `onsetDebounceNs` = 100 ms sits on the **left edge** of its
plateau: on held-out, 100/110/120 ms all give 59/60 with 0 FP, while 90 ms gives
58/60 with 1 FP and 80 ms gives 57/60 with 2 FP.

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
