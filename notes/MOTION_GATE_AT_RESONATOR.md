# Round 26: the motion gate, re-measured at the resonator operating point

**Negative.** The gate removes one of the six lap false triggers for free and
cannot touch the other five, because five of the six do not look like a moving
chassis. Nothing shipped, nothing changed, `motionGateG` still defaults to 0.

Every number here comes from `tunk-score` over `data/raw`. Nothing was measured
against `data/holdout`, and `data/holdout` could not price this anyway — it
carries 1.5 minutes of lap tap decks and no typing, idle or confound sessions,
so a false-trigger change is invisible there. Train is the only place the cost
shows.

Operating point throughout:

    {"resonatorHz":40,"resonatorQ":2,"defaultThreshold":0.011,"minThresholdG":0.002}

## Why it was worth re-measuring

`DetectorConfig.motionGateG` was built for a reported failure — "I moved my
laptop and it counted as a tap" — and shelved at 0.030 because it separated
synthetic lifts while costing a loud surface four of ten deliberate doubles.
Two things changed since. The resonator moved the whole amplitude scale
(`defaultThreshold` 0.032 -> 0.011). And four of the six lap false triggers the
resonator leaves sit 0.5 to 5.3 s from any labelled tap, which is what the
operator shifting the machine between prompted taps would look like.

One correction before the numbers, because it decides how to read them:
**`bulkMotion` is computed from the RAW magnitude**, upstream of the high pass
and therefore upstream of the resonator (`SignalChain.process` takes the
magnitude first, "the bulk-motion tracker must see gravity"). The new operating
point did not rescale the statistic by so much as a percent. What changed is
only which onsets reach the gate.

## Measure first: the sweep

`tunk-score sweep --param motionGateG`, `data/raw`, 14 sessions, per surface:

| motionGateG | desk det | soft det | lap det | lap strict | lap FP | lap FP/20min | typing FP | confound FP | idle FP | lap p95 |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 (off) | 95.65 % (22/23) | 100.00 % (20/20) | 91.25 % (73/80) | 82.50 % | 6 | 13.08 | 0 | 0 | 0 | 226.5 ms |
| 0.005 | 69.57 % (16/23) | 25.00 % (5/20) | 30.00 % (24/80) | 27.50 % | 1 | 2.18 | 0 | 0 | 0 | 227.7 ms |
| 0.010 | 91.30 % (21/23) | 50.00 % (10/20) | 76.25 % (61/80) | 67.50 % | 4 | 8.72 | 0 | 0 | 0 | 226.5 ms |
| 0.014 | 95.65 % (22/23) | 80.00 % (16/20) | 90.00 % (72/80) | 81.25 % | 4 | 8.72 | 0 | 0 | 0 | 226.5 ms |
| 0.016 | 95.65 % (22/23) | 90.00 % (18/20) | 90.00 % (72/80) | 81.25 % | 5 | 10.90 | 0 | 0 | 0 | 226.5 ms |
| **0.021** | 95.65 % (22/23) | 100.00 % (20/20) | **91.25 % (73/80)** | **82.50 %** | **5** | **10.90** | 0 | 0 | 0 | 226.5 ms |
| 0.025 | 95.65 % (22/23) | 100.00 % (20/20) | 91.25 % (73/80) | 82.50 % | 5 | 10.90 | 0 | 0 | 0 | 226.5 ms |
| 0.030 | 95.65 % (22/23) | 100.00 % (20/20) | 91.25 % (73/80) | 82.50 % | 6 | 13.08 | 0 | 0 | 0 | 226.5 ms |

**Typing false triggers are 0 at every swept value, not only at the best one.**
The sweep ran 0.001 to 0.030 in 0.001 g steps, 30 values, and its typing and
confound columns read 0 at all thirty. Idle is not a sweep column, so it was
checked session by session at the eight values in the table above, including
0.005, where detection has collapsed to 30 % on lap and 25 % on soft and every
non-tap session is still clean. The gate can only suppress onsets, so this is
what should happen; it was checked rather than argued.

Per session, because posture is a hidden variable. Only one session moves at
0.021 — the hand-resting deck — and only its false-trigger column:

| session | gate off | gate 0.021 | gate 0.014 |
|---|---|---|---|
| desk 8f0079 | 2/3, 0 FP | 2/3, 0 FP | 2/3, 0 FP |
| desk 5f07e8 | 20/20, 0 FP | 20/20, 0 FP | 20/20, 0 FP |
| soft fe9b8c | 20/20, 0 FP | 20/20, 0 FP | **16/20**, 0 FP |
| lap 13e15a (hand resting) | 16/20 (strict 50 %), **4 FP** | 16/20 (strict 50 %), **3 FP** | 16/20, 2 FP |
| lap ad3fd3 | 19/20, 1 FP | 19/20, 1 FP | 19/20, 1 FP |
| lap 3fee5b | 18/20, 1 FP | 18/20, 1 FP | 18/20, 1 FP |
| lap a4a257 | 20/20, 0 FP | 20/20, 0 FP | **19/20**, 0 FP |

