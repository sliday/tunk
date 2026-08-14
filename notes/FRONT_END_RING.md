# Round 25: reshape the front end so a strike outweighs the tail

Every number here comes from `tunk-score` or from a replay of `data/raw`.
Nothing was measured against `data/holdout`, and nothing here is synthetic
except where it says so.

The brief: the 20 Hz one-pole high pass that opens `SignalChain` exists to
remove gravity, not to discriminate. Amplitude-matched, real second strikes have
spectral centroid p50 31.4 Hz and ring lobes 26.1 Hz, so a filter with more gain
at 31 than at 26 should make strikes bigger than rings before any threshold is
applied.

**The centroid story is wrong, the front-end idea is right, and the mechanism is
not the one the brief named.** Both halves are below.

## Measure first: raise the high-pass corner

Asked for before anything else, and it is nearly a null result. Reconstructing
the shipped chain (per-axis one-pole high pass, quadrature pair, 3-sample
sliding max) over every tap deck in `data/raw`, at corners 20 (shipped) to
40 Hz. `S/T` is the load-bearing statistic: the peak envelope of a labelled
SECOND strike over the envelope in the 12-45 ms just before it — what the second
strike has to stand out from for the detector to re-arm and hear it.

| corner | lap S/T p25, by session | desk S/T | soft S/T | lap strike | lap S/N |
|---|---|---|---|---|---|
| 20 Hz (shipped) | 0.97 / 1.68 / 1.92 / 2.06 | 1.10 | 0.87 | 0.0444 | 32.3 |
| 25 Hz | 0.96 / 1.63 / 2.22 / 2.03 | 1.13 | 0.88 | 0.0395 | 33.5 |
| 30 Hz | 0.96 / 1.59 / 2.50 / 1.98 | 1.14 | 0.89 | 0.0362 | 35.4 |
| 35 Hz | 0.95 / 1.54 / 2.67 / 1.89 | 1.14 | 0.90 | 0.0329 | 36.5 |
| 40 Hz | 0.93 / 1.50 / 2.86 / 1.87 | 1.14 | 0.91 | 0.0297 | 37.1 |

Two sessions improve, two get worse, and the strike loses a third of its
amplitude. One measured surprise worth keeping: **the tilt does not cost SNR**.
Lap strike-to-noise goes 32.3 to 37.1, because lap ambient noise is even lower in
frequency than the tap. The brief expected the opposite trade; it is not there.

A first-order tilt cannot do more than this. Between 26 and 31 Hz a one-pole
high pass at 20 Hz has a gain ratio of 1.06; moved to 40 Hz it reaches 1.12. Six
percent of ratio is not what a 1.0-to-2.0 problem needs.

## What actually separates them

Same reconstruction, adding a pole PAIR (a resonator) after the high pass:

| front end | lap S/T median, by session | soft S/T | desk S/T |
|---|---|---|---|
| shipped | 1.10 / 2.36 / 2.72 / 2.27 | 1.18 | 1.12 |
| two cascaded high passes, 20 + 40 Hz | 1.18 / 2.26 / 3.05 / 2.96 | 0.91 | 1.27 |
| pole pair at 26 Hz, Q 2 | 1.19 / 4.95 / 6.69 / 4.66 | 2.07 | 1.08 |
| pole pair at 32 Hz, Q 2 | 1.16 / 5.34 / 7.45 / 5.96 | 1.82 | 1.24 |
| pole pair at 40 Hz, Q 2 | 1.14 / 5.14 / 7.25 / 6.71 | 1.21 | 1.44 |

A band centred on the RING frequency does as well as one centred on the strike
frequency. That kills the centroid explanation outright: 26 Hz is where the ring
lives, and putting the passband there still trebles the contrast.

What the band actually rejects, measured directly on the raw axes:

