# Round 26: do the two taps of a gesture resemble each other? No.

Every number here comes from `tunk-score` over `data/raw`, or from a replay of
`data/raw` through a numpy copy of `SignalChain` that reproduces the harness's
own trigger scores to a median of 0.0000 % and a p95 of 3.7 %. **Nothing here
was measured against `data/holdout`**, and `data/holdout` could not price this
change anyway: it holds 1.5 minutes of lap and no typing, idle or confound
sessions, so it has no false-trigger denominator worth quoting.

Front end throughout: `resonatorHz 40, resonatorQ 2, defaultThreshold 0.011,
minThresholdG 0.002` — the resonator operating point from
`notes/FRONT_END_RING.md`. On `data/raw` that scores lap 91.25 % (73/80) with
6 false triggers, 13.08 per 20 min against a bar of < 1.

## The brief

A real double-tap is one motor action repeated: two strikes of similar strength,
similar shape, similar direction. Two unrelated bumps from a shifting laptop
have no reason to match. The detector never asks, and the question needs no
absolute threshold — it is a within-gesture comparison, so surface, posture and
amplitude scale all cancel. That is what made it worth measuring after every
absolute statistic had already failed.

## Measure first

73 real lap detections against the 6 lap false triggers, at the operating point.
Strength ratio is `weakest / strongest` of the two onset peaks; the cosines are
between the two onsets' lateral (x, y) high-passed directions, taken at three
different sampling points; shape is the Pearson correlation of the two envelope
neighbourhoods (-7.5 to +33 ms around each crossing).

| statistic | det min | p05 | p25 | p50 | p75 | the six false triggers, sorted |
|---|---|---|---|---|---|---|
| strength ratio | 0.554 | 0.656 | 0.770 | 0.849 | 0.919 | 0.579 0.677 0.841 0.916 0.978 0.982 |
| cosine, at envelope peak | -0.999 | -0.651 | 0.951 | 0.981 | 0.998 | -0.616 0.870 0.952 0.958 0.990 0.997 |
| cosine, at loudest sample | -0.995 | -0.704 | 0.970 | 0.989 | 0.997 | -0.501 0.937 0.975 0.977 0.990 1.000 |
| cosine, at crossing sample | -0.997 | -0.957 | -0.097 | 0.968 | 0.996 | -0.425 0.913 0.939 0.964 1.000 1.000 |
| cosine, of the windowed integral | -0.949 | 0.359 | 0.725 | 0.925 | 0.986 | -0.579 0.848 0.931 0.975 1.000 1.000 |
| envelope-shape correlation | -0.209 | -0.018 | 0.645 | 0.835 | 0.933 | -0.137 -0.038 0.740 0.896 0.933 0.947 |

**The false triggers are not less coherent than the real taps. On strength they
are more so.** Three of the six are matched to better than 0.91, above the
detections' own p75, and five of the six agree in direction better than the
detections' p25.

What each threshold buys and costs, reject-when-below:

| statistic | removes 1/6 | removes 2/6 | removes 3/6 | removes 4/6 |
|---|---|---|---|---|
| strength ratio | costs 1/73 | costs 6/73 | costs 36/73 | — |
| cosine at envelope peak | costs 6/73 | costs 14/73 | costs 21/73 | costs 28/73 |
| cosine at loudest sample | costs 6/73 | costs 14/73 | costs 21/73 | costs 28/73 |
| envelope shape | costs 1/73 | costs 5/73 | costs 29/73 | — |

The best point on the whole family removes **two** of six at a cost of five of
73. That leaves lap at 8.7 false triggers per 20 min — still nine times the bar
— and drops lap detection from 91.25 % to about 85 %. It fails both halves of
the brief at once.

## Graded end to end, not just in the scratch script

The two tests are implemented behind `DetectorConfig.pairStrengthMinRatio` (0 =
off) and `DetectorConfig.pairDirectionMinCosine` (nil = off) so the negative can
be reproduced with one command. Swept on `data/raw` at the operating point:

