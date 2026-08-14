# Resuming

Paused 2026-08-14. Everything is committed and pushed; the working tree is clean
and 276 tests pass.

## Where the bar stands

Measured on real recordings, desk only:

| Criterion | Bar | Measured |
|---|---|---|
| Detection rate, double tap | ≥ 98 % | **100 % (22/22)** ✅ |
| Latency p95 | ≤ 250 ms | **210.1 ms** ✅ |
| False triggers, live use | < 1 / 20 min | **0 in 29.9 min** ✅ |
| False triggers, confounds | 0 | **0 in 2.1 min** ✅ |
| Triggers on un-armed 1-tap | 0 | **0** ✅ |
| Replay delivery order | 0 | **0** ✅ |
| **False triggers while typing** | 0 | **not recorded** |
| **Soft surface** | pass | **not recorded** |
| **Lap surface** | pass | **not recorded** |

Harness verdict: **INCOMPLETE**, correctly.

## The four recordings that finish it

Headphones on — the tool speaks and beeps, and through the speakers those shake
the chassis into the data.

```bash
cd /Users/stas/Playground/tunk

# 1. The make-or-break metric. 5 min.
./bin/tunk-capture guide --surface desk --only typing --typing-sec 300

# 2. A real held-out tap set, so detection is not self-graded. 2 min.
./bin/tunk-capture guide --surface desk --only tap_deck --taps 20 \
    --out data/holdout --split test

# 3 and 4. The other two surfaces. ~4 min each.
./bin/tunk-capture guide --surface soft --only tap_deck,typing --taps 20 --typing-sec 180
./bin/tunk-capture guide --surface lap  --only tap_deck,typing --taps 20 --typing-sec 180
```

Then:

```bash
./analyse.sh              # grades data/raw end to end
./analyse.sh --holdout    # the numbers that actually decide pass or fail
```

Or `./analyse.sh --watch` to have it grade automatically as sessions appear.

## The open question about the current result

Detection reads 100 %, but the threshold was fitted on the same session it was
measured on. `data/holdout` is empty, so that figure is self-graded.

It is probably still sound — both tap sessions give 100 % anywhere from 0.030 to
0.045, so the operating band is wide rather than a knife edge — but "probably" is
not measured. Recording #2 above settles it, and `tunk-score` refuses to read
`data/holdout` without `--i-am-a-critic`, so tuning cannot leak into it.

A critic (`critic-threshold-fit`) was auditing exactly this when work paused; its
findings had not come back.

## Final acceptance, when the bar is green

The PRD asks for a live driving test on the built app rather than a replay:

```bash
./dist/Tunk.app/Contents/MacOS/Tunk --acceptance 50 300
```

50 prompted double-taps then 5 minutes of typing, counted live against the real
sensor and the real detector. It reports hit rate, latency p50/p95 and typing
false triggers against the bar. It deliberately does **not** post the bound
action — firing a hotkey 50 times into whatever has focus would be its own
disaster, and `--live-emit-probe` already covers emission.

## Also open

- **`--collect-taps`** turns ordinary use into tap recordings. The collector is
  wired and receives every sample; the onset-to-snippet path has never fired,
  because triggering it needs a real tap. One tap settles it.
- **Position classification** (`notes/POSITION_PLAN.md`). Measured within-class
  scatter suggests axis ratios alone are too weak; spectral content is the better
  candidate. Do it after the surfaces, since a desk-trained model probably will
  not transfer to a lap.
- **The site's call to action** points at a private repo and 404s. It needs a real
  destination, and the honest note stays until there is one.
- **The motion gate** is built and shipped disabled. At 0.030 g it separated
  synthetic lifts from taps but dropped a loud surface from 10 deliberate doubles
  to 6. It needs `confound_handling` recordings and probably a gate scaled
  against the adaptive noise floor rather than a fixed g value.

## If the goal hook keeps blocking

It is waiting on a complete pass of the PRD bar, which needs the recordings
above. `/goal clear` releases it in the meantime.