So the whole free effect is **one trigger, in one session**: 13e15a at 58.860 s.
The second one costs four soft gestures and one lap gesture.

## Why it cannot do better

`bulkMotion` at the onsets of every lap trigger, taking the larger of the two
(the gate fires at each crossing and either one kills the group):

    real detections   n=73   p05 0.00184  p25 0.00344  p50 0.00541  p95 0.01059  max 0.01528
    false triggers    n= 6        0.00605  0.00632  0.00733  0.00755  0.01083  0.03637

Five of the six sit between the real p60 and the real p96. Only 0.03637 clears
the distribution, and that is the trigger 0.021 removes. Per session, with the
false triggers listed individually:

| session | real p05 | real p50 | real p95 | its false triggers |
|---|---|---|---|---|
| 13e15a | 0.00297 | 0.00697 | 0.01355 | 0.00632, 0.00733, 0.01083, 0.03637 |
| 3fee5b | 0.00139 | 0.00406 | 0.00908 | 0.00755 |
| a4a257 | 0.00223 | 0.00527 | 0.01094 | — |
| ad3fd3 | 0.00185 | 0.00541 | 0.00825 | 0.00605 |

Three of the five overlapping ones sit BELOW their own session's median real
tap, so normalising per session makes the separation worse, not better.

Seven other causal readings of the same statistic were tried before giving up on
it, in case the instant of the crossing was simply the wrong place to sample.
Every one of them was asked the same question: at the gate value that kills the
most false triggers while costing zero real ones, how many of the six die?

| reading of `bulkMotion` | at 0 real lost | at 1 real lost |
|---|---|---|
| instantaneous at the crossing (the shipped gate) | 1 / 6 | 1 / 6 |
| change across the two onsets of the group | 1 / 6 | 1 / 6 |
| ratio between the two onsets | 0 / 6 | 2 / 6 |
| max over the 300 ms before the first onset | 0 / 6 | 1 / 6 |
| max between the two onsets | 0 / 6 | 1 / 6 |
| max over the confirm window | 1 / 6 | 1 / 6 |
| max over all three windows | 1 / 6 | 1 / 6 |
| range between the two onsets | 0 / 6 | 1 / 6 |

Nothing reaches two for free, and the one it does reach is the same event every
time.

**The physical reading.** `bulkMotion` compares a 6 Hz low pass of |a| against a
0.3 Hz one, so it answers "has the resting attitude moved and stayed moved" — a
lift, a lid, setting the machine down. Five of these six false triggers do not
do that. The hypothesis in the brief was that they were the operator shifting
the machine between prompted taps; the gravity vector says otherwise. A hand
being placed on the chassis, or a knee moving under it, rings the case without
swinging the attitude, and that is what the data looks like. The gate is not
mis-tuned for these events. It is measuring the wrong thing.

## The onset ceiling, also re-measured

Named in the brief as the other guard never re-priced at the new operating
point. `onsetCeilingG` ships at 2.5 g and rejects a strike harder than a finger;
after the resonator, lap onsets publish 0.011-0.024, so 2.5 is inert by three
orders of magnitude. Swept down into the live range:

| onsetCeilingG | pooled det | FP | typing FP |
|---|---|---|---|
| 0.015 | 12.20 % (15/123) | 1 | 0 |
| 0.020 | 46.34 % (57/123) | 4 | 0 |
| 0.025 | 64.23 % (79/123) | 6 | 0 |
| 0.030 | 78.05 % (96/123) | 6 | 0 |
| 0.035 | 90.24 % (111/123) | 6 | 0 |
| 0.040 | 91.06 % (112/123) | 6 | 0 |
| 0.045 | 92.68 % (114/123) | 6 | 0 |
| 0.050 | 93.50 % (115/123) | 6 | 0 |
| 0.055 | 93.50 % (115/123) | 6 | 0 |

Strictly dominated, and worse than the minimum-score gate already recorded as
shut. By 0.025 it has destroyed 36 detections and **all six false triggers are
still there**. As a ceiling it can only bite the loudest onsets, and the false
triggers are not the loudest: they sit between the detections' p05 and p50 by
score. Closed.

## What this leaves

- Lap false triggers stay at 6 in 9.2 minutes, 13.08 per 20 min, against a bar
  of under 1. The resonator's detection gain (73.75 -> 91.25 %) is intact and
  untouched by anything here.
- 0.021 to 0.025 is a real free window — one trigger, no detection cost on any
  surface, no typing/confound/idle cost — and it is **not proposed for shipping**.
  It is one event on training data in the session that behaves unlike the other
  three, and the default has to stay 0 until something prices it out of sample.
- The next thing to try is not another statistic on this envelope. Five of these
  six events are chassis excitation with an unchanged resting attitude at
  plausible double-tap timing, which is what a real double tap also is. Telling
  them apart needs either a discriminator the 50 Hz sensor ceiling still allows,
  or a recording of the operator deliberately producing them, which does not
  exist in the corpus.

`MotionGateAtResonatorTests` holds all of this: the free removal at 0.021, the
loss at every lower value, and the distribution overlap. Nobody has to re-derive
the sweep.
