# Where Tunk stands against the bar

Measured on 163 prompted double-taps, 8.4 minutes of continuous typing and
49 minutes of ambient and confound recordings, across three surfaces, on one
operator and one machine. Every number here comes from `tunk-score` over real
recordings; nothing is synthetic.

The PRD asks that a target proved physically unreachable be reported **with the
data, not quietly relaxed**. This is that report.

## The 60 Hz point: held-out 60/60, and why that is not the bar met

A critic auditing the re-label found, as a side finding, that a plain 60 Hz high
pass at threshold 0.012 g with the threshold floor released scores **held-out
60/60** — desk 20/20, soft 20/20, lap 20/20, p95 201.4 ms, zero false triggers.
Verified here, reproducing exactly.

That is every held-out detection check passing on all three surfaces, and it is
**not** the bar met. Three reasons, in order of weight.

**1. Half the lap gain is credits landing on a different transient.** The harness
reports 6 of 20 held-out lap credits disagreeing with the label by more than
40 ms. The clean count is 14/20 = **70 %**, against 16/20 = 80 % for the shipped
detector, which carries 2. By the contract this config detects everything; by the
measure built to catch exactly this, it is worse than what ships.

**2. It fails on the larger sample.** Training data holds 80 lap gestures, 20
soft and 23 desk against held-out's 20 each:

```
              desk        soft         lap        lap FP/20min
shipped     95.65 %    100.00 %     73.75 %          6.54
60 Hz       95.65 %     85.00 %     87.50 %          8.72
```

Soft loses three gestures and the lap false-trigger rate gets worse against a
bar of 1. A configuration that reads 100 % on twenty held-out soft gestures and
85 % on twenty training ones is not a configuration that has solved soft.

**3. It was selected against held-out.** The critic searched configurations and
reported the held-out score. That is the one thing the held-out set cannot
survive being used for. Its value comes from being untouched, and a number
chosen because it looked good on it is not evidence about anything.

So the honest reading is that a 60 Hz front end trades soft for lap, gets a
favourable roll on twenty held-out lap gestures, and buys much of that with
credits on the wrong transient. It is recorded because it is real and because
somebody will find it again; it is not proposed, and the shipped default does not
move.

What it does establish, and this matters: **the four held-out lap misses are
recoverable by changing the detector, without touching a single label.** They are
not a labelling artifact and not a hardware limit.

### Searched properly, on train only, the corner cannot hold soft

Knowing a solution exists somewhere in the space, the disciplined question is
whether one exists that keeps soft. Swept on training data, threshold refit at
every corner, soft shown as a count because that is where it breaks:

```
hp     thr      desk      soft     lap      lapFP   typingFP
30     0.008    95.65    11/20    36/80     6.54       2
30     0.012    95.65    12/20    56/80    13.08       0
40     0.012    95.65    15/20    64/80    10.90       0
50     0.012    95.65    18/20    67/80    10.90       0
60     0.012    95.65    17/20    70/80     8.72       0
```

**No cell holds soft at 20/20.** The best is 18/20, and at the low corners a low
threshold starts breaking the make-or-break metric — two typing false triggers at
30 Hz / 0.008 g. So the 60 Hz point's held-out soft 20/20 is a favourable roll on
twenty gestures, not a property of the configuration: on eighty times the lap
evidence and the same twenty soft gestures it reads 17/20.

The resonator remains the best known point and beats every cell above: train soft
**20/20** with lap 73/80, held-out desk 20/20, soft 20/20, lap 19/20. Its
remaining costs are one held-out lap gesture and a lap false-trigger rate of
13.08 per 20 minutes against a bar of 1 — which the corrected labels take to 2
false triggers (4.36 per 20 min), still above the bar.

## The largest open question: the lap labels may be wrong

A critic commissioned to refute the unreachability claim came back with
something else — that lap ground truth is systematically misplaced, and that
correcting it removes most of the lap deficit. This is the biggest unresolved
item in the project and it is recorded here rather than acted on.

**Their evidence.** An instrument independent of the detector: zero-phase (so
non-causal, offline only) 60 Hz high pass, 3-axis magnitude, 5 ms mean, local
maxima at 8x the session median. Controls that matter:

- It reproduces all 183 shipped labels byte-exact when configured as the
  labeller, so the port is validated before it is trusted.
- On **desk**, where each gesture yields exactly two unambiguous peaks, 40
  gestures move by a median of **0.0 ms** and none by more than 40 ms.
- Held-out **desk 0 of 20 move, soft 0 of 20 move, lap 19 of 20 move.**
- Corner-stable at 50, 60 and 80 Hz; it breaks down only at 25-30 Hz, which is
  the ring band. 60 Hz sits 20 Hz from the resonator, so it cannot be circular
  with the mechanism it happens to vindicate.
- Several corrections make intervals **wider** (13e15a g4 91 -> 205 ms), so the
  rule is not systematically detector-flattering.

**Independently reproduced here.** Implementing the same instrument from scratch,
on the five held-out lap groups whose labels move most:

```
group   energy at label   energy at instrument peak   ratio   timing
g0         0.003910              0.005353            1.37    150 ms vs labelled 236
g1         0.002017              0.003774            1.87    159 ms vs labelled 249
g2         0.002490              0.003361            1.35    134 ms vs labelled 233
g3         0.003447              0.004394            1.27    124 ms vs labelled 223
g6         0.002143              0.002607            1.22    128 ms vs labelled 224
```

In every one there is a stronger high-frequency peak *earlier* than the labelled
second onset. Above the ring band the contact impulses dominate; at the
labeller's own corner the ring does. The labeller appears to be placing lap
second onsets on ring lobes, 60-100 ms late.

**Why lap and not desk.** Ring-to-strike is 0.20-0.29 on desk and 0.30-0.61 on
lap. An amplitude-greedy peak picker only confuses a lobe for a strike when the
lobe is comparable to the strike, which is a lap-specific condition and exactly
what the surface measurement predicts.

**What it would change.** Re-grading the same detector, trigger counts identical,
only ground truth moved: train lap 73.75 % -> 77.50 %, lap false triggers
**3 -> 0** (all three sat in the session with the proven defect), and with the
resonator lap 91.25 % -> 96.25 %.

**Why it has not been acted on.** Rewriting ground truth is the most
self-serving action available here, my own previous attempt at it moved 32 of 183
groups and collapsed intervals onto the 80 ms floor, and I would be the
beneficiary of the correction. Two independent implementations agreeing on
direction is strong, and it is not the same as an audited re-label with the desk
and soft controls re-run and the diffs reviewed by someone who did not build the
detector. That is the next piece of work, and it needs a decision rather than
another round from me.

