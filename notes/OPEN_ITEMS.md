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

- Switch `ScoringPolicy.from(config:override:)` to read `config.armedTapCounts`
  directly instead of `[config.tapCountToFire]`.
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

- **Re-run the trigger-storm sweep at 220 ms.** The 0-triggers result was
  measured at 180 ms and does not carry automatically.
- **Measure the single-tap prediction**: a knock train spaced wider than the join
  window gives every thump its own group of one — harmless while only count 2 is
  armed, fires on every thump once count 1 is armed. If it holds, it is the
  strongest evidence that single tap cannot ship armed by default. Wanted as a
  measured number, not as the lead's speculation.
- **Aperiodic knocks still fire.** The `maxInterTapNs <= confirmWindowNs` fix
  kills a *periodic* train by chaining it into one over-long group; a jittered
  one does not chain. Measured on a SYNTHETIC 60 s train with gaps drawn
  uniformly from 100–400 ms, only double armed: 22, 26, 22, 27, 24 triggers
  across five seeds, mean 24.2 per 60 s. `DetectorAperiodicKnockTests` pins it.
  Closing it needs tap-shape discrimination, which needs recorded confounds
  first — see the detector agent's report for what a shape test would key on and
  why tuning one against synthetic taps would only fit it to our imagination.

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

- `postBalanced` is not serialised: concurrent `emit()` calls interleave into N
  key-downs before any key-up, and `hasStuckKey` cannot see it.
- `Thread.sleep(8 ms)` inside `postBalanced` blocks the caller, and the only
  production caller is the 796 Hz HID sample callback.
- Nothing checks `IsSecureEventInputEnabled()`, so a keystroke swallowed by a
  password field is recorded as a successful emission.

## Owned by TunkApp

- Closing the settings window never stops the 60 Hz tap-monitor timer, so the app
  burns ~10 % CPU forever after Settings is opened once. The source claimed a
  measured 1.2 % with the panel closed; the critic measured 9–11 %.
- The gate-window slider reaches 0 ms with no floor and no warning, which
  silently disables the one mechanism that kills typing false positives.

## Pass line

Single, double and triple are graded against the **same** bar. Relaxing it for
single tap without data would be inventing a number. If single tap proves
physically incapable of meeting it, the PRD requires reporting that explicitly
with the data rather than quietly moving the line — so let it fail loudly and
decide with numbers in hand. `pass_line_overrides` exists in progress.json
schema 2 if a deliberate, documented exception is ever wanted.