| window | lap centroid | power < 20 Hz | 20-40 Hz | > 40 Hz |
|---|---|---|---|---|
| second strike | 25.4-30.4 Hz | 28-38 % | 48-60 % | 9-25 % |
| tail 5-45 ms before it | 22.8-23.6 Hz | 43-46 % | 45-46 % | 9-11 % |

The tail a second lap strike lands on is not mainly the first strike's 26 Hz
ring. It carries a low-frequency shoulder the strike does not, and a 6 dB/oct
high pass passes most of it. Two poles reject it from below while the pair's own
lowpass side trims what little sits above the sensor's 50 Hz ceiling.

The one lap session where nothing helps is `13e15a`: strike 25.5 Hz against tail
26.4 Hz, the two spectra identical. That is the session where the operator rests
a hand on the chassis, and it is the one that scores below chance on every
statistic in `BAR_ASSESSMENT`. Posture, again.

## Why the output is a magnitude, not a bandpass

A real-valued narrow band dips to zero twice per cycle. The detector re-arms on
those dips, and the recorded consequence is in `BAR_ASSESSMENT`: onsets at
16.713, 16.820, 16.921, 17.021 — a metronome at the debounce period, firing on
ripple. `Resonator` therefore publishes `|s|`, the magnitude of the complex pole
state, which is a smooth envelope. Measured on a 40 Hz tone: the magnitude
ripples between 0.437 and 0.563 of its own peak, the real part between 0.000 and
0.563. `FrontEndResonatorTests` holds both.

The filter's own ring-down has a 15.9 ms time constant at 40 Hz Q 2 and reaches
1 % of its peak in 74.1 ms, inside the 100 ms onset debounce, so the stage
cannot be detected as a tap of its own.

## Graded on data/raw

Front end: `resonatorHz 40, resonatorQ 2`. Refitted with it, and nothing else
touched: `defaultThreshold 0.032 -> 0.011` and `minThresholdG 0.02 -> 0.002`.
Both refits are forced, not free parameters — a narrow band costs a broadband
strike about 3x of its amplitude, so the shipped sanity floor alone would sit
above every tap on every surface.

| | detection | strict | FP | typing FP | p95 |
|---|---|---|---|---|---|
| desk shipped | 95.65 % (22/23) | 95.65 % | 0 | 0 | 200.1 ms |
| desk resonator | 95.65 % (22/23) | 95.65 % | 0 | 0 | 203.8 ms |
| soft shipped | 100 % (20/20) | 95.00 % | 0 | 0 | 208.9 ms |
| soft resonator | 100 % (20/20) | **100.00 %** | 0 | 0 | 210.1 ms |
| lap shipped | 73.75 % (59/80) | 66.25 % | 3 | 0 | 225.2 ms |
| lap resonator | **91.25 % (73/80)** | **82.50 %** | **6** | 0 | 226.5 ms |
| pooled shipped | 82.11 % | 76.42 % | 3 | 0 | 225.2 ms |
| pooled resonator | **93.50 %** | **87.80 %** | **6** | 0 | 226.5 ms |

Per session, because posture is a hidden variable:

| session | shipped | resonator | strict | FP |
|---|---|---|---|---|
| desk 8f0079 | 2/3 | 2/3 | 66.7 -> 66.7 % | 0 -> 0 |
| desk 5f07e8 | 20/20 | 20/20 | 100 -> 100 % | 0 -> 0 |
| soft fe9b8c | 20/20 | 20/20 | 95 -> 100 % | 0 -> 0 |
| lap 13e15a (hand resting) | 14/20 | 16/20 | 40 -> 50 % | 3 -> 4 |
| lap ad3fd3 | 16/20 | 19/20 | 80 -> 95 % | 0 -> 1 |
| lap 3fee5b | 15/20 | 18/20 | 75 -> 85 % | 0 -> 1 |
| lap a4a257 | 14/20 | 20/20 | 70 -> 100 % | 0 -> 0 |