## Finding the rejected mechanisms

Every mechanism built for this project is preserved as an annotated tag, with
its verdict in the tag message:

```bash
git tag -l 'rejected/*' 'shipped/*' 'audit/*'
git show rejected/rearm-valley-rise      # what it did and why it was rejected
git diff main...rejected/ring-subtraction
```

Sixteen rejected, one shipped (`shipped/resonator-front-end`), one audit of the
scorer itself. The worktrees they were built in held 20 GB and are gone; the
commits are not.

## The false-trigger metric conflates two different questions

The lap false-trigger rate is what keeps the resonator off by default: 13.08 per
20 minutes against a bar of 1, against the shipped detector's 6.54. Broken down
by what the operator was doing, on training data:

```
                                        minutes   false triggers   per 20 min
shipped    not tapping (idle/typing/confound)  39.7        0           0.00
           tap decks (deliberately tapping)     9.4        3           6.41

resonator  not tapping                         39.7        0           0.00
           tap decks                            9.4        6          12.82
```

**Every false trigger in the corpus occurs inside a tap deck.** Across 39.7
minutes of not tapping — 26 minutes idle, 11.7 typing, 2.1 confound — both
configurations fire **zero** times.

That is two questions wearing one number:

1. *Will Tunk fire when you are not tapping?* Measured at **0 in 39.7 minutes**
   for both. This is the question the PRD's "live use" phrasing is about.
2. *Will Tunk fire spuriously while you ARE tapping?* Measured at 3 and 6 in
   9.4 minutes. These are real misfires a user would feel — a gesture firing
   twice, or a fumble between prompted taps counting as one.

**This is not grounds for relaxing the bar.** The second number is a genuine
defect and the pooled rate is the honest conservative reading. But the pooled
rate is dominated by a denominator — deliberate tap decks — that is a small
fraction of real use, and reporting it alone implies Tunk misfires while you work,
which is measured false on every surface.

The audited label correction bears directly on the second question: 4 of the
resonator's 6 become detections under corrected labels, because they were fired
on gestures the labeller had mispaired. That would leave 2 in 9.4 minutes.

What settles it is `confound_handling` — a laptop on a lap being moved while
nobody taps it. It has never been recorded on any surface, the corpus holds zero
seconds of it, and `bin/record-for-the-bar.sh` captures it.

## The scoreboard

| Criterion | Bar | desk | soft | lap | held-out desk |
|---|---|---|---|---|---|
| False triggers while typing | 0 | **0** ✅ | **0** ✅ | **0** ✅ | — |
| False triggers, live use | < 1 / 20 min | **0.00** ✅ | **0.00** ✅ | 4.36 ✗ | **0.00** ✅ |
| Latency p95 | ≤ 250 ms | **200 ms** ✅ | **209 ms** ✅ | **225 ms** ✅ | **189 ms** ✅ |
| Detection rate | ≥ 98 % | 95.65 % ✗ | **100 %** ✅ | 73.75 % ✗ | **100 %** ✅ |

**Passing:** the make-or-break metric on every surface, latency on every surface,
detection on soft and on a held-out set the threshold was never fitted to.

**Failing:** detection on desk by one gesture, detection and live false triggers
on lap.

## Why desk misses by one

Twenty-three prompted double-taps, twenty-two detected. The miss is two clean
0.1025 g strikes at SNR 80 and 73, **426 ms apart**.

It is a real, deliberate double-tap and it is counted as a miss. It cannot be
grouped, because the join window cannot exceed the confirm window, and the
confirm window **is** the latency — widening it to admit 426 ms would put p95 at
roughly 430 ms against a 250 ms bar.

So desk's 95.65 % is the cost of the latency budget, exactly. Every other gesture
in every desk session, including the twenty held-out ones, is detected. If the
gesture envelope were documented as "two taps within about a fifth of a second",
desk would read 100 % — but that is relaxing the number by redefinition, so it is
recorded as a miss and named here instead.

## Why lap fails

Nineteen misses out of eighty, and they split cleanly:

- **10 inside the join window**, where a second onset was never declared. Lap
  taps run 0.038–0.048 g against 0.082 g on a desk, and roughly one lap
  second-tap in ten falls under the shipped threshold.
- **8 outside the window**, at 221–597 ms. Same structural limit as desk's single
  miss.
- **1 under the onset debounce.**

Plus 6 false triggers across 9.2 minutes of lap tap sessions — none of them
during typing, which stayed at zero.

### What was tried, and measured

| Lever | Result |
|---|---|
| Threshold down (0.024) | lap 73.75 → 81.25 %, but **soft collapses 100 → 70 %** |
| Threshold up (0.036) | soft holds 95 %, **lap falls to 52.5 %** |
| Onset debounce | 100 ms is optimal; 120 identical, 140+ worse |
| Release fraction | 0.4 is optimal; every higher value is worse everywhere |
| Lower bar for the 2nd tap | lap 73.75 → 75 %, **soft collapses 100 → 55 %** |
| Wider join window | lap 65 → 70 %, **latency p95 209 → 389 ms** |
| Per-surface calibration | desk 95.65 %, soft 100 %, **lap 82.5 % at its own best** |
| Learned join window (235 ms) | held-out lap **80 % → 80 %**, latency 208.9 → 223.9 ms |

### What the learned window does and does not fix

Calibration now fits the join window to the operator's own intervals rather than
shipping 220 ms for everyone. Fitted per surface on training sessions only:

```
desk  p90 198 ms  ->  227 ms
soft  p90 208 ms  ->  235 ms  (clamped from 239)
lap   p90 259 ms  ->  235 ms  (clamped from 298)
```

Graded on held-out lap, the wider window recovers **nothing**, and costs 15 ms of
latency. The four held-out lap misses break down as:

- **3 amplitude** — only one onset was ever declared; the second tap never
  cleared the bar.
- **1 timing** — two onsets 240 ms apart, which a 235 ms window still misses by
  five.

So on this operator's lap the dominant failure is force, not rhythm, and the
earlier training-set figure (8 of 19 misses out of window) overstated how much
timing was to blame. The window fit is still worth shipping — it is what stops a
naturally slower tapper from being failed by a number chosen for someone else,
and the clamp is now reported to the user instead of applied silently — but it is
not the lap fix, and nothing here should be read as one.

### Correction: the ring carries what the noise floor did not

The claim below — that nothing available separates the surfaces — is right about
the noise floor and wrong as a general statement. Ring-to-strike, measured per
session across both data roots:

