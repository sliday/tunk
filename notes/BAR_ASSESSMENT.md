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

1. **A latency budget above 250 ms**, which the PRD sets and which is a product
   decision, not an engineering one. A 300 ms window recovers most of the eight
   out-of-window misses.
2. **A front end that preserves onset shape**, read before the sliding maximum,
   with a discriminator that is not rise time — spectral content is the untested
   candidate.
3. **Shipping lap as unsupported**, and saying so.

## What option 2 turned out to be worth

Measured on `data/raw` only, behind `DetectorConfig.secondTapAdmitFraction`,
which ships at 1.0 (off).

### The soft collapse was never about spurious triples

`inGestureThresholdFraction` lowered the crossing level and the **release** level
together, because the detector re-arms at `releaseFraction * threshold`. Replay
of the soft session with the in-gesture bar at 0.6 and everything else shipped:

```
              onsets lost   extra onsets
  soft            8 of 40        1
  lap             3              22
```

Soft did not gain spurious onsets. It lost real ones: the detector sat disarmed
through the second strike. That is the whole 100 % -> 55 %, and it is fixable by
leaving the hysteresis alone, which is what the admission below does.

### Shape, measured before the sliding maximum

`SignalChain.preHoldEnvelope` exposes the quadrature pair ahead of the 3-sample
peak hold. Over the 24 crossings the admission window offers at fraction 0.7 —
13 real second taps the shipped detector misses (all lap) and 11 spurious ones
(7 lap, 4 soft, 0 desk):

```
  statistic                       AUC    real p50   spurious p50   spurious p90
  crest (peak / rms, 12 samples)  0.66     1.31        1.11           1.35
  local SNR                       0.70     2.11        1.76           2.83
  spectral centroid proxy         0.62    17.19        6.68          20.65
  high-band energy ratio (150 Hz) 0.56     0.0082      0.0011         0.0156
```

**None of these separates.** The distributions overlap end to end; crest at 1.15
keeps 11 of 13 real taps and 5 of 11 spurious ones. Rise time was measured shut
before, and spectral content is now measured weak. What the crest test earns is
narrower than a discriminator: a candidate it rejects has not consumed the
100 ms debounce, so the real strike behind it can still be seen.

### End to end

Fraction 0.8, crest 1.15, one admission per gesture, only inside
`minInterTap ... maxInterTap` of a group holding exactly one onset:

```
             detection            false triggers      latency p95
  desk       95.65 % -> 95.65 %     0 -> 0            200.1 ms (unchanged)
  soft      100.00 % -> 100.00 %    0 -> 0            208.9 ms (unchanged)
  lap        73.75 % ->  82.50 %    3 -> 5            225.2 ms (unchanged)
  typing     0 false triggers on all three surfaces, unchanged
```

Lap gains 7 gestures across three of its four sessions and loses one in the
fourth; it buys them with **two extra lap false triggers**, on a surface whose
false-trigger rate already fails the bar (6.54 -> 10.90 per 20 min). It is a
detection lever, not a fix, and it does not get lap to 98 %.

## Coverage limits

One operator, one machine, one session per surface for soft, four for lap. No
second person has tapped this chassis. Nothing here should be read as a
population claim, and the thresholds are fitted to one pair of hands.
