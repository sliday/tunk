# Open items

Requests routed between agents that outlived the agent that raised them. Each
says who owns it now. Delete an entry when it is done, not when it is started.

## Resolved by the lead

- **`TapIntent.triple`** — added to `Sources/TunkFormat/Session.swift` and
  FORMAT.md, with the rule written down: the number of `tap_onset` rows in a
  group is authoritative for the tap count; `intent` records what the operator
  meant; a disagreement is a labelling error and the harness warns rather than
  silently trusting either. `impliedTapCount` and `forTapCount(_:)` added.
- **`DetectorConfig.armedTapCounts: Set<Int>`** — stored truth; `tapCountToFire`
  is now a computed accessor over the same storage, so no call site broke.
  `calibratedInterTapNs: Int64?` added. Defaults `maxInterTapNs ==
  confirmWindowNs == 220 ms`. See D7 in DECISIONS.md.
- **`bin/tunk-label`** shipped; `bin/tunk-capture` re-cut from release (it was a
  stale wave-1 binary still containing the flag-swallowing parser).
- **Right Shift** unblocked. See D4 in DECISIONS.md — the refusal was wrong.
- **Harness scratch** `.tunk-*/` untracked and ignored.

## Owned by TunkScore

- Emit `perSurfaceTapCount` as an array of `Aggregate` elements each carrying
  `label` (surface) plus an extra `tapCount` integer. This exact shape is the
  hook `web/ingest.py` keys on to pick up per-tap-count numbers automatically.
- Emit `rounds[].source = {tool, detector, is_stub, split, data_root,
  warnings[]}` with `warnings` verbatim from `RunReport.warnings`. **This is the
  important one.** `is_stub: true` or any warning renders a "what produced these
  numbers" banner. Without it the page cannot say the numbers came from the stub
  detector, and on a run with no dataset that distinction is the entire story.
- Units the page expects: `detection_rate` as a percentage 0–100, latencies in
  **ms not ns**, `value: null` for unmeasured (never renders as a pass).
- Self-check with `python3 web/schema.py <file>` (exit 0/1, names every problem
  by JSON path) and `python3 web/selftest.py`.

## Owned by TunkCore / detector

- ~~`DetectorConfig.calibratedInterTapNs` is dead.~~ **Wired.** Calibration now
  records onset TIMES as well as strengths, groups them into gestures, fits the
  join window to the operator's own p90 x 1.15, clamps it to a latency-safe
  235 ms, and reports the clamp to the user rather than deciding for them. See
  `TapCalibration.fitInterTap` and `CalibrationTimingTests`. The original text
  follows.

- ~~**`DetectorConfig.calibratedInterTapNs` is dead.**~~ Grepped across `Sources`,
  `Tests`, `bin` and `web`: nothing writes it, nothing reads it, it only
  round-trips through `Codable`. D7 leans on it — it is the stated answer to the
  220 ms join window being a guess — but the learn-my-tap step collects onset
  *strengths* only, never the intervals between them, and the detector reads
  `maxInterTapNs` whatever is in the field. Either wire it (calibration records
  the gaps between successive ungated onsets, a high percentile plus margin
  becomes the value, the detector prefers it over `maxInterTapNs` and the
  `<= confirmWindowNs` invariant still binds) or delete the field. Leaving it
  implies a per-person window that nobody is measuring.
- ~~Re-run the trigger-storm sweep at 220 ms.~~ **Done, and it carries.** A
  periodic thump train fires **0 triggers in 60 s** at every spacing swept —
  120, 160, 200, 210, 220, 230, 260, 300, 400 ms — with the shipped
  `confirmWindowNs` of 220 ms and only double armed. The spacings deliberately
  straddle the window, since that is where chaining either holds or does not.
  Pinned by `testAPeriodicTrainCannotStormAtTheShippedWindow`.
- ~~Measure the single-tap prediction.~~ **Measured, and it holds.** On the
  39.7 minutes of training recordings where the operator is NOT tapping — 26 min
  idle, 11.7 typing, 2.1 confound:

  ```
  single armed   7 triggers   3.50 per 20 min
  double armed   0 triggers   0.00 per 20 min
  ```

  **Four of the seven are during typing** (desk 3, soft 1), which breaks the
  make-or-break metric outright. Single tap cannot ship armed by default, and
  the prediction was right.

  The settings panel already warned, but told the user to "check the harness's
  false-trigger rate" — deferring to a measurement they would never run. It now
  carries the number.