```
desk  0.20-0.29   (3 sessions)
soft  0.18-0.34   (2 sessions)
lap   0.30-0.61   (5 sessions)
```

Lap runs 0.30-0.61 against 0.18-0.34 for desk and soft, overlapping only in
0.30-0.34, which is two sessions out of ten. The noise floor by comparison reads
0.00011 / 0.00014 / 0.00012 and separates nothing at all.

Ten sessions is far too few to drive automatic profile switching, and the
overlap is real. But the more useful point is that **the surface was never the
thing worth knowing.** What predicts detection is how loudly the case rings, and
that is measurable directly — a lap that does not ring works (a4a257, ratio 0.42,
100 %) and a lap that does fails (13e15a, ratio 0.61, 80 %). Conditioning on the
ring is strictly better than conditioning on the furniture, and it is what
calibration now reports to the user.

### Why calibration cannot pick the surface for you

Per-surface calibration helps (the table above), so the obvious next step is to
detect the surface and switch profiles automatically. The adaptive noise floor is
the only signal available for that, and it does not carry the information:

```
median high-passed magnitude, tap sessions
  desk  0.00011
  soft  0.00014
  lap   0.00012
```

Three surfaces inside a 30 % spread, with typing sessions (0.0005–0.0007)
an order of magnitude above all of them. What the floor measures is whether the
user is touching the machine, not what the machine is resting on. Any profile
switching has to be something the user does deliberately.

### The threshold ceiling, measured on held-out data

Sweeping the threshold from 0.020 to 0.040 g against the held-out sets tops out
at 95 % pooled (57/60) and never reaches the 98 % bar. Three of the four lap
misses are a second tap that no threshold in the usable band recovers without
spending the false-trigger budget. Reported here rather than acted on: these are
held-out numbers and tuning against them would destroy the only unbiased estimate
the project has.

**Soft and lap pull in opposite directions.** Every step that helps one costs the
other about twice as much. Even with perfect per-surface calibration — the PRD's
own remedy for coupling that varies by surface — lap tops out at 82.5 %.

## Correction: the lap failure is deafness, not weakness

Everything above this line that attributes lap misses to weak second taps is
wrong, and the four mechanisms built on that premise are recorded below as
measured negatives.

`tunk-score` reports a missed gesture as *"only 1 ungated onset near this label"*.
That was read as "the second tap was too weak to cross the bar". Tracing the
detector's own arm state says otherwise. On the three held-out lap gestures that
defeated every amplitude mechanism:

```
group   disarms   re-arms   second tap   deaf by
g1      16.713    17.073    17.003        70 ms
g3      23.496    23.879    23.759       120 ms
g6      35.821    35.956    35.889        67 ms
```

Those second taps measure 1.20x, 1.35x and 2.01x the threshold. They are strong.
The detector was still disarmed.

Re-arming requires the envelope to fall back under `releaseFraction` (0.4) times
the threshold. A damped chassis rings for hundreds of milliseconds, so between
the two halves of one gesture the envelope never returns to baseline and the
detector stays deaf straight through the second strike.

Split across every training tap deck — "disarmed, and the transient was big
enough to have crossed" against "genuinely under the bar":

| surface | gestures | 2nd tap seen | deaf | weak |
|---|---|---|---|---|
| desk | 23 | 23 | 0 | 0 |
| soft | 20 | 17 | **3** | 0 |
| lap | 80 | 55 | **12** | 13 |

Every soft miss and half the lap misses are deafness. This also explains the
soft-versus-lap tug of war that defeated every earlier lever: lowering the bar
cannot help a detector that is not listening, and it does buy false triggers.
`ArmStateDiagnosisTests` holds these counts as upper bounds.

## Four amplitude mechanisms, built and rejected

Each was built by one agent and graded by a separate critic with fresh context,
who rebuilt from source and ran the harness on held-out data.

| mechanism | held-out lap | critic |
|---|---|---|
| reduced bar gated on return-to-baseline | 80 % -> 85 % | do not ship; strictly dominated |
| bar proportional to first tap's strength | 80 % -> 85 % | do not ship; p = 1.0 |
| shape discriminator before the sliding max | 80 % -> 85 % | do not ship; noise |
| envelope stage rework | 80 % -> 85 % | do not ship; effect was the bundled threshold |

All four recovered **the same single gesture** and left the same three missed.
Four independent mechanisms converging on one gesture is not four weak results;
it is one result, and it is the signature of a mispecified problem. Train gains
of 6 to 8 gestures did not transfer, and per-session effects ranged from -2 to
+5, which is an overfit signature on n=80.

## Three re-arm mechanisms, built and rejected

Same discipline: one builder each, one fresh critic each, graded on held-out.

| mechanism | held-out lap | g1 | g3 | g6 | critic |
|---|---|---|---|---|---|
| valley-rise (causal prominence) | 80 % -> **10 %** at best-for-deafness | no | no | no | do not ship |
| modelled tail decay | 80 % -> 80 % (no effect) | no | no | no | do not ship |
| debounce-only re-arm | 80 % -> 85 % | yes | no | no | do not ship |

The valley-rise mechanism **did** do what it was built to do: lap deaf counts fell
12 -> 2 and soft 3 -> 0. It recovered **zero gestures**. That is the finding.

The third mechanism's "recovery" was caught by its critic as an artifact: the
detector clocked a synthetic onset onto its own ringing tail at exactly
`lastOnset + tailRearmNs`, manufacturing a 201 ms interval inside the 100-220 ms
join window. A fitted number, not a cure.

### Why hearing the second tap does not help

On a lap the second strike and the first strike's ring are the same amplitude
scale. So:

1. The second tap lands on a decaying tail.
2. To hear it, the detector must re-arm while the tail is still elevated.
3. Re-arming on the tail also hears the tail's own ripple.
4. The group becomes three or more onsets, and the grouper fires on exactly two.

Every re-arm mechanism runs into this. Held-out declared onsets went 117 -> 145
on one setting while detection *fell* by 21 gestures; the onset trace shows the
detector firing at 16.713, 16.820, 16.921, 17.021 — a metronome at the debounce
period, re-arming on ripple rather than on strikes.

## The latency budget, priced

`BAR_ASSESSMENT` previously offered "a latency budget above 250 ms" as a way to
close lap, calling it a product decision. It has now been measured, moving
`maxInterTapNs` and `confirmWindowNs` together on training data:

| join window | lap detection | p95 | typing FP |
|---|---|---|---|
| 220 ms | 73.75 % (59/80) | 225 ms | 0 |
| 240 ms | 75.00 % (60/80) | 245 ms | 0 |
| 260 ms | 76.25 % (61/80) | 265 ms | 0 |
| 280 ms | 77.50 % (62/80) | 285 ms | 0 |
| 300 ms | 77.50 % (62/80) | 305 ms | 0 |
| 400 ms | 77.50 % (62/80) | 405 ms | 0 |

