# Smoothing pass

Branch `worktree-wf_9a9d9f8a-01a-11`, built on `worktree-qa-finalize-ux` after
merging the three builder branches. Goal: one app, not three improvements.

## Merges

| Branch | What it carried | Conflicts |
|---|---|---|
| `worktree-wf_9a9d9f8a-01a-8` | installer (DMG, toolchain detection, README install path); onboarding closes on Done rather than the replayed flag | none |
| `worktree-wf_9a9d9f8a-01a-2` | settings sidebar (General / Actions / Calibration / Advanced), `--dump-panel` renders every section | none |
| `worktree-wf_9a9d9f8a-01a-7` | DMG window layout shipped as `dist/dmg-assets/DS_Store`, 2x background fix | none |

Every merge was a clean `ort` merge; git reported no conflicts. Branches 8 and
7 share their first installer commit, so 7 applied on top of 8 as a fast
delta. Nothing was resolved by hand. The merged tree built and passed 387
tests before any smoothing edit.

## Wording changes

One rule per thing, applied across the first-run window, the settings window,
the menu and README.

| Thing | Before | After | Where |
|---|---|---|---|
| Permission reasons | onboarding: "Reads the accelerometer, and sees when you type…" / "Presses the keyboard shortcut for you."; settings card: "reads the accelerometer" / "posts the hotkey and watches for typing"; README: "sees keystrokes so typing can pause detection" / "sends the keyboard shortcut you chose" | one pair of sentences, stated once as `PermissionState.inputMonitoringWhy` / `accessibilityWhy` and used by both windows; README table carries the same words | `AppSettings.swift`, `OnboardingView.swift`, `SettingsView.swift`, `README.md` |
| Permission button | settings: "Open Settings"; onboarding: "Open System Settings" | "Open System Settings" everywhere (`PermissionState.openButtonTitle`); the settings button no longer truncates | `SettingsView.swift` |
| Permission card title | "Tunk is not armed" plus a three-line caption repeating the typing argument | "Tunk needs two permissions", one sentence, pointing at Set up Tunk… | `SettingsView.swift` |
| Not-granted pill | settings: orange; onboarding: red | red in both | `SettingsView.swift` |
| Status words | menu: "Sensor unavailable"; settings: "Sensor lost" | "Sensor unavailable" in both | `SettingsView.swift` |
| The double-tap setting's name | menu "Double tap: …", Actions "Double tap", General "Double-tap action", README "Under **Double tap**" | "Double tap" as the name everywhere; "double-tap" stays as the verb in running prose | `SettingsView.swift` |
| Hotkey rendering | menu, onboarding key caps and README: `Ctrl+Opt+Cmd+;`; recorder button, its complaints and the Test result: `⌃⌥⌘;` | the word form everywhere, since it is what VoiceInk takes typed; the "paste into VoiceInk" readout that repeated the recorder is gone | `HotkeyRecorderView.swift`, `SettingsView.swift`, `README.md` |
| VoiceInk instruction | settings: "…Leave your Right Shift binding alone; it stays your manual trigger." (assumes the user's binding); onboarding: "…Your existing VoiceInk shortcut keeps working." | the onboarding sentence in both | `SettingsView.swift` |
| Actions caption | "Double tap is the one that ships armed." | "Double tap is on by default; single tap is off." | `SettingsView.swift` |
| Set up Tunk… | reachable from the menu only | menu, and a button in the settings sidebar that opens the same window (`PanelModel.openSetup`, wired by `AppDelegate`) | `SettingsView.swift`, `SettingsWindowController.swift`, `AppDelegate.swift` |
| README install | no word on reopening the walkthrough | names **Set up Tunk…** in the menu and the sidebar button | `README.md` |
| README VoiceInk step | "Open Tunk's settings from the menubar." | "Click Tunk's menu bar icon and choose **Settings…**", and says the combination reads `Ctrl+Opt+Cmd+;` | `README.md` |
| "menubar" / "menu bar" | README mixed both | "menu bar" in README prose | `README.md` |

Kept as they were, deliberately:

- "Launch at Login" in the menu and "Launch at login" as the onboarding
  checkbox: macOS title-cases menu items and sentence-cases checkbox labels, and
  both references (BAR S6 and `gpt-onboarding.png`) agree with that.
- "Enable detection" was already the same in the menu and the settings switch.
- The sidebar tagline "Reads only the accelerometer. Nothing leaves your Mac."
  and the first-run window's sentence about the accelerometer are one-line
  claims, not explanations; they stay.

## One amber

`Color.tunkAmber` (0.96, 0.65, 0.16) is defined once in `Theme.swift`. It
replaces every `Color.accentColor` in `Sources/TunkApp` (sidebar selection,
prominent buttons, tap-monitor trace and trigger line, calibration bars and
readouts), so the settings window no longer turns system blue next to an amber
first-run window. The tap monitor's typing-pause band uses the same amber at
its old opacities. `OnboardingView.amber` is now an alias for it. Cautions keep
`.orange`, the system's warning colour, so a warning cannot be mistaken for a
highlight.

## Evidence

- `swift build` and `swift test` (Xcode toolchain): 387 tests, 0 failures,
  52 skipped (the emit suites under secure input, as on the base).
- `reports/gauntlet-ux/renders/`: 28 settings PNGs from `--dump-panel` and 18
  first-run PNGs from `--dump-onboarding`, light and dark. General renders at
  659 pt with both grants (bar: 680).
- Not exercised here: clicking Set up Tunk… in the live sidebar. The button
  calls the same `showOnboarding(at: .whatItDoes)` the menu item calls; the
  render proves the button is there, not that the click lands.
