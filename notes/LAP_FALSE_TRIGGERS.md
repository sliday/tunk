# Round 26: the six lap false triggers, audited one at a time

The brief was to cut the resonator front end's six lap false triggers without
losing the detection gain. **No detector code changed.** The audit says four of
the six are not detector defects, and the metric they fail is computed over a
denominator that contains no lap idle time at all.

Every number here comes from `tunk-score` or from a direct read of `accel.bin`
over `data/raw`. Nothing was measured against `data/holdout`.

Operating point throughout:

    {"resonatorHz":40,"resonatorQ":2,"defaultThreshold":0.011,"minThresholdG":0.002}

Reproduced exactly: pooled 93.50 % (115/123), desk 95.65 %, soft 100 %,
lap 91.25 % (73/80), 6 lap false triggers, typing / confound / idle 0.

## The first hypothesis the brief named, killed in one query

*"Is it a double fire on a gesture that was also credited? If so the fix is the
refractory or the group-close path."*

**No. Zero of six.** For each false trigger, the labelled group nearest to it:

| false trigger | nearest labelled group | that group's verdict |
|---|---|---|
| 13e15a 16.263 s | g1 | **missed** |
| 13e15a 30.189 s | g5 | **missed** |
| 13e15a 58.866 s | g12 | **missed** |
| 13e15a 92.238 s | none — 5.19 s past the last label | — |
| ad3fd3 12.213 s | none — 1.92 s before the first label | — |
| 3fee5b 79.069 s | g17 | **missed** |

Not one sits beside a credited gesture. The refractory and the group-close path
are not the fix, and the 600 ms refractory is already doing its job — in 13e15a
the detector declares an onset at 30.438 s, right on labelled g5's second onset,
and the refractory correctly suppresses it because a trigger fired 250 ms
earlier.

The second consequence matters more: **four of the six false triggers and four
of the seven lap misses are the same four events.** One disagreement between the
detector and the label is charged to the score twice.

## Per-trigger classification

Evidence for each: the detector's own onset list (`tunk-score explain`), the
labeller's peak list inside the prompt window (`tunk-label show`), and an
independent read of `accel.bin` — resting |a| per 250 ms block, plus every
broadband envelope local maximum above 0.004 g.

### 1. 13e15a 16.263 s — LABELLING ERROR

Prompt at 14.963 s. Transients in the window, from the raw stream:

    15.864 s  0.0471 g
    16.087 s  0.0721 g   } 42 ms apart: one strike, two crests of its own ring
    16.129 s  0.0906 g   }
    16.726 s  0.0496 g

Resting |a| is flat at 0.978-0.982 g throughout: nothing was moved.

The labeller committed **(16.133, 16.730), gap 596 ms** — the widest labelled
interval in the whole corpus and 2.3x this session's own median of 257 ms. The
detector fired on **(15.854, 16.037)**, i.e. on the 0.047 g strike and the
0.091 g strike, 223-265 ms apart.

`TunkLabel.analyse` walks the peak list in DESCENDING AMPLITUDE and takes the
first pair whose gap lands in [80, 600] ms. Here that is the 0.091 g peak paired
with the 0.050 g peak 597 ms later; the 0.047 g strike 265 ms *before* it is
never considered, because the loop stops at the first legal pair rather than the
most plausible one.

**The detector fired on the gesture and the label points at something else.**
Under a corrected label the trigger's last onset (16.037) would sit 96 ms from
the labelled last onset — inside the ±150 ms match window — so the group would
be a detection and the false trigger would not exist.

This one also fires at the SHIPPED operating point. It is not a resonator cost.

### 2. 13e15a 30.189 s — GROUND TRUTH UNRESOLVABLE

Prompt at 29.146 s. Six transients across 300 ms, all of comparable height:

    29.761 s  0.0376 g
    29.801 s  0.0341 g
    29.860 s  0.0402 g
    29.960 s  0.0560 g
    30.001 s  0.0493 g
    30.061 s  0.0527 g
    ...
    30.455 s  0.0551 g

Resting |a| flat. The operator produced a flurry, not a clean double. The
labeller committed (29.964, 30.459), gap 495 ms; the detector fired on
(29.771, 29.968), gap 198 ms. Both readings are physically available and the
recording cannot say which two crests the operator intended.

**Not a fire on silence, and not demonstrably a label error either.** It is a
gesture that should never have entered the corpus as a labelled double.

### 3. 13e15a 58.866 s — GROUND TRUTH AMBIGUOUS (three strikes)