**It saturates at 280 ms.** Buying 180 ms of extra latency — well past the point
where the gesture stops feeling like a double-tap — recovers three gestures out
of eighty and leaves lap at 77.5 %. With an *unlimited* latency budget lap does
not reach the bar. That option is now closed, not deferred.

At the saturating window, 17 of the 18 remaining lap misses are still
"only 1 ungated onset near this label".

## Two gaps in the measurement itself

Named independently by all four critics, and neither is fixable by code:

1. **`data/holdout` has no typing and no confound sessions.** It is 4.5 minutes
   of tap decks. The zero-false-triggers-while-typing bar — the make-or-break
   metric — has never been graded out of sample. The held-out "0.00 FP/20 min"
   is close to vacuous.
2. **n = 20 per surface.** At that size the 98 % bar can only be met by 20/20;
   19/20 reads 95 %. One gesture is five percentage points, so the held-out set
   cannot distinguish a real fix from luck at the resolution the bar demands.

Both need recordings, not engineering: held-out typing and confound sessions on
all three surfaces, and a larger held-out lap tap deck.

**The harness cannot paper over gap 1.** Checked directly, on the two held-out
sessions where every detection check reads 100 %:

```
[  ok  ] pooled  detection rate, all armed gestures  >= 98 %  ->  100.00 % (40/40)
[ ---- ] pooled  false triggers, typing sessions     = 0      ->  no typing sessions
[ ---- ] lap     surface coverage                    >=1 session -> none recorded
VERDICT: INCOMPLETE            exit code 3
```

A missing typing session is `.noData`, and `.noData` maps to `.incomplete`, not
to `.pass`. So a perfect detection score cannot buy a green verdict while the
make-or-break metric has nothing behind it. The gap is real, and it is reported
rather than hidden — which is the difference between an unmeasured metric and a
false green.

## Which tap goes missing

Twelve mechanisms targeted the second tap. The split had never been measured.
Replaying every training tap deck and asking, for each missed gesture, which
onset the detector never declared:

| surface | detected | missed | first tap unseen | second unseen |
|---|---|---|---|---|
| desk | 22 | 0 | 0 | 0 |
| soft | 20 | 0 | 0 | 0 |
| lap | 61 | 17 | **3** | **14** |

So the focus was right: lap misses are overwhelmingly the second tap, and no
gesture fails with both onsets seen but ungrouped. `MissedTapSideTests` holds
these as upper bounds.

## Correction: the ranking yardstick below was wrong

The section that follows estimated that a pick-the-largest ranker could reach
about 90 % on lap. That estimate was wrong, in two ways that both inflated it,
and three critics found the consequence independently before the arithmetic
error was found.

| the estimate assumed | the detector actually enforces |
|---|---|
| candidates collapsed 40 ms apart | `minInterTapNs` / `onsetDebounceNs` = **100 ms** |
| a [100, 450] ms search window | legal join window **[100, 220] ms** |

Redone inside the window the detector can actually use, on lap training data at
a 0.8x bar:

```
debounce 100 ms:  0 cand  2   1 cand 76   2+ cand  2 ( 2.5 %)   2nd tap present 64/80 (80 %)
debounce  70 ms:  0 cand  2   1 cand 71   2+ cand  7 ( 8.8 %)   2nd tap present 65/80 (81 %)
debounce  50 ms:  0 cand  2   1 cand 68   2+ cand 10 (12.5 %)   2nd tap present 65/80 (81 %)
debounce  35 ms:  0 cand  2   1 cand 66   2+ cand 12 (15.0 %)   2nd tap present 65/80 (81 %)
```

Two consequences:

1. **Ranking cannot engage.** Only 2.5 % of lap gestures offer more than one
   legal candidate. Measured in the built mechanisms: 9 selection attempts all
   held exactly one eligible candidate; one prunable group in 49 minutes of
   training data; zero on held-out. What shipped in all three was the second-tap
   threshold reduction already recorded as measured shut, wearing a ranking
   name.
2. **Lowering the bar buys nothing inside the legal window.** 80 % presence at
   0.8x against 81.2 % at full bar. The information is not under the bar; it is
   outside the window.

Shortening the debounce does not rescue it: at 35 ms only 15 % of gestures offer
a choice and presence stays at 81 %. That combination is measured shut without
needing to be built.

**This is why lap sits at exactly 80 %.** For about a fifth of lap gestures
there is no second transient inside the legal join window at any threshold, and
widening the window saturates at 77.5 % (see the latency table above).

## Ranking, not admission — and the yardstick it must beat

Every one of the eleven mechanisms used a statistic to ADMIT an onset: "is this
a real tap?" That is detection, and it is why the best statistic found died —
at a threshold admitting 1 % of ring lobes it kept only 10 % of real strikes.

But the detector already waits a full confirm window before firing, holding
several candidate onsets and choosing none. The useful question is therefore
"WHICH candidate is the real second tap?", which is ranking, and ranking inside
a window that has already elapsed costs no latency at all.

Feasibility, measured on lap training data by reconstructing the detector's
envelope and looking for candidate local maxima in the join window. (The
reconstruction reads about 0.70x the detector's published strength, so these are
estimates, not harness numbers.)

| bar | real 2nd tap is among the candidates | candidates per gesture |
|---|---|---|
| x1.0 (shipped) | 65/80 (81.2 %) | median 1 |
| **x0.8** | **76/80 (95.0 %)** | median 2 |
| x0.6 | 77/80 (96.2 %) | median 2 |
| x0.4 | 77/80 (96.2 %) | median 4 |

So the information is present: at a bar 20 % lower, the real second tap is a
candidate in 95 % of lap gestures. Three gestures out of eighty have no second
transient at any bar, and those are the true floor.

**But most of the work is not ranking.** At x0.8:

```
exactly 1 candidate, no choice needed  : 33  (43 %)
2+ candidates, a ranker must choose    : 43  (57 %)
  of those, picking the LARGEST is right: 39/43  (91 %)
```

A trivial pick-the-largest rule therefore reaches roughly 33 + 39 = 72 of 80,
about **90 % on lap**, against 73.75 % today. That is the yardstick: any
statistic clever enough to justify its complexity has to beat 91 % selection
accuracy, and `cos_first_xy` at AUC 0.79 probably cannot.

