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
2. ~~A front end that separates a strike from a ring at the same amplitude.~~
   **Attempted and measured shut**, see the matched-filter section below. A
   causal correlator against a strike template with the ring projected out cures
   the deafness outright (the signal falls back between the strikes in 80/80 lap
   gestures) and still loses: pooled detection 82.11 % to 62.60 %, because
   re-arming and hearing the ripple are the same act.
3. **Shipping lap as unsupported**, and saying so.

Ten mechanisms have now been built and independently graded — four amplitude,
three re-arm, plus threshold, debounce and window sweeps. None reached the bar
on lap. The evidence that this is structural rather than a tuning failure is no
longer one measurement; it is ten, from agents that did not see each other's
work, every one graded on data its builder could not touch.

## Matched filter: the ring projected out of the front end, and measured shut

Candidate 2 above asked for a front end that separates a strike from a ring at
the same amplitude. This is the first mechanism to attack the ring itself rather
than threshold around it, and it does not reach the bar. Both knobs ship at 0.

### What was built

Two 20-sample (25 ms) templates, on the high-passed vector magnitude, each window
normalised to unit length before averaging so a loud tap cannot dominate a quiet
one, pooled across all seven `data/raw` tap decks:

- a STRIKE template, centred on the peak of every `index_in_group == 0` onset.
  First strikes are unambiguous: nothing precedes them, so there is no ring
  underneath.
- a RING template, centred on the second lobe of those same first strikes, at
  +26.4 ms, where the damped chassis puts it.

The two templates correlate at **0.874**, which is the whole problem written as
one number. What runs is the strike template with the ring component projected
out and renormalised, correlated causally against the live signal, so the filter
answers "how much of the last 25 ms looks like a fresh impulse, after removing
whatever a decaying ring would explain". It is unnormalised, so its output stays
in g, and a fixed gain (0.9752, the median ratio of envelope peak to filter peak
over 123 first strikes) keeps the shipped 0.032 g bar meaning the same thing.

Leave-one-session-out cosine against the pooled template is 0.98 or better on
every session, so no single recording invents it. Per-surface templates do
differ (desk cosine 0.75, soft 0.78, lap 0.97), and the pooled template is
therefore mostly lap's, but the surface is not detectable at runtime so a
per-surface template cannot ship anyway.

### Measure first: the offline separation

123 labelled second strikes against 671 ring lobes (local envelope maxima 30 to
250 ms after a first strike, at least 40 ms from any label). At a bar admitting
the same number of ring lobes as the shipped envelope bar admits:

| statistic | 2nd strikes admitted | lap | of the 13 under-bar lap strikes |
|---|---|---|---|
| envelope (shipped) | 110/123 | 67/80 | 0/13 |
| plain matched filter | 84/123 | 41/80 | 0/13 |
| normalised cross-correlation | 51/123 | 48/80 (desk **0/23**) | 12/13 |
| **ring-projected, unnormalised** | **120/123** | **77/80** | 10/13 |

**Normalising by local energy divides out the very ring the filter exists to see
past.** Amplitude-matched on lap the NCC scores AUC 0.565 against the envelope's
0.842, and on desk it admits nothing at all. That row is the reason the shipped
statistic is unnormalised. The two-template forms (ring projected out, and a
strike-minus-ring likelihood ratio) both reach lap AUC 0.88 amplitude-matched
against the envelope's 0.84.

The deafness test looked decisive. Per lap gesture, does the signal fall back
under `releaseFraction * threshold` between the two strikes, so the detector
could re-arm?

```
                    falls back    falls back AND clears the bar at the 2nd strike
ring-projected MF   80/80         62/80
envelope            (65/80 by the same test)
```

Deafness is cured outright: the ring-suppressed signal falls back in **every**
lap gesture. That is the measurement that justified building it.

### What the harness said

`matchedFilterWeight` mixes the filter into the envelope; 1.0 replaces it.
`data/raw`, threshold unchanged:

| weight | pooled | desk | soft | lap | typing FP | FP/20min | p95 |
|---|---|---|---|---|---|---|---|
| 0 (ships) | 82.11 % | 95.65 % | 100 % | 73.75 % | 0 | 1.22 | 225.2 ms |
| 0.2 | 69.92 % | | | | 0 | 1.22 | 225.2 ms |
| 0.4 | 65.85 % | | | | 0 | 0.41 | 225.2 ms |
| 0.6 | 62.60 % | | | | 0 | 0.00 | 226.4 ms |
| 0.8 | 63.41 % | | | | 0 | 0.00 | 226.4 ms |
| 1.0 | 62.60 % | 95.65 % | 60.00 % | 53.75 % | 0 | 0.00 | 225.2 ms |

Re-sweeping the threshold on the new front end does not rescue it: the best
value is 0.024, at 69.92 % pooled, still twelve points under baseline. Every
swept value held typing false triggers at zero.

