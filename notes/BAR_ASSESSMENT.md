# Where Tunk stands against the bar

Measured on 163 prompted double-taps, 8.4 minutes of continuous typing and
49 minutes of ambient and confound recordings, across three surfaces, on one
operator and one machine. Every number here comes from `tunk-score` over real
recordings; nothing is synthetic.

The PRD asks that a target proved physically unreachable be reported **with the
data, not quietly relaxed**. This is that report.

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

## Group pruning: ranking instead of gating, built and rejected

The reading above says the information was there and nothing was choosing: a
re-arm mechanism heard real second taps, the ripple pushed the group past two,
and the grouper fires on exactly two. So the twelfth mechanism changes nothing
about onset admission. At the confirm deadline, when a group holds more onsets
than any armed count, it ranks the candidates, keeps the first plus the best of
the rest, and fires the pruned group. It is behind `groupPruneRanker`, which
defaults to 0 (off), and `GroupPruneTests` proves off is byte-identical.

Ranking is a weaker requirement than gating, and the confirm window has already
elapsed, so selection costs no latency. Both of those hold. The mechanism still
fails, for a reason that has nothing to do with the statistic:

**The shipped detector produces one prunable group in the entire training
corpus.** Arm 2 and 3 together and the whole of `data/raw` reports a single
3-onset group, in one lap session. There is nothing to choose between, because
the deafness the last round measured means the ripple is never heard either.

Swept over every ranker on `data/raw`, detection does not move once:

| ranker | detected | FP | FP typing |
|---|---|---|---|
| off | 101/123 | 3 | 0 |
| cos_first_xy | 101/123 | 3 | 0 |
| crest | 101/123 | 4 | 0 |
| crest inverted | 101/123 | 3 | 0 |
| decay residual | 101/123 | 4 | 0 |
| combined | 101/123 | 4 | 0 |
| keep-the-latest (control) | 101/123 | 3 | 0 |
| keep-the-strongest (control) | 101/123 | 3 | 0 |

The one group it can act on is unwinnable. Lap session 1 holds onsets at 29.763,
29.877 and 30.029 while the labelled gesture is (29.958, 30.453), and the real
second tap at 30.435 heads the NEXT group. No ordering of those three onsets
produces a detection; the pruned pair lands 424 ms from the labelled last onset,
outside the 150 ms match window, so the only thing pruning can buy there is a
false trigger, which is exactly what three of the rankers bought.

### The ranking itself, measured against two controls

Because the harness could only offer n = 1, the ranking was measured separately,
on recorded training data, by manufacturing the condition the mechanism was
designed for: re-arm early (release 0.6, 0.75, 0.9 against the shipped 0.4) so
ripple onsets chain at the debounce period, then ask whether the ranker keeps the
candidate nearest the labelled second tap. 41 contests, every one a straight
choice between two candidates, so chance is 50 %:

| ranker | pooled | lap | soft | amplitude-matched |
|---|---|---|---|---|
| cos_first_xy | 56.1 % (23/41) | 45.5 % | 68.4 % | 52.9 % |
| crest | 24.4 % | 36.4 % | 10.5 % | 29.4 % |
| crest inverted | 75.6 % | 63.6 % | 89.5 % | 70.6 % |
| decay residual | 39.0 % | 22.7 % | 57.9 % | 35.3 % |
| combined | 39.0 % | 27.3 % | 52.6 % | 35.3 % |
| CONTROL keep-the-latest | 75.6 % | 90.9 % | 57.9 % | 70.6 % |
| CONTROL keep-the-strongest | 100 % (41/41) | 100 % | 100 % | 100 % |

Desk contributes nothing: it never produces an over-long group at any of these
re-arm levels.

`cos_first_xy`, the statistic that survived amplitude stratification and an
independent rebuild, is a coin flip here, and a ranker reading no signal at all
beats it. Crest only looks good inverted, and its inverted score matches
keep-the-latest exactly, which is what a statistic correlated with recency rather
than with strike-ness looks like.

**And the contests amplitude wins 41 out of 41 are not the contests these
statistics were measured in.** Early re-arm declares onsets on small dips, so the
ripple in this regime is much weaker than the strike, while the whole lap problem
is that a real second strike and the first strike's tail are the SAME size. So
this measurement cannot validate a shape ranker. What it does establish is
negative and solid: in the only over-long groups this corpus can produce, the
shape statistics do not rank better than chance, and there is no evidence that
adding a ranker to the confirm window recovers anything.

### What pruning costs

Two costs, both measured rather than argued.

1. **A deliberate triple becomes a double.** With triple unarmed, a 3-onset group
   fires nothing today; with pruning on it fires the double action.
   `GroupPruneTests.testATripleBecomesADoubleWhenPruningIsOn` holds that as a
   fact, and pruning stands down when the user has actually bound triple.