Note what this does and does not say. Amplitude failed four times as an
ADMISSION rule and works here as a RANKING rule, because ranking compares
candidates from the same gesture on the same surface, where the absolute scale
that defeated it cancels out. The estimate also ignores false triggers bought by
the lower bar outside gestures, which is what killed the earlier attempts, and
it assumes the first tap was detected. The harness decides; this only says the
direction is not hopeless.

Even at 90 %, lap does not reach 98 %.

## The high-pass corner: the first lever that is not a straight trade

The chain opens with a 20 Hz one-pole high pass whose only job is removing
gravity. It was never shaped for discrimination. But the one spectral difference
that survived amplitude matching lives right at that corner:

```
lap, amplitude-matched   real second strikes  centroid p50  31.4 Hz
                         ring lobes           centroid p50  26.1 Hz
```

Raising the corner suppresses the ring more than the strike, and the noise floor
faster than either. Measured on lap training data:

| HP corner | strike/ring | strike/noise |
|---|---|---|
| 20 Hz (shipped) | 2.13 | 28.1 |
| 30 Hz | 2.37 | 29.3 |
| 40 Hz | 2.56 | 30.7 |

Both improve together, which was not expected — tilting away from the tap's own
energy peak was supposed to cost absolute SNR.

Replayed through the real detector with the threshold refitted per corner
(the corner changes the scale of everything downstream, so holding the threshold
fixed would measure the rescaling instead of the filter):

```
                        desk     soft      lap    typingFP
HP 20 Hz  thr x1.00     95.7 %  100.0 %   73.8 %      0     <- shipped
HP 30 Hz  thr x0.75     95.7 %  100.0 %   83.8 %      0
HP 28 Hz  thr x0.80     95.7 %  100.0 %   81.2 %      0
HP 35 Hz  thr x0.65     95.7 %   90.0 %   87.5 %      0
```

**The lap gain is a broad plateau** — 80-86 % across the whole region 26-34 Hz by
x0.65-0.75 — so it is not a fitted cell. Desk never moves. Typing false triggers
stay at zero throughout.

**Soft's 100 % is not a plateau.** It appears in three cells and reads 85-95 %
elsewhere, and soft training data is one session of 20 gestures, so that spread
is two gestures either way. The honest summary is that the corner buys lap about
ten points and costs soft between nothing and ten, depending where you sit.

That is still a trade, but it is a far better curve than every earlier lever,
which cost soft 30-45 points to buy lap seven. It is the only change measured so
far that moves lap materially without collapsing soft.

Held-out has not graded this yet. These are training numbers and the same
caution applies as to every other training number in this file: the four-round
pattern has been that train gains of six to eight gestures deliver one on
held-out.

## How much of the resonator's held-out gain is clean

The strict measure had a weakness worth fixing rather than arguing about. It
flags a credit when the trigger's onset vector disagrees with the label by more
than 80 ms — the labeller's own two-tap floor. But a lap ring lobe sits about
25 ms from its strike, so a credit disagreeing by 40-60 ms may be firing on a
lobe two steps away and still pass.

The harness now publishes the whole distribution instead of one line. Held-out:

| config | lap detections | credits with spread > 40 ms | clean |
|---|---|---|---|
| shipped default | 16/20 | 2 (59, 58 ms) | **14** |
| resonator on | 19/20 | 4 (61, 59, 58, 41 ms) | **15** |

Two of the resonator's three new credits have spreads of 61 and 41 ms. Counting
only credits whose onsets agree with the label to within 40 ms, the gain is
**14 -> 15 — one gesture, not three**, and held-out lap reads 75 % rather than
95 %.

Desk and soft have **zero** credits over 40 ms under either config (p50 spreads
1.2-2.5 ms, max 12.5 ms). The loose credits are entirely a lap phenomenon, which
is what ring lobes predict and what the whole front-end argument was about.

So the resonator's honest held-out claim is: one clean lap gesture recovered,
two more that the corpus cannot adjudicate, desk and soft untouched at 20/20,
latency unchanged, and a doubling of train lap false triggers. That is a
narrower result than "80 % -> 95 %" and it is the one to quote.

## The join window, re-measured at the resonator point, and the default not flipped

The window was measured saturated at the OLD operating point. At the resonator
point it reopens on training data — 220 ms gives lap 91.25 %, 240 ms gives
93.75 %, and 240 ms still clears the latency bar at p95 246.5 ms. Three
independent critics graded 220, 230 and 240 ms on held-out, blind to each other.

**It did not transfer.** All three windows give identical held-out results —
desk 20/20, soft 20/20, lap 19/20, pooled 59/60, zero false triggers — and the
wider ones simply charge every gesture on every surface 10 or 20 ms more
latency. Two of three critics called their own candidate strictly dominated.
The shipped 220 ms window stands.

### The default stays OFF, against one critic's advice

The operating-point critic recommended making the resonator the default. The
mechanism's own critic, who examined it far more closely, said the opposite:
land it with the knob off, do not flip the default yet. Taking the more
cautious verdict, for three reasons.

1. **Two of the three held-out lap recoveries are questionable.** Groups 1 and 3
   have onset spreads of 41.3 and 61.3 ms, the two largest on the held-out set.
   In both, the first onset leads the label by the session's ordinary 30-40 ms,
   while the SECOND onset lands 81-92 ms early. `strictDetectionRate` passes
   them because it measures the SPREAD of residuals, which cancels a lead common
   to every onset by design — it cannot see a shift in one onset only. And
   41-61 ms is exactly lap ring-lobe scale. Only group 5 is a clean recovery.
   **This is a real limitation of the strict measure** and it should not be
   quoted as if it settled the question.
2. **The false-trigger cost is unpriced.** Train lap in-deck false triggers
   double, 3 -> 6. `data/holdout` has no typing, idle or confound sessions, so
   its zero establishes only that the detector does not double-fire inside a tap
   deck.
3. Flipping it changes what "a tap" means throughout the synthetic fixtures. The
   measured chain gain moves from 0.68 to **0.0789** — the resonator passes a
   narrow slice of a broadband impulse — so a synthetic tap needs about three
   times the raw amplitude for the same envelope. That migration is real work
   and should be done deliberately, not as a side effect.

Flipping the default would not reach the lap bar in any case: 95 % against 98 %,
and at n=20 only 20/20 will do.

## One lap session carries most of the remaining lap deficit

Per session at the resonator operating point, training data:

| session | detection | strict | false triggers |
|---|---|---|---|
| lap a4a257 | **100.0 %** | **100.0 %** | 0 |
| lap ad3fd3 | 95.0 % | 95.0 % | 1 |
| lap 3fee5b | 90.0 % | 85.0 % | 1 |
| lap **13e15a** | 80.0 % | **50.0 %** | **4** |
| soft fe9b8c | 100.0 % | 100.0 % | 0 |
| desk 5f07e8 | 100.0 % | 100.0 % | 0 |
| desk 8f0079 | 66.7 % | 66.7 % | 0 |