Every session improves or holds, including the deviant one, and the strict rate
moves with the contract rate everywhere. That is the difference from the eleven
mechanisms before it: this is not credit for firing on ring lobes. The mechanism
check agrees — lap second taps the detector actually hears go **55/80 to 64/80**
(`FrontEndResonatorTests.testItHearsMoreLapSecondTapsThanTheShippedFrontEnd`),
where the valley-rise re-arm mechanism cured deafness and recovered no gestures.

The comparison that matters, since the refit lowers the bar in new units: the
SHIPPED front end at its own best threshold, same corpus, same harness.

| shipped front end | desk | soft | lap | pooled |
|---|---|---|---|---|
| threshold 0.024 | 95.7 / 95.7 | 70.0 / 65.0 | 81.2 / 75.0 | 82.1 / 77.2 |
| threshold 0.028 | 95.7 / 95.7 | 85.0 / 75.0 | 81.2 / 75.0 | 84.6 / 78.9 |
| threshold 0.032 (shipped) | 95.7 / 95.7 | 100 / 95.0 | 73.8 / 66.2 | 82.1 / 76.4 |
| resonator 40 Hz Q 2, 0.011 | 95.7 / 95.7 | 100 / 100 | 91.2 / 82.5 | 93.5 / 87.8 |

No threshold on the shipped front end reaches lap 91 % at any soft rate, let
alone at soft 100 %. The soft-versus-lap tug of war that defeated a dozen
mechanisms is a property of the front end, not of the threshold.

## Costs, and every value swept

- **False triggers inside lap tap decks double: 3 to 6**, 6.54 to 13.08 per
  20 min. Lap live false triggers already failed the bar; they now fail it
  harder. Desk, soft, both confound sessions, 25 minutes of idle and all
  11.7 minutes of typing stay at **zero**.
- **Typing false triggers across the whole threshold sweep** at this front end:
  0 at every value from 0.005 to 0.022, and **1 at 0.004**. The headroom is
  finite and the operating point sits well inside it, but it is not unlimited.
  Across the Q sweep (1.0 to 4.0) and the centre sweep (10 to 60 Hz), typing
  false triggers are 0 at every value.
- **Latency**: no window moved. p95 desk 200.1 -> 203.8, soft 208.9 -> 210.1,
  lap 225.2 -> 226.5 ms. The 1-3 ms is the pole pair's own group delay at onset.
- **Plateau**: 38-42 Hz, Q 1.75-2.25, threshold 0.0105-0.0115 all land pooled
  91.9-93.5 %. Soft is the sensitive edge — it swings 90 to 100 % over 0.0005 g,
  which on n=20 is two gestures. Treat the soft figure as the least stable
  number here.
- **`minThresholdG` is not load-bearing at the operating point.** 0.002 and a
  proportionate 0.0069 give identical results, because `defaultThreshold` 0.011
  is above both. It has to move only so that it stops being the binding term.

## What is on and what is off

`DSPTuning.resonatorHz` ships at **0**, the stage is not constructed, and the
graded output is byte-identical to the pre-change build: a `tunk-score run
--json` before and after this change differs only in its timestamp. Turning it
on requires naming it, and any report produced with it on carries
`FRONT END IS NOT THE SHIPPED ONE` as its first warning.

The harness can now reach the front end at all, which it could not before —
`Replay` built every detector on `DSPTuning.default`. `resonatorHz`,
`resonatorQ`, `highPassHz` and `minThresholdG` are sweepable by name.

## What this does not settle

- **It is train-set only.** 73/80 on lap is fitted on the same four sessions the
  threshold was refitted on. A critic on held-out data decides whether it
  survives, and the earlier rounds are a warning: four amplitude mechanisms won
  6-8 gestures on train and transferred none.
- **Lap still fails the bar**, at 91.25 % against 98 %, and its live false
  triggers got worse.
- **Desk is unchanged at 95.65 %**, still the single 426 ms gesture the join
  window cannot admit.
- **n = 20 per surface on soft and desk.** One gesture is five points.