**Why it fails is the interesting part, and it is the same wall as before.**
Replacing the envelope also replaces its hysteresis. The ring-suppressed signal
collapses between lobes, the detector re-arms, and every later lobe that still
clears the bar becomes its own onset: the soft session went from 40 declared
onsets to 48, and the extra ones sit 109 to 138 ms after a real strike, inside
the join window, turning doubles into ungrouped triples. Curing deafness and
hearing the ripple are the same act, measured for the eighth time.

The offline table above missed this because it scored the statistic at candidate
positions without simulating the arm state. A statistic that admits fewer ring
lobes in absolute terms can still produce more onsets, if it is armed when they
arrive. Any future front-end measurement has to include the arm state.

### The additive path, also measured shut

Since replacing the envelope loses its hysteresis, the second attempt keeps the
envelope path byte-identical and adds one thing: while the detector is disarmed
and past the onset debounce, a matched-filter score over `matchedFilterAdmitG`
declares an onset anyway. This is the brief's "run the correlator continuously as
a detection statistic in its own right".

| bar (g) | pooled | lap | triggers | FP | typing FP |
|---|---|---|---|---|---|
| 0.02 | 60.16 % | | 74 | 0 | 0 |
| 0.03 | 67.48 % | | 83 | 0 | 0 |
| 0.04 | 72.36 % | | 89 | 0 | 0 |
| 0.05 | 75.61 % | | 93 | 0 | 0 |
| 0.06 | 78.05 % | | 98 | 2 | 0 |
| 0.07 | 80.49 % | 71.25 % | 103 | 4 | 0 |
| 0.09 and up | 82.11 % | 73.75 % | 104 | 3 | 0 |

It is monotone in the wrong direction and converges to baseline only when the
bar is above every score the filter ever produces, which is the same as being
off. **Recovery: zero gestures, at any bar.**

The reason is visible offline. Restricted to the band where an extra onset is
even possible (at least 100 ms after the previous onset, inside the join window),
a bar of 0.036 g admits 0 of the 13 lap second strikes that sit under the
envelope bar, and the bar that admits 11 of them (0.024 g) also admits 45 ring
lobes. **A second strike that is weak in the envelope is weak in the matched
filter too**, because both are linear in the signal. The shape gain is real and
it is small: lap AUC 0.88 against 0.84, amplitude-matched. That buys separation
between populations; it does not move a detection rate that needs 98 %.

### Per-session, and the strict rate

| session | off | weight 1.0 | admit 0.07 |
|---|---|---|---|
| desk 090700 | 2/3 (strict 2) | 2/3 (2) | 2/3 (2) |
| desk 090935 | 20/20 (20) | 20/20 (20) | 20/20 (20) |
| lap 104745 | 14/20 (strict 8) FT 3 | **4/20** (4) FT 0 | 12/20 (7) FT 3 |
| lap 110347 | 16/20 (16) | 15/20 (15) | 16/20 (16) |
| lap 110809 | 15/20 (15) | 11/20 (11) | 15/20 (15) |
| lap 111032 | 14/20 (14) | 13/20 (13) | 14/20 (14) |
| soft 104124 | 20/20 (strict 19) | 12/20 (12) | 20/20 (19) |

Pooled strict detection goes 76.42 % to 62.60 % at weight 1.0 and to 75.61 % at
admit 0.07. Nothing here lifts the contract rate while the strict rate stays
flat, because nothing here lifts the contract rate at all.

Two things did improve, and neither is worth the trade. At weight 1.0 the false
triggers go 3 to 0 and the loose credits go 7 to 0: the ring suppression works
exactly as designed on the false side. The hand-on-chassis session (`lap
104745`, the posture outlier) is where both effects live. Its baseline 14/20 is
only 8/20 strict, so six of its credits were landing on ring lobes; weight 1.0
removes those and lands at 4/20. Even read strictly, it is worse.

### Cost

0.333 us/sample with the front end off, 2.280 us/sample with the 20-tap
correlation running. At 796 Hz that is **0.18 % of one core**, so cost is not
what rules this out. Held by `MatchedFilterTests.testPerSampleCostIsReported`.

### What ships

Nothing. `matchedFilterWeight` and `matchedFilterAdmitG` both default to 0, the
filter is not evaluated while they are, and `run --json` output with the knobs
off is byte-identical to the run before this round (checked field by field, only
`generatedAt` and the two new config keys differ).
`MatchedFilterTests.testOffReproducesTheEnvelopeBitForBit` compares the envelope
against a chain rewritten from its own documentation, sample by sample, on the
`bitPattern`.

Fifteen mechanisms, fifteen measured negatives on lap.

## Coverage limits

One operator, one machine, one session per surface for soft, four for lap. No
second person has tapped this chassis. Nothing here should be read as a
population claim, and the thresholds are fitted to one pair of hands.