2. **A false trigger per prunable group that is not a gesture.** Lap FP went 3 to
   4 on the shipped config for three of the five rankers.

What it does not cost: **zero typing false triggers and zero confound false
triggers in every configuration measured**, which is the property the mechanism
was picked for. Pruning cannot admit an onset, so it cannot fire in quiet. It can
only ever turn a group the detector already had into a shorter one.

A guard is worth recording, since it decides half the numbers above. Dropping a
middle onset can leave a pair wider than `maxInterTapNs`, which fires on a gesture
the grouper would have refused, i.e. a silent widening of the join window.
`groupPruneRequireSpacing` defaults to true and refuses those, and with it on
`cos_first_xy` changes nothing at all rather than buying a false trigger.

### Where it would pay, and why that is not shippable

At `defaultThreshold` 0.028, where the lower bar produces three prunable groups
instead of one, pruning with the spacing rule relaxed recovers two gestures:

| config | pooled | desk | soft | lap | FP | FP typing |
|---|---|---|---|---|---|---|
| 0.032, prune off (shipped) | 82.11 % | 95.65 % | 100 % | 73.75 % | 3 | 0 |
| 0.028, prune off | 84.55 % | 95.65 % | 85.00 % | 81.25 % | 4 | 0 |
| 0.028, prune on, spacing off | 86.18 % | 95.65 % | 85.00 % | 83.75 % | 5 | 0 |

Every ranker recovers the same two gestures, including both controls, so the
recovery is the pruning and not the statistic. And it is bought on top of a
threshold that has already cost soft 100 % to 85 %, with the false-trigger rate
going the wrong way. On the shipped threshold the same setting recovers nothing.

**Verdict: do not ship.** Not because ranking inside the confirm window is a bad
idea (it costs nothing and it is the right shape of question), but because this
detector does not produce the groups it would act on. Pruning is a fix for the
failure mode a WORKING re-arm mechanism would create. Nothing in eleven previous
rounds produced one, so this is a fix waiting on a cure that does not exist. If a
future front end starts hearing second strikes on a lap, the knob is here, it is
measured, and it is off.

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

## Root cause: the sensor is band-limited near 50 Hz

This is the finding that explains all eleven failed mechanisms, and it was found
by accident while measuring whether spectral content could separate a strike
from a ring.

Power spectral density of the raw z axis, no filtering applied, six windows of
512 samples from a desk tap deck:

```
sample rate 799.6 Hz, Nyquist 399.8 Hz

    0- 25 Hz : 99.9841 %
   25- 50 Hz :  0.0127 %
   50-100 Hz :  0.0032 %
  100-150 Hz :  0.0000 %   (6.4e-10)
  150-200 Hz :  0.0000 %   (1.1e-11)
  200-398 Hz :  0.0000 %   (1.4e-11)
```

The stream reports at 796 Hz and carries nothing above about 50 Hz. Content
above 100 Hz sits nine to ten orders of magnitude down, at numerical noise.

It is not naive upsampling: consecutive samples are identical 0.0 % of the time
(7 of 69,567), so the ADC really is producing distinct values at 796 Hz. The
part has an internal filter, which is the normal configuration for a MEMS
accelerometer intended for orientation and motion rather than vibration.

### Why this explains everything

A knuckle striking aluminium is broadband to several kHz. The energy that makes
an impulse *look* like an impulse — and therefore distinguishable from the
chassis resonance that follows it — is removed before the data reaches us. What
arrives is the low-frequency rigid-body response, and a strike and its own ring
produce the same shape there.

Every consequence already measured follows from this one fact:

- **Rise time could not separate them** (13.8 ms vs 12.6 ms). A 50 Hz-limited
  signal cannot rise faster than about 10 ms. That measurement was of the
  filter, not of the taps.
- **Spectral flatness ran backwards** on lap (AUC 0.173, strikes more *tonal*)
  and the band ratio above 200 Hz had an empty numerator. There is no broadband
  part left to find.
- **The best spectral statistic was a 25 Hz versus 50 Hz bin ratio in a
  two-live-bin spectrum**, which is why it inverted between surfaces.
- **Ring lobes sit at crest factor 1.41** — exactly the sinusoid value — while
  strikes reach 1.78. The ring hypothesis is right; there is simply not enough
  bandwidth left to act on it reliably.

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

Group pruning (above) is the one mechanism that attacked the *selection* problem
rather than the detection problem. It recovered nothing for a new reason: the
detector never produces the over-long groups it exists to rescue.

## Coverage limits

One operator, one machine, one session per surface for soft, four for lap. No
second person has tapped this chassis. Nothing here should be read as a
population claim, and the thresholds are fitted to one pair of hands.
