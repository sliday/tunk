# The tail model: re-arming against a decay of the last strike

A measured negative. The mechanism is implemented, swept over ~130 settings on
`data/raw`, and **ships off**. Nothing anywhere on the grid beats the shipped
detector on any surface. What it does buy is a clean reading of why the deaf
second taps cannot be recovered on amplitude alone.

## The idea

The detector re-arms when the envelope falls back under
`releaseFraction * threshold`, an absolute line, 0.0128 g. On a damped surface
the case is still ringing above that line hundreds of milliseconds later, so the
detector is deaf when the second half of the gesture lands. Tallied over every
training tap deck, the detector never declared the second tap of 25 lap gestures
and 3 soft ones; 12 of those lap taps and all 3 soft ones were a strong strike
(1.2x to 2.0x the threshold) into a disarmed detector. Desk is never deaf.

So model the ring instead of guessing a constant:

    D(t) = peak * exp(-(t - onset) / tau)

- re-arm once the envelope drops under `tailRearmFraction * D(t)` (`m`)
- declare an onset only when it exceeds `tailOnsetFraction * D(t)` (`n`), so the
  ring cannot declare itself the instant the detector listens again

Self-scaling by construction: a loud strike grants a proportionally larger
allowance, and `tau` rather than a per-surface constant carries the difference
between a desk and a lap.

## First measurement: tau

Measured on all 123 training gestures (`TauMeasurementTests`), envelope binned at
10 ms from the first strike's peak, normalised to that peak:

    ms from peak:     0   10   20   30   40   50   60   70   80   90  100  110  120  130
    desk n=23      1.00 0.95 0.82 0.66 0.48 0.33 0.21 0.12 0.09 0.04 0.03 0.03 0.02 0.03
    lap  n=80      1.00 0.54 0.33 0.33 0.32 0.32 0.37 0.38 0.33 0.28 0.24 0.22 0.24 0.26
    soft n=20      1.00 0.74 0.68 0.49 0.54 0.49 0.39 0.23 0.23 0.29 0.28 0.30 0.29 0.26

Per-gesture exponential fits past +40 ms:

    surface  n   no decay at all   tau p10   median    p90     R2 median
    desk     23      11 / 23         94 ms   425 ms   5000 ms     0.01
    lap      77      22 / 77        154 ms   381 ms   3381 ms     0.14
    soft     20      13 / 20        200 ms   254 ms    293 ms     0.14

**A single tau cannot serve, and neither can a per-surface one.** Median R2 of
0.01–0.14 says the model is not describing the signal at all, and roughly a third
of gestures show no decay whatsoever over the span that matters. Only the desk
looks like a ring-down (down to 3 % of its peak by 90 ms). On a lap the envelope
drops to a third within 20 ms and then **plateaus** at 0.22–0.38 of the strike
peak for the rest of the gesture: that is the surface itself, not the ring, and
an exponential has nothing to say about it.

Read `tailDecayTauNs` as a tunable allowance curve, not as fitted physics.

## Second measurement: the bound

For every gesture, the loudest excursion the envelope makes between the 100 ms
debounce and 20 ms before the second strike, against the second strike itself,
both as a fraction of the first strike's peak:

    surface  n    tail p50  tail p90   2nd p50  2nd p10   2nd louder than the tail
    desk     23     0.51      0.63       0.79     0.70        23/23  (100 %)
    lap      77     0.32      0.98       0.89     0.66        70/77  ( 91 %)
    soft     20     0.53      1.44       1.07     0.79        13/20  ( 65 %)

This is the ceiling on any rule of the form "an onset must beat what the previous
strike's tail could still be producing". On soft, the tail is **louder than the
second strike in 7 of 20 gestures**. There is no constant `n` that admits a
second strike at the 10th percentile (0.66 of the peak on lap, 0.79 on soft) and
rejects a tail at the 90th (0.98 on lap, 1.44 on soft). The two distributions
overlap. Rise time hit the same wall earlier in this project: a ring lobe and a
fresh strike are not separable by height either.

## What the mechanism actually does

`TailModelDiagnosisTests`, deaf/weak split beside the number of ungated onsets
each labelled gesture ends up with:

    setting                      lap DEAF   soft DEAF   gestures with >=3 onsets
    OFF (shipped)                   12          3            0 lap,  0 soft
    m 0.5, n 0,   tau 0 (flat)       9          1            6 lap,  5 soft
    m 1.0, n 0,   tau 250 ms         6          1            7 lap,  5 soft
    m 2.0, n 0,   tau 150 ms         2          0            8 lap,  6 soft

**Deafness is curable and the cure is not worth having.** At `m = 2.0` the
detector hears every soft second tap and all but two lap ones, and turns 14
clean doubles into three-onset groups, which fire nothing. Every deaf tap
recovered costs roughly one gesture that used to work.

## Sweep, `data/raw`, `bin/tunk-score run`

Baseline: desk 95.65 % (22/23), soft 100 % (20/20), lap 73.75 % (59/80),
3 lap false triggers, 0 while typing, p95 225.2 ms.

    tau     m     n      desk      soft      lap       lap FP   pooled
    off (shipped)       95.65 %   100.00 %   73.75 %     3      82.11 %
    150   0.2–0.4  0    95.65 %   100.00 %   73.75 %     3      82.11 %   (inert)
    150   0.5     0     95.65 %   100.00 %   72.50 %     4      81.30 %
    150   0.6     0     95.65 %    90.00 %   71.25 %     4      78.86 %
    150   1.0     0     95.65 %    60.00 %   68.75 %     2      72.36 %
    150   2.0     0     95.65 %    40.00 %   61.25 %     0      64.23 %  (1 desk FP)
      0   0.5     0     95.65 %    55.00 %   70.00 %     2      72.36 %
      0   0.5    0.5    95.65 %    65.00 %   70.00 %     2      73.98 %
      0   0.5    1.0     4.35 %     5.00 %    2.50 %     1       3.25 %
    250   1.0    1.2    95.65 %    80.00 %   68.75 %     0      75.61 %
    250   1.0    1.5    95.65 %    80.00 %   70.00 %     0      76.42 %
    400   1.0    1.5    86.96 %    80.00 %   35.00 %     0      52.03 %

Full grids: 48 points over (tau 0/150/250/400) x (m 0.5/1/2) x (n 0/0.3/0.5/0.7),
36 over (tau 60–200) x (m 0.2–0.8), 40 over (tau 60–400) x (m 1/2) x (n 0.8–1.5).
**No setting improves detection on any surface.** Desk never moves at all, its
ring is gone by 90 ms, so no allowance changes anything. Every setting that
re-arms early enough to matter costs soft first and lap second, in the same
direction and for the same reason as every amplitude lever before it.

Typing false triggers stay at **0 across every setting swept**, which is the one
piece of good news: the mechanism only ever fires inside 250 ms of an onset the
full bar already accepted, and a keystroke gate kills those.

## The one thing it is good at

`tau 250 ms, m 1.0, n 1.2` removes **all three lap false triggers** (6.54 → 0.00
per 20 min, pooled 1.22 → 0.00) because the onset guard rejects tail excursions
that used to pair into phantom doubles. It costs 8 gestures pooled (lap 73.75 →
68.75 %, soft 100 → 80 %). Not shipped, lap detection is already the worst
number on the board, but if false triggers ever become the binding constraint on
a live surface, this is a lever that exists and is measured.

## Status

`tailRearmFraction` defaults to 0, which disables the whole mechanism.
`TailModelTests` proves byte-identical output against the shipped detector on
every recorded tap session and on synthetic gestures, with the other two knobs
set to loud values. Turning it on is one config key.
