# Resuming

## Do this first

Everything that can be measured without your hands has been. Two bars need you.

```bash
# 0. the machine must be unlocked, nothing holding secure input
ioreg -l -w 0 | grep kCGSSessionSecureInputPID          # must print NOTHING

# 1. ten minutes, on your lap. Grades detection at 49/50 and typing false
#    triggers live, AND leaves a held-out typing session + labelled lap deck.
./dist/build-app.sh
./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300 \
    --record data/holdout --surface lap --tap-category tap_deck

# 2. label what it recorded, then grade
./bin/tunk-label run data/holdout/<the two new sessions>
./bin/tunk-score run --data data/holdout --i-am-a-critic
```

Do it twice more with `--surface desk` and `--surface soft` for the per-surface
bar. Then, if you want the confound evidence too, `./bin/record-for-the-bar.sh`
(39 min) — it is the only source of the lap-confound recording that prices the
experimental mechanism.

**Want to feel it rather than grade it?** Settings → Lap pairing (experimental).
Off by default. It reaches lap 20/20 on held-out where the default reaches 16/20,
and the card lists every risk that has not been measured.

**One decision is yours and only yours:** `notes/DECISIONS.md`, D-LABELS. Four
independent lines of evidence say the lap labels in one session are wrong. I am
not the one who gets to rewrite the ground truth I am graded against.

---


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

### CORRECTION: the synthetic fixtures under-stated real lap by 14x

**The section below is wrong where it claims margin, and is kept for the record.**
Everything in it was measured on synthetic fixtures — one damped sinusoid on three
axes — and its own builder warned that "a real lobe at 100 ms may be a larger
fraction of its parent than 0.131".

Measured since, on `data/raw`, driving the real detector and validated by
reproducing all 242 published onset pairs exactly. The ratio of the envelope
100-220 ms after a real **isolated** strike to that strike's own peak — the exact
quantity the 0.30 floor tests:

| surface | n | p50 | at or above 0.30 |
|---|---|---|---|
| desk | 24 | 0.153 | 0 of 24 |
| soft | 20 | 0.363 | 13 of 20 |
| **lap** | 83 | **0.488** | **81 of 83** |

Synthetic storm lobes sat at 0.031-0.131. **Real lap sits 14× higher.** Restricted
to crests that also clear the candidate bar: lap p50 0.437, 49 of 83 above the
floor.

Ring-down time constants, same method: **desk 28 ms, soft 105 ms, lap 231 ms**,
against a storm knee at 25-28 ms. The storm regime is not merely reachable on a
lap — it is what a lap is.

Raising the floor cannot rescue it: real lap second taps have a p25 of 0.43, so
any floor that closes the storm sits inside the genuine population.

The polarization pair was the only defence left. **It does not hold**, measured
on `data/raw` with a probe validated three ways — 242/242 published onset pairs
reproduced, the envelope matching the detector bit for bit across 2.55 M samples,
and a Python transcription of `PairRescue.scan` reproducing all 19 real rescues
exactly.

| gate | on real lap data |
|---|---|
| 3, anchor floor 0.30 | does not filter: 81 of 83 strikes clear it |
| 5, coherence veto (cos ≥ 0.7) | **admits 74.5 %** of lobes (35 of 47) |
| 5, empirically | rejected **0 of 19** real lap singletons |
| 6, rect ranking | ranks only — never rejects the last survivor |

34 of 55 isolated lap strikes have a crest passing gates 1-4. Their `|cos|` runs
p50 0.841 against real rescues at p50 0.859 — not separable, P(lobe > rescue)
= 0.369. And singleton groups, the only ones M26 scans, form at **3.86 per minute**
during real lap tapping.

The veto's direction was the trap: it *requires* alignment in order to reject
unrelated disturbances, and a ring lobe is maximally aligned with the strike that
produced it. It was built to admit exactly the thing that hurts it.

**That verdict was too strong, and the next round corrected it.** The 28 "hazard"
anchors it rested on are, 26 of them, the *second tap of a deliberate double-tap*
— they never form the one-member group M26 scans. Only 3 ever do. Measured on the
harness rather than inferred: **M26 costs 2 extra false triggers in 9.2 minutes of
lap tapping** (3 → 5). The lone-knock rate is not measured at all, because the
corpus holds exactly **two** knocks with no deliberate tap on either side.

So the honest position is narrower: the mechanism is *unpriced* on lap rather than
demonstrably dangerous, and three separate guards have now failed to close it.