Prompt at 57.816 s. Transients:

    58.536 s  0.0800 g
    58.660 s  0.0520 g
    58.777 s  0.0718 g   } 55 ms apart: one strike ringing
    58.832 s  0.0749 g   }

Resting |a| flat. Three physical events, and the operator was asked for two.
Labeller: (58.540, 58.837), gap 296 ms. Detector: (58.523, 58.640), gap 117 ms.

Also present at the shipped operating point. Not a resonator cost.

### 4. 13e15a 92.238 s — CHASSIS MOTION

Fires 5.19 s after the last labelled onset and 120 ms before the `phase stop`
mark. Resting |a| over the last second:

    -1.00 s  0.9804
    -0.75 s  0.9958
    -0.50 s  0.9844
    -0.25 s  1.0441
    +0.00 s  1.2105

The gravity vector swings 0.23 g and stays swung. The broadband envelope ramps
monotonically 0.026 → 0.037 → 0.046 → 0.057 → **0.148** g, three times the
largest tap in the lap corpus. This is the operator moving the machine as the
script ends.

**A genuine false trigger of exactly the kind the bar exists to count.** Pinned
by `LabelCoverageTests.test13e15aEndsWithAChassisMoveNotATap`.

### 5. ad3fd3 12.213 s — A REAL, UNLABELLED DOUBLE TAP

Fires **170 ms before the session's first beep**. Resting |a| flat at
0.978-0.982 g: nothing moved. Two isolated transients on an otherwise quiet
stream, neighbours at 0.005-0.006 g:

    11.823 s  0.0427 g
    11.987 s  0.0376 g     164 ms apart

Compare the next gesture in the same session, which the harness credits:
0.0501 and 0.0546 g, 158 ms apart. The two are indistinguishable in amplitude,
in spacing, and in the flatness of the attitude around them.

The operator tapped before the first prompt. `TunkLabel.analyse` iterates
`marks` where `kind == "beep"` and searches only `[beep, beep + 2600 ms]`, so a
gesture before the first beep can never be labelled and a detector that fires on
it can never be credited.

**A labelling coverage gap, not a detector defect.** Pinned by
`LabelCoverageTests.testAd3fd3HasAnUnlabelledDoubleTapBeforeItsFirstBeep`.

### 6. 3fee5b 79.069 s — A GENUINE RING-LOBE FALSE TRIGGER

Prompt at 77.758 s. Transients:

    78.660 s  0.0423 g     strike one
    78.709 s  0.0218 g   }
    78.757 s  0.0192 g   }  decaying comb at ~46 ms spacing (~21 Hz): ring
    78.839 s  0.0305 g   }
    78.883 s  0.0265 g   }
    78.931 s  0.0219 g   }
    79.094 s  0.0396 g     strike two

Unlike 1, 2 and 3, the intermediate peaks here decay monotonically at the ring
period. The label **(78.665, 79.099), gap 434 ms, is right**, and the detector's
second onset at 78.845 sits on a ring lobe standing at 72 % of strike one's
height, 179 ms after it.

**The detector is wrong here.** This one does NOT fire at the shipped operating
point: it is the resonator's real cost.

## Tally

| class | count | which |
|---|---|---|
| labelling error — detector fired on the gesture | 1 | 13e15a 16.263 |
| labelling coverage gap — real tap, no beep to label it | 1 | ad3fd3 12.213 |
| ground truth unresolvable — operator produced 3-6 transients | 2 | 13e15a 30.189, 58.866 |
| chassis motion — genuine | 1 | 13e15a 92.238 |
| ring lobe — genuine, and new with the resonator | 1 | 3fee5b 79.069 |

**Two of six survive as false triggers in the sense the bar means.** One of
those two (the ring lobe) is the only one the resonator introduced.

Applying the same audit to the SHIPPED operating point's three lap false
triggers — 13e15a at 16.262, 58.861 and 75.929 — all three land in the
label-ambiguity classes (the third is group 16, labelled at 306 ms with a strong
in-window alternative). **The claim that lap false triggers already failed the
bar before the resonator does not survive the audit either.**

## The finding that reframes the round

Every gesture missed on the whole training corpus, desk and lap, is one whose
LABELLED interval falls outside the detector's [100, 220] ms join window. Not
one gesture labelled inside the window is missed.

