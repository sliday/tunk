# Audit fixes merged

Branch `worktree-wf_631deab5-28e-21`, merged on top of `worktree-qa-finalize-ux` (9348252) in the order below. No merge conflicts; `Engine.swift` auto-merged fixes 9 and 10 with both intents intact (the sample gate under `detectorLock`, and the calibration restore base).

| # | Fix | File | Test | Behaviour change |
|---|-----|------|------|------------------|
| 1 | Treat a NaN or Inf sample as a dropout so one bad value cannot deafen the detector | `Sources/TunkCore/Detector.swift` | `AuditDetectorProbeTests.testANaNSampleDoesNotDeafenTheDetectorForever` (+2) | A non-finite accelerometer sample no longer poisons the envelope; the detector keeps hearing taps after it. |
| 2 | Sanitise a non-finite noise floor in calibrate so the absolute clamp always applies | `Sources/TunkCore/DetectorCalibration.swift` | `AuditCalibrationClampTests.testNaNNoiseFloorStillAppliesTheAbsoluteClamp` (+2) | Calibration with a NaN/Inf noise floor now yields a finite, clamped threshold instead of a NaN or infinite one that wedged every slider. |
| 3 | Lower a hand-set minInterTapNs when calibration learns a window under it | `Sources/TunkCore/DetectorCalibration.swift` | `AuditCalibrationJoinBandTests.testCalibratedWindowUnderAHandSetMinimumStillDetectsTheCalibratedGesture` (+1) | After calibration, a user-set minimum inter-tap larger than the learned window is lowered so the calibrated gesture still groups. Defaults untouched. |
| 4 | Publish a pending onset only after the retroactive gate window | `Sources/TunkCore/Detector.swift` | `AuditRetroactiveGateTests.testReplayHelperKeepsTheRetroactiveGateFlagOnAPublishedOnset` (+1) | A per-sample `drainOnsets()` (the app's path) now sees the typing-suppressed flag on onsets, matching the batch path. Detection itself unchanged (referee identical). |
| 5 | Keep the stderr reader open past the watchdog | `Sources/TunkEmit/ShortcutSpawner.swift` | `AuditSpawnerWatchdogTests.testChildThatOutlivesTheWatchdogSurvivesItsNextStderrWrite` (+2) | A Shortcut that outlives the spawner watchdog is no longer killed by SIGPIPE on its next stderr write. |
| 6 | Stamp modifier-key flagsChanged relative to the live session set | `Sources/TunkEmit/Poster.swift` | `AuditModifierFlagsChangedTests.testBareModifierDownKeepsTheModifiersTheSessionAlreadyHolds` (+3) | A bare-modifier hotkey (e.g. a lone Shift) no longer clears modifiers the user is physically holding; only its own bits are added or subtracted. |
| 7 | Forward every emission to the panel | `Sources/TunkEmit/ActionRunner.swift` | `AuditEmitTests.testDetectorPathSnapshotSeesItsOwnPair` (+1) | The panel's key down / key up counters now reflect the tap that just fired on the detector path, not only the test button. |
| 8 | hasStuckKey means an unbalanced pair, not a key-down mid-hold | `Sources/TunkEmit/HotkeyEmitter.swift` | `AuditEmitStatsTests.testAHealthyPairMidHoldIsNotReportedAsStuck` (+1) | The stuck-key indicator no longer flashes during a healthy hold; it reports only a key-down whose key-up failed. |
| 9 | Gate feed(sample:) on a lock-protected flag cleared in stopSensors | `Sources/TunkApp/Engine.swift`, `Diagnostics.swift`, `main.swift` | probe: `tunk --sleep-gate-probe` (GATED, 0.00 ms on every path) | Sleep (and every other disarm path) stops feeding the detector as fast as the off switch; TSan no longer reports the `wantsRunning` guard. |
| 10 | Restore the stored config after calibration, not the derived one | `Sources/TunkApp/Engine.swift`, `Diagnostics.swift`, `main.swift` | probe: `tunk --calibration-config-probe` (OK on all three checks) | Cancelling or committing calibration restores the user's stored config; a mid-calibration settings publish can no longer overwrite the restore base. |

## Verification

- Build: `swift build --scratch-path .build-fix` clean.
- Tests: `swift test --scratch-path .build-fix`: 408 executed, 0 failures, 52 skipped (emit suites skip under secure input, expected). Base had 387; the 10 fix branches add 21 tests.
- Referee: `tunk-score run --data data/holdout --i-am-a-critic` written to `/tmp/holdout-merge21.txt`.

```
scope     sess  groups  det   rate      trig  FP   FP/20m   p50       p95       max
desk      1     20      20    100.00 %  20    0    0.00     187.6 ms  198.9 ms  210.1 ms
soft      1     20      20    100.00 %  20    0    0.00     197.6 ms  207.6 ms  208.9 ms
lap       1     20      16    80.00 %   16    0    0.00     183.9 ms  208.9 ms  208.9 ms
VERDICT: FAIL
```

Matches baseline (desk 20/20, soft 20/20, lap 16/20, 0 FP, lap p95 208.9 ms, VERDICT FAIL). `diff` against the baseline report `/tmp/holdout-run.txt` shows only the two worktree-path lines (the reason line and `data root`); every other byte is identical. No fix documented a referee change and none produced one.
