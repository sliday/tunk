# Predicting where the tap landed

Owner's hypothesis: sweep the frame around the keyboard clockwise, and learn to
report not just *a double-tap happened* but *where on the case it happened*.

```
        [----FS]        S start, F finish
        |[    ]|        clockwise from the right corner
        [--[]--]
```

That would turn one gesture into eight, which is a different product. It is worth
doing, and it is worth doing in the order that keeps the existing bar intact.

## What the measurement says so far

There is only one 3-axis accelerometer, so there is no time-difference-of-arrival
and nothing to triangulate. Position, if recoverable, is a **classification**
problem: a tap at the top-right loads the axes and excites the panel's bending
modes differently from one at the bottom-left, and those differences are learnable.

Measured on the 40 real onsets already recorded, all at one spot on the keyboard
deck, as the within-class scatter any classifier has to beat:

| axis share of total | mean | sd | range |
|---|---|---|---|
| z | 0.991 | 0.005 | 0.973 – 0.995 |
| x | 0.082 | 0.038 | 0.037 – 0.222 |
| y | 0.102 | 0.019 | 0.062 – 0.141 |

Read that honestly. Nearly all the energy is normal to the deck, which is what a
finger striking a flat panel should do. The positional information has to live in
the ~10 % that is not, and at one fixed spot that 10 % already scatters by 20–40 %
of its own size. **Axis ratios alone look too weak.**

The better candidate is spectral: where you strike a plate determines which
bending modes you excite, and that shows up as a shift in the ringing frequencies
rather than in the amplitude split. Decay time is a third channel — a strike near
a stiff edge rings differently from one over an unsupported span. None of this is
settled by argument; it is settled by recording eight positions and looking.

## Protocol

Eight positions, clockwise from the right corner of the panel as sketched:

| # | position |
|---|---|
| 1 | top right corner |
| 2 | top edge, centre |
| 3 | top left corner |
| 4 | left edge, beside the keyboard |
| 5 | bottom left, palm rest |
| 6 | bottom edge, centre, below the trackpad |
| 7 | bottom right, palm rest |
| 8 | right edge, beside the keyboard |

**20 double-taps per position, ~2 minutes each, about 20 minutes total.** Twenty
gives enough to see whether the classes separate at all; it is not enough to
train anything final, and if they do separate the next round wants 50+.

Record positions in one sitting without moving the machine. Position is being
compared against position, so anything that changes between them — the laptop
shifting on the desk, the lid angle, the surface — is a confound the classifier
will happily learn instead.

## Grading it honestly

The same discipline the detector is under, because a position classifier is far
easier to fool than a threshold:

- **Hold out 25 % of each position**, chosen before any model is fitted.
- **Report a confusion matrix, never accuracy alone.** Eight classes at chance is
  12.5 %; a classifier that nails four positions and guesses the rest can still
  post a respectable single number.
- **Adjacent-class errors are not equal to opposite-class errors.** Confusing
  position 1 with 2 is a near miss; confusing 1 with 5 means the features carry
  nothing. Report both.
- **A baseline that only sees amplitude** must be run alongside. If the real
  classifier does not clearly beat it, the extra features are decoration.

## Order of work, and why

1. **The typing session first.** It is the last unmeasured criterion on the
   existing bar, it is the make-or-break metric in the PRD, and it is five
   minutes. A position classifier sitting on a detector that misfires while
   typing is worth nothing.
2. **Soft and lap surfaces next**, for the same reason: the bar asks for
   robustness across three surfaces, and it is currently measured on one.
3. **Then positions.** With the bar green, this becomes a feature rather than a
   distraction, and there is a working harness to grade it with.

Coupling changes per surface, so a positional model trained on a desk will very
likely not transfer to a lap. That is worth knowing early and is an argument for
doing the surface work before the positional work, not after.


## Feasibility, measured on the existing corpus

The proposal was to tap clockwise around the keyboard frame and learn to predict
WHERE a tap landed, not just that one happened. Before recording a thousand taps
it is worth asking whether the signal could carry position at all.

Every recording in the corpus is `tap_deck` — one location. That cannot test
across positions, but it bounds the answer from the other side: if taps at ONE
location already scatter across all directions, then direction cannot separate
different locations, and no amount of recording changes that.

Lateral (x, y) direction of the first strike, all sessions, both data roots:

| surface | n | circular SD | resultant R |
|---|---|---|---|
| desk | 43 | 83° | 0.353 |
| soft | 40 | 71° | 0.464 |
| lap | 100 | 93° | 0.265 |

Near-uniform. Separating eight positions 45° apart needs within-location scatter
well under about 20°; this is three to four times that. The direction of a strike
is dominated by something other than where it landed — most likely the angle of
the knuckle on each individual tap.

This is the second statistic to fail: the note above already records axis ratios
as too weak. Two independent measures, both near-uniform within one location.

### The physical reason to expect this

There is **one** accelerometer. Locating an impact normally needs several, so
that time-of-arrival differences can be triangulated. A single sensor can only
infer position from how differently the strike excites the chassis modes — and
the sensor is band-limited near 50 Hz, so most of the modal structure that would
differ between locations never arrives.

### What would still be worth testing, and what would not

Not worth recording: anything that leans on direction or axis ratios.

Possibly worth it, but only after the detection bar is settled: whether the
LOW-frequency mode mix differs by location — the 25-50 Hz band is the only part
of the spectrum that reaches the file with any energy. That is a different
statistic from the two now measured shut, and it would need the clockwise deck to
test. It is a research question, not a feature.