A lap session now reads 100 %, which has not happened before. On the three
sessions other than 13e15a, lap is 57/60 = **95.0 %**.

13e15a is an outlier on every axis at once, and the evidence that its ground
truth is wrong rather than merely difficult is now substantial:

1. A **proven pairing defect** in its group 1, verified at source level by an
   independent critic: a 597 ms pair chosen over a legal 265 ms one.
2. **Strict rate 50 %** against 85-100 % elsewhere. Half its credits land on a
   different physical event than the label names.
3. Labelled intervals p50 258 ms against 181-187 ms in every other lap session.
4. It holds **4 of the 6** lap false triggers, and at shipped defaults it held
   all 3.
5. Two independent statistics (`cos_first_xy`, crest factor) score BELOW CHANCE
   on it while scoring 0.87-1.00 on the other three.
6. The operator reports resting a hand on the chassis during some lap sessions,
   which changes the coupling.

Points 1 and 2 say the labels are wrong. Points 3 to 6 say the operator may
genuinely have tapped differently. **Both can be true**, and the corpus cannot
separate them: nothing recorded says which gesture the operator believed they
made. That is what a confirmed re-recording would settle.

This is stated as context for reading the lap number, not as grounds for
dropping the session. Excluding a session because it is inconvenient is how a
project talks itself into a passing grade, and the headline lap figures
everywhere in this file include 13e15a.

The odd seventh miss at the resonator point — "the transient was above threshold
but rejected by the detector's own logic", 0.0534 g against a 0.0110 g bar,
4.85x — is 13e15a group 1 itself, the group with the proven defect. Labelled
16.128 -> 16.725 s, a 597 ms span. Not a detector failure.

## A labelling bug that is real, and a fix that was worse

An audit found a source-level defect in the labeller. `Sources/TunkLabel/main.swift`
walks candidate peaks in descending amplitude and commits to the FIRST pair
inside [80, 600] ms. Its own comment says "the two strongest peaks in the window
that sit a plausible interval apart", which is not what it does: when two
partners are of similar height it takes whichever the amplitude sort happened to
put first, however far away it is.

Session 13e15a group 1 is the proof. Peaks at +905 ms (0.04713 g) and +1767 ms
(0.04963 g) against a head at +1170 ms. A 5 % amplitude difference bought a
**597 ms** pair — one millisecond under the tool's own cap, the widest label in
the corpus — over a legal **265 ms** one. The detector was then scored as missing
a gesture it had read correctly, and its correct fire counted as a false trigger.
One labelling bug, charged twice.

### The fix made it worse, and was reverted

Rule tried: among legal pairs, keep those whose weaker peak is within 80 % of the
best available, then take the tightest. Applied blind to both data roots, it
moved **32 of 183** labelled groups, and the new intervals collapsed onto the
80 ms floor:

```
13e15a  g0  259 -> 86 ms     g5  495 -> 101 ms    g18  284 -> 83 ms
3fee5b  g14 189 -> 89 ms     a4a257 g15 185 -> 93 ms
```

Those are ring lobes, not second taps. The rule replaced a bias toward
implausibly WIDE pairs with a worse bias toward implausibly TIGHT ones — the
exact failure its own comment warned about. It also rewrote six held-out groups
toward shorter intervals, which would have flattered the detector, since shorter
intervals fit the 220 ms join window.

Reverted. Ground truth is unchanged and the held-out numbers are as before.

### What this leaves

Only 5 of 183 labelled intervals exceed 300 ms, and 4 of those sit in one lap
session. So the defect is narrow, and every general repair tried either fails to
fix the proven case (maximising the weaker peak still picks the 597 ms pair) or
does far more damage than it repairs.

The honest reading is that ground truth is *fragile in exactly the sessions where
the detector struggles*, which is the worst possible place for it to be fragile,
and the corpus cannot currently distinguish "the operator tapped 597 ms apart"
from "the labeller mispaired". Settling it needs a recording where the operator
confirms each gesture, not a cleverer rule.

## WITHDRAWN: "the sensor is band-limited near 50 Hz"

**This section was wrong. It measured gravity.**

The PSD table below computed power without removing the mean, so the 0-25 Hz bin
held the DC term — mean |z| over that session is 0.9808 g — and every "nine to
ten orders of magnitude down" figure was a ratio against gravity, not against
signal. Two independent critics found this and agree to three decimal places.

Recomputed on the same desk deck, tap-aligned windows, **mean removed**:

```
   0- 25 Hz    0.67 %
  25- 50 Hz   76.62 %
  50-100 Hz   22.71 %
```

Tap windows against quiet windows from the same session: 1014x at 25-50 Hz,
**5828x at 50-100 Hz, 590x at 100-150 Hz**, falling to 3.3x by 150-200 Hz.
Brick-walling the same tap windows at 50 Hz and re-measuring 100-150 Hz gives a
ratio of 3.6e7, so that content is signal and not window leakage. The flat
ceiling above ~190 Hz is the quantiser: the smallest non-zero step in z is
1.525879e-05 g, exactly 1/65536 g.

**The sensor is usable to about 150 Hz and floor-limited above it.** It is not
deaf at 50 Hz, and "the content that would separate a strike from the chassis
ringing never reaches the file" is not a fact about this hardware.

### The consequence was wrong in the more damaging direction

"On a lap the second tap lands on the first one's ring and the two are the same
size in the envelope" is half right. They are the same size. The second one is
**not landing on the ring.**

An independent onset instrument finds two clean contacts in every one of the four
held-out lap gestures the detector misses:

```
g1  16.7101 / 16.9177   207.6 ms apart
g3  23.5018 / 23.6644   162.6 ms
g5  32.1121 / 32.2960   183.9 ms
g6  35.6368 / 35.7969   160.1 ms
```

Every interval is **inside** the legal [100, 220] ms join window. The second
contact measures 0.83x, 1.14x, 0.75x and 1.19x the first — it is *larger* than
the first in two of the four. The envelope between them falls to 7-55 % of the
first peak and crosses the re-arm line within 2.5 to 6.2 ms. The ring is gone in
under ten milliseconds, and 150 to 200 ms of quiet separates the two strikes.

### What this leaves

The operational sentence survives: **on this corpus, lap does not reach 98 %
inside a 250 ms latency budget.** Four independent attempts, including three
critics who tried to refute it, produced no better than 19/20 on held-out lap,
and at n=20 nothing short of 20/20 clears 98 %.