| pairStrengthMinRatio | pooled det | FP | typing FP | confound FP | lap p95 |
|---|---|---|---|---|---|
| 0 (off) | 93.50 % | 6 | 0 | 0 | 226.5 ms |
| 0.5 | 93.50 % | 6 | 0 | 0 | 226.5 ms |
| 0.6 | 91.87 % | 5 | 0 | 0 | 226.4 ms |
| 0.7 | 84.55 % | 4 | 0 | 0 | 226.4 ms |
| 0.8 | 61.79 % | 4 | 0 | 0 | 226.4 ms |
| 0.9 | 30.89 % | 3 | 0 | 0 | 226.4 ms |

| pairDirectionMinCosine | pooled det | FP | typing FP | confound FP | lap p95 |
|---|---|---|---|---|---|
| off | 93.50 % | 6 | 0 | 0 | 226.5 ms |
| -0.82 | 85.37 % | 6 | 0 | 0 | 226.5 ms |
| -0.28 | 77.24 % | 5 | 0 | 0 | 226.5 ms |
| 0.44 | 76.42 % | 5 | 0 | 0 | 226.5 ms |
| 0.80 | 73.98 % | 5 | 0 | 0 | 226.5 ms |
| 0.98 | 50.41 % | 2 | 0 | 0 | 226.5 ms |

**Typing false triggers are 0 at every swept value of both knobs**, as are
confound and idle. That is not a virtue of the mechanism: a test applied at
group close can only ever suppress a trigger, and typing was already at zero.

Per surface and per session, at the three points worth naming. `strict` is the
2-tap `strictDetectionRate`; FP counts are whole triggers.

| point | desk | soft | lap | lap strict | lap FP | lap FP/20min |
|---|---|---|---|---|---|---|
| both off | 95.65 % | 100 % | **91.25 %** | 82.50 % | **6** | 13.08 |
| ratio 0.6 | 95.65 % | 100 % | 88.75 % | 81.25 % | 5 | 10.90 |
| ratio 0.7 | 95.65 % | 95.00 % | 78.75 % | 72.50 % | 4 | 8.72 |
| cosine 0.80 | **60.87 %** | 85.00 % | 75.00 % | 67.50 % | 5 | 10.90 |
| cosine 0.98 | **34.78 %** | 65.00 % | 51.25 % | 47.50 % | 2 | 4.36 |

| session | both off | ratio 0.6 | ratio 0.7 | cosine 0.80 | cosine 0.98 |
|---|---|---|---|---|---|
| desk 8f0079 | 2/3 | 2/3 | 2/3 | 0/3 | 0/3 |
| desk 5f07e8 | 20/20 | 20/20 | 20/20 | 14/20 | 8/20 |
| soft fe9b8c | 20/20 | 20/20 | 19/20 | 17/20 | 13/20 |
| lap 13e15a (hand resting) | 16/20, 4 FP | 16/20, 3 FP | 15/20, 3 FP | 14/20, 3 FP | 7/20, 2 FP |
| lap ad3fd3 | 19/20, 1 FP | 19/20, 1 FP | 18/20, 1 FP | 11/20, 1 FP | 8/20, 0 FP |
| lap 3fee5b | 18/20, 1 FP | 16/20, 1 FP | 13/20, 0 FP | 18/20, 1 FP | 13/20, 0 FP |
| lap a4a257 | 20/20, 0 FP | 20/20, 0 FP | 17/20, 0 FP | 17/20, 0 FP | 13/20, 0 FP |

The direction test costs **desk** hardest of all, which the brief did not
predict: a desk strike is a near-vertical impulse and its lateral component is
whatever the chassis does next, so consecutive strikes agree in direction less
reliably on a hard surface than on a lap. Any future use of this statistic has
to be graded on all three surfaces, not on lap alone.

## Two other shelved knobs, re-measured at the operating point