**That lead was graded and rejected** — `rejected/rect-ceiling`. Rect really does
separate lobes (p50 0.995) from real rescues (p50 0.895), and that measurement
stands. But the 24-of-28 figure was counterfactual: only 3 of those anchors ever
form a scannable group, at 0.99 exactly one stops firing, and the harness scores
it as a *detection*. Lap false triggers read 5 at rectMax 1.1 and 5 at 0.99.

And it points the wrong way on the only real examples. Both lap false triggers
M26 adds are rescues at crest rect **0.975 and 0.410**; the two genuinely isolated
knocks read **0.936 and 0.410**. All four sit *below* the ceiling that stops the
lobes. A ring lobe of a deliberate strike is a textbook rank-one decay; the knocks
that actually fool this detector are not. The ceiling filters the population that
is not firing and misses the one that is — the same failure as the coherence veto,
reached from the opposite side.

One real gain, kept on record: the ceiling removes **37 %** of M26's added
un-gated typing exposure (262 → 205 pooled). Gated, every config reads 0.

### The lobe storm is dead on synthetic fixtures; the residual is a physics limit

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

## A band I proposed myself, and it was a fit

Off the back of the note above I proposed a band that would trade the three loose
credits for both false triggers. **The arithmetic I proposed it with was wrong.**

A band does not delete a rescue — it filters *candidates*, and the ranker then
promotes the next crest from the buffer, so the rescue survives with a different
crest. `pairRescueRectMin` 0.50 with the ceiling open leaves **all 19 rescues
intact** and lap FP at 5. Both my reasoning and `rejected/rect-band`'s worked from
the winning crest's rect alone, which does not hold once a replacement exists.

There is a real window underneath: floor 0.8535-0.8685 with ceiling 0.9740 gives
train lap 72 contract / 65 strict at FP 3, against the shipped 59 at FP 3 — 13
more detections at equal false triggers, in a window **0.015 wide**. A critic
swept both axes on held-out:

| floor | held-out lap | train lap FP |
|---|---|---|
| 0.00 – 0.810 | **20/20** | 4-5 |
| **0.8535 – 0.8685** | 19/20 | **3** ← train optimum |
| 0.88 – 0.90 | 18/20 | — |
| 0.9749+ | 16/20 | — |

The train optimum sits exactly where held-out has already lost a gesture. It buys
a train false-trigger reduction by paying a held-out detection. Confirmed fit.
`rejected/rect-band-strict`.

Two things from the builder's own critique are worth more than the result.

**The falsifier fired, and it reported it.** The brief said the trade is only
defensible if the strict rate holds, since the discarded credits are loose. Strict
lap moves 66 → 65 — not because a discarded credit was strict, but because the
band **silently substitutes the crest under three *surviving* rescues** (0.7873 →
0.9504, 0.8393 → 0.9664, 0.7949 → 0.9720) and one of those pushes a credit past
the 80 ms line. In its words: "true about what is discarded and false about the
consequence. By the brief's own rule that makes the argument wrong, and I am
saying so."

**The overfit is subtler than the sorted list can show.** The crest the floor
excludes at 0.8531 *is not one of the 19*. It is the substitute that becomes the
winner only because the floor already removed the 0.4104 reading. **The boundary
is fitted against a value the boundary itself created.** The floor's working edge
is 0.0005 wide; the ceiling plateau is 0.0026 wide, decided by two readings 0.0029
apart out of nineteen.

For the record, the three-way at equal false triggers — the number that made this
worth testing, and which does not survive held-out:

| config | lap contract | lap strict | lap FP |
|---|---|---|---|
| shipped default | 59 | 53 | 3 |
| M26 | 76 | 66 | 5 |
| M26 + band | 72 | 65 | **3** |

### The point that outlives this round

**Held-out cannot grade false triggers at all.** Held-out lap is 1.5 minutes with
zero typing and zero confound sessions. Train lap runs 3 false triggers in 9.2
minutes — 6.5 per 20 min — so over 1.5 minutes the expected count is about 0.5.
"0 held-out lap false triggers" is consistent with *exactly the train rate*. It is
not evidence of zero; it is evidence of insufficient exposure, and every
false-trigger claim made against that split in this project inherits the limit.

## The rect axis is closed in both directions

`rejected/rect-ceiling` closed the ceiling. M26's two train lap false triggers sit
at crest rect **0.9749 and 0.4104** — top and bottom of the range — with its 17
credits centred at 0.895, so a *band* was the obvious untried shape. If one
existed, M26's train lap false triggers would drop 5 → 3, equal to the shipped
default.