The word **unreachable** does not survive, and has been removed everywhere.
What was called a fact about the hardware was an artifact of my own arithmetic.

The re-arm constants were the obvious next suspect — `releaseFraction` and
`onsetDebounceNs` were fitted when the chain gain was 0.68 and the threshold
0.032 g, and at the resonator point they are 0.0789 and 0.011 g. Neither was
reachable from the harness; four critics in a row reported that wall. Both are
now exposed as config keys and swept:

```
release  debounce   lap             soft
0.3      60 ms      90.00 %         90.00 %
0.4      60 ms      91.25 %        100.00 %   <- shipped
0.4      100 ms     91.25 %        100.00 %
0.5      100 ms     91.25 %         95.00 %
0.6      100 ms     91.25 %         80.00 %
```

0.4 survives re-measurement at the new operating point. It was not the missing
lever either — but it is now gradeable, which it was not when this document
claimed to know why lap failed.

### Reconciling the two accounts — both were overstated

The adjudicating critic wrote that "the ring is gone in under ten milliseconds,
and 150 to 200 ms of quiet separates the two strikes". This document had claimed
the opposite: that the second tap lands on the ring. Measured on the raw signal
around held-out lap g1, gravity removed by a long mean, no filter:

```
  16.740  0.06969        16.833  0.07077
  16.800  0.06916        16.950  0.08651
```

Sustained excursions of 0.035 to 0.087 g across the whole window. The critic's
own "the envelope drops to 7-55 % of the first peak" is right and is not quiet:
40-50 % of peak sits between the contacts for most of the interval.

So neither account was accurate. The second contact is real, comparable in size
to the first, and separated by a region carrying **roughly half the peak energy**
— not a decayed ring, and not silence.

That reconciles the mechanism. The release line is `releaseFraction` (0.4) times
the threshold, and the inter-contact energy on a lap sits right on top of it.
Re-arming is therefore marginal and decided by where individual samples fall,
which is exactly what the trace below shows: one dip to 0.01279 against a line at
0.01280. Not a filter with too much memory, and not a chassis that rings for
300 ms. Two comparable numbers.

It also explains why both repairs fail in opposite directions. Latching the
release, or releasing on the undilated signal, re-arms during that half-energy
region and the chatter there becomes onsets. Requiring a deeper release never
re-arms at all. No single threshold separates a lap's inter-contact energy from
its contacts, because on this evidence they are the same size.

### Why the detector reports one onset where two contacts exist

Traced through the shipped chain on held-out lap g1, the gesture whose two
contacts an independent instrument places 207.6 ms apart:

```
16.7129  armed=n  env 0.03424   <- onset; release line is 0.01280
16.7930  armed=n  env 0.01279   <- under the line by one thousandth
16.8130  armed=n  env 0.01588   <- debounce expires here, envelope back above
16.8330  armed=n  env 0.05790
16.9130  armed=n  env 0.03195   <- the second contact, unseen
```

Re-arming requires the envelope under the release line **and** the debounce
elapsed **on the same sample**. The envelope goes under the line exactly once,
at 80 ms — twenty short of the 100 ms debounce — and by the time the debounce
expires it is back above and never returns. The dip is forgotten.

That reads like a defect rather than a policy, so the obvious repair is to latch
it: remember that the envelope has been under the line, and re-arm when the
debounce expires. It cannot re-arm earlier than the debounce, so it cannot
resurrect the second lobe the debounce exists to swallow.

**Measured, and it is worse.** On training data the latch changes nothing on two
lap sessions and takes soft from 20/20 to **15/20**. Re-arming promptly lets the
ring's own chatter become onsets, and those form groups that fire nothing. The
same pattern that defeated every re-arm mechanism in round two.

### Releasing on the undilated signal

The other repair the trace suggests. The 3-sample sliding maximum exists so one
physical tap reads as one onset — a detection concern. Applying it to the RELEASE
test as well holds the envelope up for three samples past every ripple, during
the exact interval the detector is asking whether the surface has gone quiet.
Detecting on the dilated envelope and releasing on the quadrature pair beneath it
is principled and had never been tried.

Measured on training data, across the debounce it interacts with:

```
                              desk           soft            lap        typingFP
dilated (shipped), 100 ms    95.7 %        100.0 %        73.8 %  (59/80)   0
undilated,         100 ms    95.7 %         85.0 %        76.2 %  (61/80)   0
undilated,         140 ms    95.7 %        100.0 %        75.0 %  (60/80)   0
undilated,         180 ms    65.2 %         60.0 %        40.0 %            0
undilated,         220 ms      0.0 %          0.0 %         0.0 %           0
```

The 140 ms cell is a real gain: soft restored to 20/20, desk untouched, lap
59 -> 60, typing still zero. It is also **one cell**. At 100 ms it costs soft
three gestures; at 180 ms everything collapses because the debounce starts
exceeding the gesture interval. A single-cell optimum worth one gesture, in a
project that has documented four separate times that train gains of six to eight
do not survive held-out, is not a result. Reverted rather than graded, because
grading it would spend the held-out set on something already known to be inside
its own noise.

### Releasing on a short mean

The third repair the diagnosis suggests, and the one the adjudicating critic's
own instrument implies: their onset finder used a 5 ms MEAN, and a mean averages
chatter down while an impulse still lifts it. The shipped chain uses a sliding
MAXIMUM, which holds chatter up. So: detect on the max, release on a mean.

```
                    desk           soft            lap
sliding max        95.7 %        100.0 %      73.8 %  (59/80)
short mean         95.7 %        100.0 %      72.5 %  (58/80)
```

Slightly worse, typing zero either way.

### The combination that looked like the first real win

Three repairs failing the same way suggested the pair rather than either half:
re-arm loosely enough to hear the second contact, then prune the chatter it lets
in. Round four's pruning never engaged because the shipped re-arm rarely hears
three things; with a loose re-arm it would.

First attempt kept the outer pair, and never fired: measured, all six over-long
groups span further than the join window allows, so first-and-last is never
legal. Keeping the first onset and its **latest legal partner** instead — the
real second contact is the last thing inside the window, the chatter sits before
it — pruned all six. On training data:

```
              desk        soft            lap          lapFP  typingFP
shipped      95.7 %     100.0 %      73.8 % (59/80)      3       0
combination  95.7 %     100.0 %      77.5 % (62/80)      4       0
```

Soft preserved, desk untouched, **+3 lap**, typing still zero. The first
mechanism measured in this project to gain lap without costing soft.

