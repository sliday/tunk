# A second-tap bar that scales with the first tap

`DetectorConfig.secondTapBarFraction`. Ships at 0, which is off; every number
below comes from `./bin/tunk-score run --data data/raw` on the 14 training
sessions (49.1 min, 123 labelled gestures). Nothing here has been scored against
`data/holdout`.

## The gap

Three of the four held-out lap misses are a second strike that was never
declared: one ungated onset, and a 2-tap needs two. Lowering the global
threshold recovers those and destroys soft (100 % to 70 % at 0.024). Lowering
the bar by a fixed factor once a gesture is in flight —
`DSPTuning.inGestureThresholdFraction`, already measured — recovers 1.3 lap
points and takes soft from 100 % to 55 %, because a damped chassis rings at 80 %
of its own peak and the ring crosses the reduced bar.

Both levers fail for the same reason: they are one number for three surfaces,
and lap first taps are about six times weaker than desk first taps.

## The mechanism

After a first onset of measured peak `S`, a later onset inside the join window
faces

    max(adaptive floor, min(shipped threshold, k * S))

instead of the shipped threshold. `k = 0` is off. The adaptive floor is the
existing `max(noiseSnrMultiple * noiseFloor, minThresholdG)`; the `min` keeps the
bar from ever being stricter than what ships today.

The premise is measured, not assumed: a second tap runs a median 0.85 (desk),
0.86 (soft), 0.95 (lap) of its first, and that ratio travels across surfaces
while amplitude does not.

Only the crossing scales. The re-arm hysteresis still uses the unmodified
threshold, so a lowered bar cannot re-arm the detector part-way down a ring.

## The curve

Detection rate per surface, false triggers, latency p95, at each `k`:

    k        desk      soft      lap       lap FP   pooled FP/20min  p95
    0 (off)  95.65 %   100.00 %  73.75 %   3        1.22             225.2 ms
    0.40     95.65 %    95.00 %  70.00 %   4        1.63             221.4 ms
    0.50     95.65 %    95.00 %  77.50 %   3        1.22             223.9 ms
    0.55     95.65 %   100.00 %  76.25 %   4        1.63             223.9 ms
    0.60     95.65 %   100.00 %  80.00 %   5        2.04             225.2 ms
    0.65     95.65 %   100.00 %  82.50 %   4        1.63             225.2 ms
    0.66     95.65 %   100.00 %  83.75 %   4        1.63             225.2 ms
    0.70     95.65 %   100.00 %  80.00 %   4        1.63             225.2 ms
    0.75     95.65 %   100.00 %  78.75 %   4        1.63             225.2 ms
    0.80     95.65 %   100.00 %  77.50 %   4        1.63             225.2 ms

Zero false triggers while typing at every `k` in the table, on all three
surfaces, across 11.7 minutes of typing. That is the make-or-break metric and
the mechanism does not touch it: the bar only comes down inside the join window
of an onset that already cleared the full bar, and the typing gate kills those
onsets before they can open one.

`k = 0.65` is the recommendation. 0.66 measures one gesture better and its
neighbours measure two worse; the plateau from 0.55 to 0.80 is the result, not
any single value inside it.

**At `k = 0.65`: lap 73.75 % to 82.50 %, desk unchanged, soft unchanged, latency
p95 unchanged on desk and soft, and one more lap false trigger (3 to 4, 6.54 to
8.72 per 20 min).** Lap already fails that bar; it now fails it by more.

## Is it adapting, or is it a constant?

The bar each gesture actually imposed, at `k = 0.65`, over every onset that
headed a gesture in a tap session:

    surface  gestures  bar < 0.032  bar = 0.032  median bar  min bar
    desk     24        0            24           0.0320      0.0320
    soft     20        6            14           0.0320      0.0237
    lap      90        62           28           0.0284      0.0211

On a desk the mechanism is inert — every desk gesture is loud enough that
`0.65 * S` lands above the shipped threshold and the clamp pins the bar at
0.032. On a lap it moves on 62 of 90 gestures, down to 0.0211 g at the extreme.
Soft sits between, moving on 6 of 20 and never below 0.0237.

That is the whole point. The same constant `k` is a no-op where the surface is
loud and a 34 % reduction where it is quiet, without anything having to detect
the surface — which the noise floor cannot do (desk 0.00011, soft 0.00014, lap
0.00012).

## What the raise side costs

The mechanism was first built without the `min(shipped threshold, ...)` clamp,
so a loud first tap raised the bar against its own second tap and rejected
ring-down by construction. Measured, that costs and buys nothing:

    form                      desk      soft      lap       lap FP
    raise and lower (k=0.62)  95.65 %   100.00 %  78.75 %   4
    lower only      (k=0.65)  95.65 %   100.00 %  82.50 %   4

Ring rejection is already done by the 100 ms onset debounce, so the rise side
only rejects real second taps that came in under 65 % of their first. Dropped.

## Where the lap gain comes from, and where it does not

Per lap session, gestures detected out of 20, off then `k = 0.65`:

    13e15a   14 -> 12   (-2, and 3 false triggers either way)
    ad3fd3   16 -> 19   (+3, and 1 new false trigger)
    3fee5b   15 -> 16   (+1)
    a4a257   14 -> 19   (+5)

Three sessions gain, one loses. A lower bar can lose a gesture: the extra onset
it admits can be a ring lobe past the debounce, which turns a double into a
triple, and nothing is bound to three. That is the same failure that killed the
fixed reduction, showing up here at a rate the proportional bar can survive
rather than one that swamps it.

So this is not a uniform improvement to lap detection. It is a net +7 gestures
across four sessions from one operator, with a -2 inside it, and it is one
operator's hands on one chassis.

## Why it ships off

- The gain is train-set only, and it is fitted on the same four lap sessions it
  is measured on. The honest estimate is on `data/holdout`, which this work has
  not touched and must not.
- It makes lap false triggers worse on a surface that already fails that bar.
- One of four lap sessions regresses.

Turning it on is a product call that needs the held-out number first. The knob
exists so that call can be made without another detector change.