- **Aperiodic knocks still fire.** The `maxInterTapNs <= confirmWindowNs` fix
  kills a *periodic* train by chaining it into one over-long group; a jittered
  one does not chain. Measured on a SYNTHETIC 60 s train with gaps drawn
  uniformly from 100–400 ms, only double armed: 22, 26, 22, 27, 24 triggers
  across five seeds, mean 24.2 per 60 s. `DetectorAperiodicKnockTests` pins it.
  Closing it needs tap-shape discrimination, which needs recorded confounds
  first — see the detector agent's report for what a shape test would key on and
  why tuning one against synthetic taps would only fit it to our imagination.

  **In proportion: it is not observed in any real recording.** The synthetic
  train fires 28.8 times per 60 s. The same detector fires **0 times in
  39.7 minutes** of real non-tapping recordings. Both are true, and the
  reconciliation is in how many onsets the detector declares at all:

  ```
  idle             0 and 3 onsets      over 26 minutes
  confound_music   0 and 4 onsets      over 2.1 minutes
  typing         540, 190, 269 onsets  over 11.7 minutes — all gated, 0 triggers
  synthetic train ~480 knocks in 60 s, every one at 1.6x threshold
  ```

  Real ambient recordings barely produce a suprathreshold onset — at most four
  across twenty-seven minutes. Typing produces hundreds and the input gate kills
  every one. The synthetic train resembles neither: sustained suprathreshold
  impacts every 100-400 ms for a minute, with no keyboard activity to gate them.

  So the finding describes a real weakness in the grouping logic and a regime
  this machine has never been recorded in. What would test it honestly is
  `confound_footfall` — sustained mechanical disturbance with nobody typing —
  which has never been recorded on any surface. Until it is, "24 triggers per
  minute" should be read as what the detector does to a pathological input, not
  as what a user would experience.

  **The resonator does not close it.** Measured with each front end's knock
  amplitude scaled to its own chain gain, and with a control requiring each to
  detect a real double-tap at that amplitude: shipped 28.8 per 60 s, resonator
  28.6. Identical. `ResonatorConfoundTests` pins both the result and the control.

  The first attempt at this measurement said the resonator fired **zero** times.
  It used the shared amplitude helper, which divides by the default chain's gain
  of 0.68; the resonator's is 0.0789, so every synthetic knock was a ninth of the
  intended size and sat under the bar. The control — does this front end still
  detect a real double-tap at the amplitude under test — turns that from a
  breakthrough into an artifact in one line, and is why it is in the test.

### Resolved by the detector agent

- ~~The adaptive noise floor freezes while the detector is disarmed.~~ Fixed.
  Measured worse than described: the freeze was open-ended, so on a loud surface
  the detector could not re-arm and the frozen floor was what stopped the
  threshold rising to let it. On a SYNTHETIC 10 s stretch of 0.25 g broadband
  shake the floor stayed pinned at 0.0030 g and ten deliberate 3.0 g double-taps
  fired nothing; now all ten fire. The hold is bounded to one strike's ring-down
  (`DSPTuning.noiseFloorHoldNs`, 30 ms) so a tap still cannot lift its own
  reference. `DetectorNoiseFloorTests`.
- ~~One-sample race at the join boundary.~~ Fixed. An onset arriving in
  `(maxInterTapNs, maxInterTapNs + one sample]` used to delete the live group
  instead of closing it, losing the gesture silently: a completed double
  followed by a stray knock 221 ms later fired nothing, where the same knock at
  222 ms fired normally. Groups are now closed and take their confirm decision.
  `DetectorJoinBoundaryTests`.

## Owned by TunkEmit

All three of these were fixed and the list was never updated. Checked against
the source and the tests on 2026-08-14:

- ~~`postBalanced` is not serialised.~~ Fixed. `postLock` admits one pair at a
  time (`HotkeyEmitter.swift:233`), and `ActionTests` drives 50 concurrent
  `emit()` calls and asserts no interleaving — the case aggregate counters
  cannot see, because three downs then three ups sums to balanced.
- ~~`Thread.sleep(8 ms)` blocks the caller.~~ Fixed. The hold runs on
  `postQueue`, not on the sensor thread; a test asserts the sensor path returns
  without waiting for it.
- ~~Nothing checks `IsSecureEventInputEnabled()`.~~ Fixed. The emit path throws
  `EmitError.secureInputActive` (`HotkeyEmitter.swift:335`) rather than counting
  a swallowed keystroke as a success, and `ActionTests` pins the error case.

That matters more than a tidy list: a tap into a password field now fails
loudly instead of appearing to work, which is the difference between "Tunk is
unreliable" and "macOS blocked that keystroke".

## Owned by TunkApp

- The calibration review reports the threshold it derived, and the detector runs
  that number multiplied by the sensitivity slider. The panel now names both and
  computes its margin against the one in force, but the underlying question is
  still open: should committing a calibration reset sensitivity to 1.00×, since
  "1.0 = as calibrated" is what `DetectorConfig` says the slider means? Decide
  with the owner rather than in a smoothing pass.

### Resolved by the smoothing pass

- ~~Closing the settings window never stops the 60 Hz tap-monitor timer.~~ Fixed
  before this pass; verified against the built bundle rather than the source.
  `Tunk.app --cpu-probe`, two runs: 1.14 % / 1.48 % of one core with the panel
  never opened, 8.06 % / 9.34 % with it open, 1.37 % / 2.17 % after closing, and
  **0.0 polls per second** in phase 3 both times. The poll counter is the real
  proof; CPU alone moves for other reasons.
- ~~The gate-window slider reaches 0 ms with no floor and no warning.~~ Fixed
  before this pass. The slider floors at 60 ms and the panel prints what it
  costs below 150 ms; `--dump-panel` renders that state as `panel-gatefloor-*`.

## Pass line

Single, double and triple are graded against the **same** bar. Relaxing it for
single tap without data would be inventing a number. If single tap proves
physically incapable of meeting it, the PRD requires reporting that explicitly
with the data rather than quietly moving the line — so let it fail loudly and
decide with numbers in hand. `pass_line_overrides` exists in progress.json
schema 2 if a deliberate, documented exception is ever wanted.