Both were flagged as never re-measured since the amplitude scale changed.

`motionGateG` (`chain.bulkMotion` at the crossing sample), swept on `data/raw`:

| motionGateG | pooled det | FP |
|---|---|---|
| 0 (off) | 93.50 % | 6 |
| 0.030 (its old candidate value) | 93.50 % | 6 |
| 0.025 | 93.50 % | 5 |
| 0.020 | 92.68 % | 5 |
| 0.015 | 91.06 % | 4 |
| 0.010 | 74.80 % | 4 |
| 0.005 | 36.59 % | 1 |

Measured directly at the onsets: bulk motion at the six false triggers runs
0.0012 to 0.0288 g against a detection distribution of p50 0.0049 and max
0.0180 g at the first onset. The gate removes two false triggers for three
detections. It is not the mechanism either, and the reason is now visible: these
false triggers are not a laptop being carried.

`onsetCeilingG`, same sweep: all six false triggers survive down to 0.024 g, by
which point detection has already fallen to 61.79 %. They are not oversized.

## What the six false triggers actually are

The brief describes four of the six as "almost certainly the operator shifting
the machine between prompted taps". Checked against the label files, that is
wrong for at least three and probably four of them.

| false trigger | its onsets | nearest labelled group | that group's verdict |
|---|---|---|---|
| 29.764 s (13e15a) | 29.764, 29.962 | 29.958 .. 30.453 (495 ms apart) | **missed** |
| 58.523 s (13e15a) | 58.523, 58.640 | 58.535 .. 58.831 (296 ms apart) | **missed** |
| 78.663 s (3fee5b) | 78.663, 78.845 | 78.661 .. 79.095 (434 ms apart) | **missed** |
| 15.854 s (13e15a) | 15.854, 16.037 | 16.128 .. 16.725 (597 ms apart) | **missed** |
| 11.824 s (ad3fd3) | 11.824, 11.990 | 1.9 s away | — |
| 91.870 s (13e15a) | 91.870, 92.011 | 5.3 s away | — |

Three of them share an onset with a real labelled strike to within 2 to 12 ms,
and a fourth lands 91 ms before one. In each case the labelled gesture is a slow
one — 296 to 597 ms between taps, wider than the 220 ms join window can admit —
so the same gesture is scored as a **miss** and as a **false trigger** at once:
the detector took the real first strike and paired it with a neighbouring lobe
or precursor, fired at the wrong pair, and never saw the true partner.

That is why every within-gesture statistic fails. Half of each of these pairs is
a real tap, so of course it looks like one. It also means the lap false-trigger
count and the lap miss count are not independent problems: four of the six false
triggers are a symptom of the out-of-window gesture, which is a latency-budget
problem, not a discrimination problem.

The remaining two (1.9 s and 5.3 s from any label) are the only ones the brief's
description fits, and no statistic measured here separates them either.

## Status

Both knobs ship **off**: `pairStrengthMinRatio 0`, `pairDirectionMinCosine nil`.
A `tunk-score run --json` before and after this change, at the shipped defaults
and at the resonator operating point, is identical once the timestamp is
removed — 108 990 and 116 203 characters, byte for byte. The two fields are
written into a config file only when they are on, so a settings file from this
build is also unchanged.

## What this does not settle

- **The sample is six.** Nothing here rules out a coherence test working on a
  larger false-trigger set; it rules out this one working on the only six that
  exist, and no threshold on any of the six statistics comes close enough to be
  worth a second look.
- **Only the lateral plane was used for direction.** The strike axis is z, which
  is common to both strikes and carries no information about which way the
  chassis was pushed, so adding it can only dilute the statistic. Untested.
- **The out-of-window finding is the live lead.** Four of the six false triggers
  would stop existing if the detector could group a 300 to 600 ms gesture, and
  the reason it cannot is `maxInterTapNs <= confirmWindowNs` and a 250 ms p95
  budget. That is a different problem from the one this round was given.