Measured from the rescue trace, 19/19 joined to the report JSON and cross-checked
against `explain`. **The credits straddle both false triggers:**

| | rect | |
|---|---|---|
| low blocker | **0.1369** | credited (`3fee5b` 71.084 s) |
| | 0.4104 | **false trigger** |
| 15 credits | 0.787 – 0.972 | credited |
| | 0.9749 | **false trigger** |
| high blockers | **0.9976, 0.9981** | credited |

Any floor above 0.4104 kills the 0.1369 credit; any ceiling below 0.9749 kills
both top credits. Not a fitting problem — an interleaving one, with no line to
draw.

Worth recording for whoever revisits it: all three blocking credits are **loose**,
89-135 ms from their labels. Under a stricter crediting rule they would move and a
band might open. Under the harness's own rule it does not. `rejected/rect-band`.

## The gesture does not inflate its own bar — measured, not assumed

The noise tracker's four parameters had never been exposed to config, so they had
never been swept. The hypothesis was specific: a lap ring-down runs 231 ms, the
floor is frozen only 30 ms after an onset, so the first tap's own ring should push
the bar up exactly while the second tap arrives.

**Measured first, and it died there.** Probe validated by reproducing all 242
published onset pairs from `explain`, 0 mismatches. Median across lap gestures,
from each gesture's own first onset:

| | floor | 4 × floor | effective threshold |
|---|---|---|---|
| 0 ms | 0.00164 | 0.00655 | **0.03200** |
| 220 ms | 0.00369 | 0.01478 | **0.03200** |

The floor climbs. It cannot reach the bar: `currentThreshold()` is a `max()` and
the configured 0.032 g dominates 4 × floor by more than double everywhere it
matters. Rise through the 100-220 ms window is **median +0.00 % on all three
surfaces**, with 3 of 79 lap gestures over 1 % and all three in `13e15a`.

**Where it applies at all, the hypothesis is backwards.** In those three,
freezing the floor *removed* onsets rather than adding them — the re-arm
condition is `envelope <= threshold × releaseFraction`, so a higher bar means a
higher release level means the detector re-arms *sooner*. The adaptive floor's
only measurable effect near a gesture is on hysteresis, not admission.

The sweep confirms it through the graded scorer rather than the probe alone:
across `noiseFloorHoldMs` 30→430, `noiseRiseTauSeconds` 1.8→8 and
`noiseSnrMultiple` 1→3, lap detection stays at **59/80 exactly** and pooled at
101/123 — the shipped value, every row.

`rejected/noise-floor-hold`. The four parameters are now sweepable, which they
were not before.

### What it did establish: family A, named and sized

The same probe measured every lap gesture whose labelled second tap peaks under
the bar. **On train that is 13 gestures, 12 of them among the 21 missed** — not
the 6 quoted earlier from the held-out failures. The builder flags the difference
itself: its window is peak envelope within ±40 ms of the label, looser than
whatever produced the 6. The definitions differ; the conclusion does not.

Their ratio to the 0.032 g bar, every one failing a threshold that rose
**0.00000 g** between the first onset and the second tap:

| ratio | gestures |
|---|---|
| 0.682 | `3fee5b` g18 |
| 0.845 | `3fee5b` g14, g15 |
| 0.866-0.935 | `ad3fd3` g1, `a4a257` g6, g2, g3, g14 |
| 0.958-0.982 | `ad3fd3` g9, `a4a257` g4, `13e15a` g19, `3fee5b` g17, `ad3fd3` g8 |

**Eight of the thirteen are within 8.5 % of the bar.** That is tantalising and it
is exactly the trap: closing 8.5 % of amplitude is what nine rejected variants
tried, and a lobe sits in the same band. Desk 0/23 and soft 0/20 have no
sub-threshold second taps at all — this is a lap phenomenon entirely.

## The amplitude axis is closed, with the last variant graded

A critic had handed over a "strict improvement" that nobody built:
`currentThreshold()` lowers the bar for the second onset while a gesture is in
flight, and the *same value* feeds the re-arm test — so the release line falls
with it, making admission easier and re-arming harder at once.

**The coupling was real and the decoupling fixes it.** Matched-pair miss-set diff
at fraction 0.92: the coupled arm reproduces D9's failure exactly, losing
`soft-fe9b8c` g3 and g19 — `rejected/amplitude-proportional-bar`'s signature. The
decoupled arm holds soft at 20/20 across the whole band.