**And it is a regression.** Run through the harness rather than a hand-rolled
script, the loose-credit counts appear:

| | contract | credits disagreeing > 40 ms | clean |
|---|---|---|---|
| shipped, soft | 20/20 | 0 | **20** |
| shipped, lap | 59/80 | 6 | **53** |
| combination, soft | 20/20 | 5 | **15** |
| combination, lap | 62/80 | 12 | **50** |

Soft's preserved 100 % is 15 clean credits and 5 landing on a different
transient, against 20 clean before. Lap's three extra gestures come with six
extra loose credits. On the clean measure both surfaces go **backwards**.

Reverted. Recorded at length because of what caught it: `strictDetectionRate` and
the `> 40 ms` count exist because a critic showed my strict measure could not see
a one-onset shift, and I sharpened it rather than defending it. Two rounds later
it stopped me shipping a regression I had already called "the first real win" —
against a contract rate that said, unambiguously, that nothing had been lost.

### Three repairs, one mechanism

All three fail the same way, and together they explain the constraint better than
any of them individually:

| repair | lap | soft |
|---|---|---|
| latch the release | unchanged | **20/20 -> 15/20** |
| release on the undilated pair | 59 -> 61 | **20/20 -> 17/20** |
| release on a short mean | 59 -> 58 | unchanged |

Every one of them re-arms **sooner**. Sooner means hearing the half-peak energy
between the contacts, that energy becomes onsets, and a group with three or more
onsets fires nothing. The detection lost to over-long groups exceeds the
detection gained by hearing the real second contact.

And the escape from that — prune the surplus onsets and fire on the survivors —
is closed by arithmetic already measured. `onsetDebounceNs` keeps declared onsets
100 ms apart, and the join window is [100, 220] ms from the first onset, so two
candidates can both be legal only inside a 20 ms corner of a 120 ms band. Round
four measured it directly: nine selection attempts, every one holding exactly one
eligible candidate; one prunable group in 49 minutes of training data; none at
all on held-out. A looser re-arm does not change that, because the debounce that
sets the spacing is upstream of it.

So the constraint is not the re-arm rule, and not the grouper, but the pair: the
detector cannot hear the second contact without also hearing the chatter, and
cannot keep the chatter without losing the gesture.

*Process note, recorded because it matters:* I ran this on held-out first, since
that is where the critic's evidence sat, and only then on train. That is the
discipline this project enforces everywhere else, broken by me. It changed
nothing — train rejects the latch on its own, and the change was reverted rather
than kept — but the order was wrong and pretending otherwise would be worse than
the error.

### Is the ceiling tied to the report rate?

On most MEMS parts the anti-alias filter follows the output data rate, so a
faster `ReportInterval` might move it. Measured, six idle recordings:

```
requested    delivered
 5000 us  ->  199.0 Hz
 2500 us  ->  398.1 Hz
 1250 us  ->  796.3 Hz   <- shipped
  625 us  ->  796.3 Hz
  400 us  ->  796.3 Hz
  250 us  ->  796.3 Hz
```

**796 Hz is a hard cap.** Asking for more returns the same rate, and asking for
less simply downsamples. Power above 100 Hz stays at 6.5e-11 relative across
every setting. The rate is a dial; the bandwidth is not attached to it.

(These are idle recordings with no broadband excitation, so they establish the
rate cap. The bandwidth limit itself is measured on tap decks above, which do
have excitation.)

### Can the filter be moved?

No, not through the interface available. `--sensor-props` asks the service for
29 candidate property names — every plausible spelling of bandwidth, cutoff,
output data rate, range, and performance mode. Two return a value:

```
  ReportInterval = 1250
  BatchInterval  = 0
```

Report rate and batching are exposed. Bandwidth is not. There is no enumeration
API, so absence is not proof of unsupported — but combined with the measured
spectrum, the working conclusion is that the ceiling is fixed.

**Tunk is asked to tell a strike from a ring using a sensor that filters out the
difference.** That is the honest statement of the limit, and it is a property of
the hardware and its driver, not of the detector.

## The physical reason

One tap is not one lobe. The raw magnitude around a single real soft-surface tap:

```
   0.0 ms  0.1093  <- peak
 +12.6 ms  0.0194  <- trough
 +26.4 ms  0.0875  <- second lobe, 80 % of the original peak
```

A damped chassis rings in lobes. On a hard desk the event is over in about 5 ms
and this never arises; on soft and lap the detector must not read the second lobe
as a second tap, which is what forces the 100 ms debounce, and the debounce in
turn is why a lower threshold cannot simply be traded in.

Shape discrimination was the obvious escape and it is measured shut:

```
soft:  strike rise 10%->peak p50 13.8 ms   lobe rise p50 12.6 ms   overlapping
desk:  strike rise           p50 13.8 ms   lobe rise p50  6.3 ms   lobe FASTER
```

Rise time does not separate a strike from a lobe. It is also destroyed by the
front end regardless: `SignalChain` ends in a 3-sample sliding maximum, so
measured rise from 20 % to peak reads 0.0 ms for almost every real tap.

## The honest verdict

On a **hard desk and on a soft surface**, Tunk meets the felt-reliability bar the
PRD set: zero false triggers while typing, 100 % detection on a held-out set,
latency around 200 ms. That is the Back Tap comparison holding up.

**On a lap it does not**, and the reason is physical rather than a tuning failure.
Lap coupling halves the tap while lap ambient noise reaches tap amplitude
(p99 0.0576 g against a tap median of 0.0616 g), and lap tapping spreads across a
wider interval range than a 250 ms latency budget can admit.

Closing lap needs one of:

1. ~~A latency budget above 250 ms.~~ **Measured and closed.** The window
   saturates at 280 ms and lap tops out at 77.5 % with an unlimited budget.
2. **A front end that separates a strike from a ring at the same amplitude.**
   Every mechanism tried operates on the existing envelope, and on a lap the
   second strike and the first strike's tail are the same size in that envelope.
   This is the only remaining candidate and it is research, not tuning: a new
   front end, re-tuned from scratch, re-graded on all three surfaces.
3. **Shipping lap as unsupported**, and saying so.

Ten mechanisms have now been built and independently graded — four amplitude,
three re-arm, plus threshold, debounce and window sweeps. None reached the bar
on lap. The evidence that this is structural rather than a tuning failure is no
longer one measurement; it is ten, from agents that did not see each other's
work, every one graded on data its builder could not touch.

## Coverage limits

One operator, one machine, one session per surface for soft, four for lap. No
second person has tapped this chassis. Nothing here should be read as a
population claim, and the thresholds are fitted to one pair of hands.