| session | groups | labelled gap outside the window | missed | loose credits |
|---|---|---|---|---|
| desk 8f0079 | 3 | 1 (426 ms) | 1 | 0 |
| desk 5f07e8 | 20 | 0 | **0** | 0 |
| soft fe9b8c | 20 | 0 | **0** | 0 |
| lap 13e15a | 20 | **14** | 4 | 6 |
| lap ad3fd3 | 20 | 1 (221.5 ms) | 1 | 0 |
| lap 3fee5b | 20 | 3 | 2 | 1 |
| lap a4a257 | 20 | 0 | **0** | 0 |

The three sessions with no out-of-window labels score 20/20. The session with 14
scores 16/20 and supplies four of the six false triggers. `ad3fd3` g5 is
labelled at 221.5 ms and misses by one and a half milliseconds.

At the resonator operating point there is **no amplitude failure and no deafness
failure left on train**. What remains is the join window against the labelled
interval, and in `13e15a` that interval distribution is itself suspect: a
labelled median of 257 ms against 166, 180 and 179 ms in the other three lap
sessions, while the detector's own credited intervals in that same session have
a median of 178 ms — matching the other three, not the labels.

Pinned by `LabelCoverageTests.testOutOfJoinWindowLabelsAreConcentratedInOneLapSession`.

## Two knobs re-measured at the new operating point, both negative

The brief named both as never having been re-measured since the amplitude scale
changed. Full sweeps on `data/raw`; typing, confound and idle false triggers
stayed at **0 at every swept value of both**.

**`motionGateG`** (shipped 0, disabled):

| value | detected | lap FP | note |
|---|---|---|---|
| 0 | 115/123 | 6 | baseline |
| 0.005 | 45/123 | 1 | detection collapses |
| 0.010 | 92/123 | 4 | |
| 0.015 | 112/123 | 4 | -2 FP costs -3 detections |
| 0.020 | 114/123 | 5 | |
| 0.025 | 115/123 | 5 | -1 FP, no detection cost |
| 0.030 and above | 115/123 | 6 | inert |

At 0.025 it removes exactly one false trigger — number 3, the ambiguous
three-strike burst — and, measured directly, it does **not** remove either of the
two genuine ones. The chassis move at 92.238 s survives it, because `bulkMotion`
compares a 6 Hz low pass against a 0.3 Hz one and the ramp has not accumulated
at 91.876 s when the first onset is declared. A knob that removes one of six by
catching the wrong one, on n = 6, is a coin flip, not a mechanism.

**`onsetCeilingG`** (shipped 2.5):

| value | detected | lap FP |
|---|---|---|
| 0.02 | 57/123 | 4 |
| 0.04 | 112/123 | 6 |
| 0.06 to 0.30 | 115/123 | 6 |

Dead. It starts removing detections before it removes a single false trigger,
which is the same conclusion the score-gating measurement already reached from
the other direction: by strength these six are inside the distribution of real
lap taps.

## What no code change means

Nothing under `Sources/` moved. `tunk-score run --data data/raw --json` before
and after this commit is byte-identical apart from `generatedAt`, verdict FAIL
either way, pooled 101 detected and 3 false positives both times.

## What would settle it

Three recordings, in priority order. None of them is a detector change.

1. **Lap idle and lap confound.** The corpus holds 26 minutes of desk idle and
   2.1 minutes of desk confound, and **zero seconds of either on a lap**. The
   metric being failed is "false triggers per 20 minutes of live use", and there
   is no lap live-use recording to compute it from. 20 minutes of the machine on
   a lap while the operator reads, scrolls and shifts position — no prompts, no
   deliberate taps — prices this properly. Everything else here is inference.

2. **A tap deck recorded with the operator's hands staying off the chassis
   between prompts**, and with a `hands off` mark after each gesture. Four of the
   six false triggers are the operator producing three to six transients where
   the protocol asked for two. That is a protocol problem, and the corpus cannot
   distinguish "the detector fired on the wrong pair" from "the operator made an
   ambiguous gesture" without it.

3. **Hand-checked labels for `13e15a`**, or its removal from the training set
   with that removal stated. It carries 14 of the 18 out-of-window lap labels,
   four of the six false triggers and four of the seven misses, on 25 % of the
   lap gestures. Every conclusion about lap detection and lap false triggers is
   currently a conclusion about this one session.

A fourth, cheaper item: `TunkLabel.analyse` takes the first amplitude-ordered
pair inside [80, 600] ms. Preferring the pair closest to the session's own median
interval, or reporting groups with three or more strong peaks as needing review
rather than silently committing a pair, would have surfaced all of this at
labelling time. Not done here — changing the labeller changes ground truth, and
ground truth should not be edited by the agent whose score depends on it.
