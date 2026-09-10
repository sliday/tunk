# The bar: a quality Mac menubar app that a non-technical person can set up

This is what the critic compares the built artifact against. It is not a
description of what we want; it is a set of things a critic can open, run, or
count. A round is won only when the critic, with this file and the artifact and
nothing else, prefers ours.

## Visual reference (open these, then open ours)

Drafted by GPT image 2.5 from the current panel plus a full brief on what every
control does. They set the *layout and hierarchy* bar. They do not set wording:
the dark draft's gate-window caption is wrong (it describes the confirm window).
Wording facts come from `README.md`, `Sources/TunkApp/SettingsView.swift`, and
`Sources/TunkCore/Types.swift`.

| File | What it is the reference for |
|---|---|
| `design/mockups/gpt-settings-light.png` | Settings window: sidebar General / Actions / Calibration / Advanced, essentials above the fold, experiments out of sight on General |
| `design/mockups/gpt-menu-dark.png` | Menubar dropdown wording and order; dark-mode settings materials |
| `design/mockups/gpt-onboarding.png` | First-run window: three steps, two permission rows with status pill + one button each, launch-at-login, Continue gated on both grants |
| `design/mockups/before-settings-light.png`, `before-settings-dark.png` | What we are trying to beat: the current single-column scroll |

Reference apps, by name, for the critic who knows them: CleanShot X (onboarding
and permission wizard), Rectangle (one-screen Accessibility onboarding), Ice
(menubar extra and sidebar settings), Raycast (settings IA), Apple System
Settings on macOS 26.

## Mechanical checklist (each item is pass / fail, no partial credit)

### Install and first launch
- [ ] B1. From a fresh `git clone` of the branch, `./dist/build-app.sh` produces a signed `dist/Tunk.app` on a Mac with Xcode installed, even when `xcode-select` points at the Command Line Tools. (Today: `dist/` is gitignored and the CLT toolchain cannot compile SwiftUI macros.)
- [ ] B2. `./dist/build-dmg.sh` produces `dist/Tunk-<version>.dmg` that mounts with `Tunk.app`, an `Applications` alias, and a background that says to drag. `hdiutil verify` passes.
- [ ] B3. First launch of the app from `/Applications` opens a window (not only a menubar glyph). It says in one sentence what Tunk does, names iPhone Back Tap, and says it reads only the accelerometer.
- [ ] B4. The window lists the two permissions, each with: name, one plain-English line of why, a status pill, and exactly one button that opens the correct System Settings pane (`Privacy_ListenEvent` for Input Monitoring, `Privacy_Accessibility` for Accessibility).
- [ ] B5. After the user grants in System Settings and returns, the pill updates without relaunch within 2 s. Where macOS requires a relaunch (Input Monitoring for the IOHID client), the window says so and offers a one-click Relaunch that brings the user back to the same step.
- [ ] B6. Continue is disabled until both are granted. Launch at login is offered on the same screen.
- [ ] B7. The last step invites a double-tap with live feedback (the tap monitor or a "felt it" pulse) and shows the bound hotkey with the VoiceInk second-shortcut instruction.
- [ ] B8. Onboarding never shows again after completion, but is reachable from the menu ("Set up Tunk…" or under Settings) and from `tunk --onboarding`.
- [ ] B9. `README.md` has an Install section a non-technical person can follow: download DMG, drag, open, grant two permissions, done; plus Uninstall (quit, drag to Trash, remove from the two permission lists).

### Settings information architecture
- [ ] S1. Settings has sections General, Actions, Calibration, Advanced (sidebar or segmented). General fits in 680 pt of height without scrolling at the default window size and contains: enable switch, live readouts (sample rate, taps fired, last latency), tap monitor, double-tap action.
- [ ] S2. Nothing on General or Actions uses engineering vocabulary: "effective threshold", "confirm window", "noise floor", "p95", "onset", "resonator", "pairing" appear only under Advanced.
- [ ] S3. Both experimental switches (resonator front end, lap pairing) live under Advanced, off by default, with their measured caveats intact.
- [ ] S4. Every control that existed before still exists and writes the same setting. `--dump-panel` still renders, and renders each section.
- [ ] S5. Dark and light both render (`--dump-panel`), and the panel honours reduced motion.
- [ ] S6. Menubar dropdown order: status line in plain words ("Listening", "Off", "Needs permission"), Enable detection, separator, the bound double-tap readout, Calibrate…, Settings…, separator, Launch at Login, Quit Tunk.
- [ ] S7. `UI_STANDARD.md` holds: tabular digits on live readouts, concentric radii, shadows not borders, 40 pt hit areas, no first-paint animation.

### Icon
- [ ] I1. `design/AppIcon.icns` is built from a transparent PNG: all four corner pixels alpha 0, subject centred, fills 75-85 % of the canvas.
- [ ] I2. Two impact points of unequal size; no face, no fingers, no text. Palette: aluminium body, amber cores.
- [ ] I3. Reads at 16 px in the Dock and Finder (open `design/contact-sheet.html`).

## Rules the critic enforces regardless of the checklist
- The four non-negotiables in `AGENTS.md` (detector reads no clock; never read `data/holdout/` unless a critic; no stuck modifiers; report what was measured).
- No change to any detector default, `DetectorConfig`, `DSPTuning`, or `Package.swift`.
- No new dependency. SwiftPM only. Ad-hoc signing stays.
- Every claim in a builder's report is discarded; the critic looks at the artifact.

## Instrument notes (read before trusting any render)
- `tunk --dump-panel <dir>` renders `SettingsView` with a throwaway defaults suite. It runs with whatever permissions the calling terminal has; the permission card appears only when a permission is missing, so a dump made from a terminal that has both grants will never show it. Force it with `--dump-panel` after the builder adds a `--no-permissions` render, or inspect the code path.
- Building needs Xcode's toolchain: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --scratch-path .build-<name>`. The Command Line Tools toolchain fails on `@State` with "plugin for module SwiftUIMacros not found". A critic who sees that error has a toolchain problem, not a code finding.
- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path .build-<name>`; 387 pass on the base commit.
- Launching the real app from a worktree build to look at a window: `.build-<name>/arm64-apple-macosx/debug/tunk --settings` opens the panel; `--onboarding` (once built) opens the first-run window. Quit with `pkill -f '/debug/tunk'`. A window screenshot needs Screen Recording permission for the terminal; the dump PNGs are the accepted instrument when that is not granted.