**The critic's claim was still wrong.** At its named 0.85, soft is 19/20 and lap
false triggers go 3 → 4; both guards fail. The best train point (0.91) reaches lap
65/80, +6 over baseline, with desk and soft intact — but lap FP 3 → 5.

Held-out, graded fresh: desk 20/20, soft 20/20, **lap 17/20**, 0 FP, p95 208.9 ms.
One gesture recovered against a bar needing 20/20. And the deciding observation:
*the decoupling differs from the rejected variant on train and not at all on
held-out* — held-out soft does not degrade under the coupled arm either, so the
thing this mechanism fixes is invisible where it counts.

**Two corrections to how I framed this round.** My brief called it "the central
suspect on lap". It is not: the decoupled and coupled arms recover an *identical*
set of six lap gestures and lose the same one, and the only difference is that the
coupled arm destroys two soft gestures. It is a pure soft-side repair. And the one
case I aimed it at — `13e15a` g12, held by the release latch after the debounce
expired — is **not recovered**; `explain` still reads "only 1 ungated onset".

The builder also declined to defend its own headline: the lap gain from 59 to 65
comes from the amplitude reduction, which *is* the rejected family, and on a
five-session lap corpus with 3 baseline false triggers going to 5 "is well inside
noise". The deep end is worse decoupled than coupled (lap 47/80 against 60/80 at
0.60), the same coupling running the other way — a higher release line re-arms
sooner, so ring-down clears the reduced bar and doubles become un-armed triples.

Worth keeping: the control reproduces D9 **to the number**. At 0.60 coupled, soft
reads 11/20 = 55.0 % and lap 60/80 = 75.00 % — exactly the "soft 100 % to 55 %"
and "lap 73.75 % to 75.00 %" D9 records. The field is now sweepable and the
coupling is documented and unit-tested, which was not true before.

**Nine amplitude-family variants have now been graded and the axis is closed.**
Every one recovers the same one easy held-out gesture and pays in lap false
triggers, for one reason: a bar is a scalar, and a ring-down lobe and a real
second strike have the same amplitude. No threshold on that axis separates them.
`rejected/in-gesture-release-decoupled`.

## The motion gate composes with M26, in a narrow window

`rejected/fp-motion-gate` was measured against the resonator and never against
M26. M26's cost is exactly 2 added lap false triggers, so it was worth asking.
Train, M26 on, sweeping `motionGateG`:

| gate | desk | soft | lap | lap FP |
|---|---|---|---|---|
| off | 22/23 | 20/20 | 76/80 | 5 |
| ≤ 0.028 | 22/23 | **17-19/20** | 76/80 | 4 |
| **0.030 – 0.035** | 22/23 | 20/20 | 76/80 | **4** |
| ≥ 0.040 | 22/23 | 20/20 | 76/80 | 5 |

It removes one lap false trigger at zero detection cost. **It is not proposed.**
The window is about 0.009 wide, bounded below by soft gestures breaking and above
by the gain vanishing, and the whole result is one event measured in sample —
the exact shape critics rejected as noise in round 1 (`+1 gesture, p = 1.0`). No
held-out grade was spent: held-out already reads 0 false triggers with M26, so
there is nothing there for it to improve, and the split is not spent to confirm
a single in-sample event.

Worth knowing if M26 is ever revived after the lap-confound recording exists:
`motionGateG` 0.032 is the centre of that window, and the gate composes rather
than conflicting.

## The one untried combination is dominated

M26 and the resonator each reach lap out of sample by different routes and had
never been run together. Now they have been, on train:

| config | desk | soft | lap | lap FP |
|---|---|---|---|---|
| shipped default | 22/23 | 20/20 | 59/80 | 3 |
| resonator only | 22/23 | 20/20 | 73/80 | 6 |
| **M26 only** | 22/23 | 20/20 | **76/80** | **5** |
| M26 + resonator | 22/23 | 20/20 | 76/80 | 6 |

Zero detection gain over M26 alone, one more false trigger. Strictly dominated,
so no held-out grade was spent on it — that split is the only unbiased evidence
here and it is not spent on options that already lose in sample.

In hindsight the shape is obvious: both mechanisms recover the *same* lap
gestures by different routes, so the gains do not add while the false-trigger
costs do. The resonator lowers the admission threshold; M26 halves it again for
the second tap. Stacking them widens one door twice.
`rejected/m26-plus-resonator`.

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

## The cheapest real answer is 10 minutes, not 39

The PRD names its own final acceptance instrument, and it is not the harness:

> "Final acceptance is a live driving test on the built app, run by a fresh
> critic: perform 50 deliberate double-taps and record hit rate and latency, then
> type continuously for 5 minutes and record false triggers. Compare against the
> bar. If it loses, keep going."

That is already built, and it grades two of the bars the held-out corpus cannot
touch — detection at the granularity the 98 % figure was written for (49/50), and
typing false triggers live rather than by replay:

```bash
./dist/build-app.sh
./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300     # about 10 minutes
```

Run it with `--record` and it leaves a recording instead of a claim. Without the
flag it writes nothing and behaves exactly as before.

```bash
./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300 \
    --record .tunk-acceptance --surface desk [--tap-category tap_deck]
```

Two sessions per run, because the phases are different categories: the taps go to
`tap_<surface>` with `expected_triggers = 50`, the typing to `typing` with zero.
Both carry the detector that produced them in `meta.json`. `labels.jsonl` is
written EMPTY on purpose — the test knows when it PROMPTED, not when anybody
tapped, so ground truth comes from `bin/tunk-label run <dir>` reading the `beep`
marks, exactly as it does for every other session. `--record` takes an explicit
path and has no default, so nothing lands in `data/` unless you name it.

It now also **leaves evidence a critic can re-grade**, which it did not before:

```bash
./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300 \
    --record data/holdout --surface lap --tap-category tap_deck
./bin/tunk-label run data/holdout/<the new session>
./bin/tunk-score run --data data/holdout --i-am-a-critic
```

Two FORMAT.md sessions per run — a tap deck with `expected_triggers` set to the
tap count, and a typing session with 0. The PRD makes final acceptance a test
"run by a fresh critic", and until now its whole output was a printed number that
no critic could check. **It writes marks, never labels**: `AcceptanceRecorder` has
no `TapLabel` API, `labels.jsonl` is created empty and never reopened, and ground
truth comes from `tunk-label` reading the beep marks independently, exactly as for
every other session in the corpus. Without `--record` nothing is written and the
output is byte-identical.

It refuses to record in two cases, both of which would otherwise waste the whole
run and only reveal it afterwards:

- **no usable audio output** — a beep nobody hears would anchor every label to a
  cue that never sounded;
- **secure event input held by another process** — the window server then
  delivers no keystrokes to any monitor, so `input.jsonl` comes out empty and
  `verify` rejects the typing session as unusable for false-positive scoring,
  after you have already typed for the full five minutes.

Both were verified by running them. Without `--record` neither guard applies,
because nothing is being kept.

**Check before you start:** the machine must be unlocked with nothing holding
secure input. `ioreg -l -w 0 | grep kCGSSessionSecureInputPID` should print
nothing. During this session it printed `397` (loginwindow, screen locked), which
is also why 43 emit tests fail here.

**So one 10-minute run on your lap produces a held-out typing session and a
labelled lap deck as a side effect** — two of the three things the corpus is
missing, from the test the PRD already asks you to perform.

It also now measures **HID delivery lag** during the typing phase, which no
recording could: `input.jsonl` stores the hardware stamp and never the arrival, so
the gap between them has been invisible. That gap is the single number blocking
the largest latency win available — `rejected/early-fire-on-count` took held-out
p95 from 211.4 ms to **16.3 ms** with detection unchanged, and was rejected only
because firing early cuts the keystroke gate's slack from ~290 ms to 25 ms. Its
tag says it is "worth reviving only if HID delivery jitter is measured on this
machine and earlySettleNs is set from it rather than from preGateNs". The run now
prints p50/p95/p99/max and what `earlySettleNs` would have to be to keep the
gate's reach.

Latency currently passes at 208.9 ms against a 250 ms bar, so this is not about
the bar — it is about "felt reliability matching iPhone Back Tap", which is the
one criterion no harness can score.

It honours the experimental switch, so it measures whichever detector is selected
in Settings — verified: `Engine.init` takes `tuning: settings.tuning`, and
`AppSettings` reads the toggle back from defaults. Run it once per surface to get
the per-surface bar. It deliberately does **not** post the bound action.

One hardening this round: `speak()` called `/usr/bin/say` and waited without a
bound. `say` returns in 1.5 s today, so this was latent rather than live — but it
has hung to a full 2-minute timeout on this machine before, which is why
`Cue.say` is already bounded, and a 50-tap run calls it 50 times in a test only a
human can perform. It now gives up after 8 s, once, and carries on with printed
prompts.

Note what this does *not* settle: confound false triggers, and the lap-confound
recording that prices the experimental mechanism. Those still need
`record-for-the-bar.sh`.

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
