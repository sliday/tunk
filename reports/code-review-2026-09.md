# Code review: Tunk, September 2026

**Verdict: ten defects fixed, nine deferred with reasons, none withdrawn. One high-severity bug made hotkey combinations unrecordable for anyone who presses the modifiers first.**

Four independent reviewers read the shipped modules in parallel, split by subsystem so no two read the same files. Every finding was checked against the source before any change, and two were proven on the real system rather than argued.

Severity: **HIGH** users hit it in normal use. **MEDIUM** reachable, harmful. **LOW** rare or cosmetic.

## Status of verification

Six fixes in `TunkCore` and `TunkEmit` compile under the Command Line Tools. The four fixes in `TunkApp` and all eleven new regression tests are unverified. Xcode 27.0 was installed after the last build and its licence has not been re-accepted. The Command Line Tools lack both XCTest and the SwiftUI macro plugin, so the app target cannot compile and no test can run until `sudo xcodebuild -license accept`.

## Fixed

| ID | Sev | Where | Defect |
|---|---|---|---|
| S1 | HIGH | `HotkeyRecorderView.swift` | The recorder committed a bare modifier on the **press** of the first key. Pressing Ctrl+Opt+Cmd+; the usual way saved "LCtrl" and stopped recording, so a double tap then sent a lone Control. A lone modifier is now held as a candidate and committed only when the same key comes back up with nothing else pressed. Combinations still commit on keyDown. |
| E1 | HIGH | `Engine.swift` `finishSensorStart` | Reset `reacquireBackoff` to 1 on every successful open. A sensor that opens but delivers no samples passes through that path on each attempt, so the backoff never grew and the engine reacquired every ~3 s forever. The watchdog documents this exact spin as fixed. Removed; the watchdog resets it after five healthy ticks. |
| C2 | MEDIUM | `DetectorConfigCoherence.swift` | Nothing kept the tap threshold below `onsetCeilingG`. Every onset that crosses the threshold was then over the ceiling by construction and discarded, and the detector went deaf with no coherence issue reported. **0.2.0 made this reachable** by lowering the ceiling from 2.5 g to 0.7 g. The ceiling now lifts to preserve the ratio the defaults ship with, and a non-positive ceiling falls back to the default. |
| C1 | MEDIUM | `DetectorConfigCoherence.swift` | `madeCoherent()` was not idempotent. A confirm window or maximum under the 100 ms debounce let the minimum be clamped below the floor the same pass had enforced, so the result failed its own `isCoherent` and no double tap could join. The band's ceiling is now floored at the debounce first. |
| E2 | MEDIUM | `Engine.swift` watchdog | Revoking a permission mid-run left the engine armed. `start()` refuses to arm without one, but nothing enforced it afterwards: typing suppression went blind, and a bound Shortcut needs no Accessibility, so it fired on keystrokes. The watchdog now stops to `.needsPermission`; the existing branch re-arms when the grant returns. |
| D2 | MEDIUM | `TunkAction.swift` | One undecodable binding threw for the whole set, and `restored` fell back to the default hotkey, silently dropping every binding that did decode. Entries now decode independently. When none decode it still throws, so a fully corrupt blob keeps falling back to the default. |
| D1 | MEDIUM | `ShortcutsCatalog.swift` | The termination handler dropped the pipe reader on exit, then parsed and marked the listing succeeded. Output still in the pipe was lost, and every bound Shortcut missing from the short listing was refused as deleted. The pipe is now drained after exit. `TextBox` is locked, so the second-thread append is safe. |
| S3 | MEDIUM | `SettingsView.swift` | The Min gap slider offered 40 to 99 ms, all below the debounce. Coherence rewrote them and showed a "settings updated" note on relaunch. Floored at 100 ms. **Partly fixed**: see deferred. |
| D3 | LOW | `ShortcutSpawner.swift` | A Shortcut name starting with `-` was parsed as flags. **Proven on this machine**: `shortcuts run "-tunkprobe"` failed with "Missing value for '-o'", while `shortcuts run -- "-tunkprobe"` correctly reports the name. Added `--`. |
| D5 | LOW | `HotkeySpec.swift` | The panel prints Fn as the globe glyph, but the glyph was missing from Fn's spellings, so pasting it back failed. Added. |

## Deferred

| ID | Sev | Where | Defect | Why not now |
|---|---|---|---|---|
| S3 | MEDIUM | `SettingsView.swift` | The Max gap slider runs to 700 ms but is clamped to the confirm window, so most of its range is rewritten. | Its upper bound has to track the live confirm window, which needs a UI check that cannot run yet. |
| S2 | MEDIUM | `HotkeyRecorderView.swift` | Closing the settings window mid-record leaves the key monitor installed, because the window is ordered out and `onDisappear` never fires. | Needs a window-close hook; untestable until the app target builds. |
| E3 | LOW | `Engine.swift` `didWake` | The delayed post-wake `start()` is not cancelled by a newer sleep or toggle. | Self-heals within a second, and it is threading code that cannot compile yet. |
| C3 | LOW | `DetectorCalibration.swift` | `apply()` can collapse the join band to one point when the fitted window was clamped. | After C1 the collapsed band is still coherent and at or above the debounce. |
| C4 | LOW | `Types.swift` | The legacy `tapCountToFire` key writes `min()` of the armed set. | Only affects a downgrade to a build older than armed sets. |
| S4 | LOW | `AppSettings.swift` | A Shortcut row with no name chosen still arms its tap count. | Fires no action; the cost is a counted gesture. |
| S5 | LOW | `OnboardingModel.swift` | "Try it" reads a disabled engine as "not listening, relaunch". | Message text only. |
| S6 | LOW | `AppDelegate.swift` | A minimised setup window counts as not visible, so a second opens. | Cosmetic. |
| D4 | LOW | `ActionRunner.swift` | A new run shows the previous run's completion latency until it finishes. | Cosmetic statistic. |
| D6 | LOW | `ShortcutsCatalog.swift` | Names are whitespace-trimmed before spawning. | Confidence 45, and trimming is defensive; needs a Shortcut with trailing whitespace to prove. |

## Checked and clean

- **No crash sites in shipped paths.** Zero `fatalError`, `as!`, `preconditionFailure` or force unwraps across `TunkApp`, `TunkCore`, `TunkEmit` and `TunkIMU`. The only five `try!` are in `Diagnostics.swift` and parse string literals.
- **No shell injection.** Shortcuts spawn from an argv array with no shell.
- **No pipe deadlock.** stdout goes to `/dev/null`; stderr is drained with a cap.
- **No stuck modifiers.** Every key-down has its key-up in a `defer`.
- **Secure input** is checked before any event is posted.
- **Sensor lifecycle is sound.** `stop()` unschedules and drains the queue before releasing the client, which rules out a use-after-free; every `@Published` write hops to main.
- **Triple tap** persists, reloads and arms the detector end to end.
