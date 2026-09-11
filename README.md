# Tunk

Double-tap the body of your MacBook and it fires a keyboard shortcut, or runs a
macOS Shortcut. It reads the accelerometer built into Apple Silicon MacBooks at a
measured 796 Hz and picks a deliberate tap out of everything else the machine
feels: typing, trackpad clicks, a mug set down, footfall, bass through the desk.

The reference is **Back Tap on iPhone**, applied to a laptop.

Built for hands-free dictation — bind it to VoiceInk and you start and stop
dictation by tapping the chassis instead of reaching for a key — but the action
is yours to choose.

**Status: in development. Not released.** There is no public download yet; the
disk image described under [Install](#install) comes from
[Build from source](#build-from-source), or from someone who built it for you.
The sensor layer, the action dispatch, the capture tool and the scoring harness
work. The detector is being tuned against recorded sessions. See
[Where it stands](#where-it-stands-against-the-bar), which lists what has and has
not been measured.

---

## Requirements

- An Apple Silicon **MacBook**. The sensor lives in laptop hardware; a Mac mini,
  Studio or Pro has nothing to read.
- macOS 13 or later.

Tunk reads only the accelerometer. Never the microphone, never the camera, and
nothing leaves the machine.

## Install

You need the file `Tunk-<version>.dmg`. Nothing else, and no Terminal.

1. **Open the DMG.** Double-click `Tunk-<version>.dmg`. A window opens with the
   Tunk icon on the left and an Applications folder on the right.
2. **Drag Tunk onto Applications.** Then eject the DMG (the ⏏ next to "Tunk" in
   the Finder sidebar) and delete the `.dmg` file if you like.
3. **Open Tunk from your Applications folder.** Tunk lives in the menu bar, at the
   right-hand end near the clock; it has no Dock icon. The first time, a window
   opens that says what Tunk does and asks for two permissions.
4. **Grant the two permissions.** Each row in that window has a button that opens
   the right pane of System Settings; flip the switch next to Tunk and come back.
   Tunk notices within a couple of seconds. When macOS insists on a relaunch, the
   window says so and offers a button that does it.

That is the whole install. The last step of the window asks you to double-tap the
MacBook so you can see it work.

### The two permissions

| Permission | Why Tunk needs it | Where it lives |
|---|---|---|
| **Input Monitoring** | reads the accelerometer, and sees keystrokes so typing can pause detection | System Settings → Privacy & Security → Input Monitoring |
| **Accessibility** | sends the keyboard shortcut you chose | System Settings → Privacy & Security → Accessibility |

Tunk says which one is missing rather than silently doing nothing. Without Input
Monitoring it refuses to arm at all: a detector that cannot see keystrokes cannot
suppress typing, and typing false positives are the metric that decides whether
the app is worth running.

macOS ties each grant to the exact copy of the app it was granted to. **If you
replace Tunk.app (an update, or a rebuild from source), macOS asks for both
permissions again.** That is macOS behaviour, not a Tunk bug; the first-run
window comes back to walk you through it.

The App Sandbox is disabled deliberately. The private `IOHIDEventSystemClient`
interface the sensor needs is not reachable from inside it.

## Uninstall

1. Quit Tunk: click its menu bar icon and choose **Quit Tunk**.
2. Drag `/Applications/Tunk.app` to the Trash.
3. In System Settings → Privacy & Security, remove Tunk from **Input Monitoring**
   and from **Accessibility** (select it and press the − button). macOS does not
   clean these up on its own.
4. Settings live in `~/Library/Preferences/dev.tunk.settings.plist`; delete that
   file if you want no trace left.

## Build from source

**Xcode is required, not just the Command Line Tools.** The app's settings and
first-run windows are SwiftUI, and SwiftUI's `@State` and friends are compiled by
a macro plugin (`SwiftUIMacros`) that Apple ships inside Xcode and leaves out of
the Command Line Tools. Under the CLT toolchain `swift build` stops at the first
`@State` with `plugin for module SwiftUIMacros not found`. The core libraries
and the three command-line tools build fine either way; the app does not.

Install Xcode from the App Store, open it once so it finishes setting up, then:

```bash
make -C dist app     # builds and ad-hoc signs dist/Tunk.app
make -C dist dmg     # builds the app, then dist/Tunk-<version>.dmg
open dist/Tunk.app
```

You do not need to run `sudo xcode-select`. The build scripts look for
`/Applications/Xcode.app` and use its toolchain for that one build when the
selected toolchain cannot compile SwiftUI. Building by hand needs the same thing
spelled out:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The DMG is assembled with `hdiutil` only. Its window layout (icon positions,
background) is written by Finder, which the script drives with AppleScript, so
the first time you run `make -C dist dmg` from a Terminal macOS asks whether the
Terminal may control Finder; allow it. That run caches the layout in
`dist/dmg-assets/DS_Store` for builds in sessions without a Finder (SSH, CI). If
neither is available the image still mounts with the app, the Applications alias
and the background file; only the window layout is Finder's default.

Every rebuild produces a new ad-hoc signature, so macOS asks for both permissions
again after each one. The signature is what the permission is granted to.

## VoiceInk

VoiceInk supports a primary and a secondary global shortcut. Leave your existing
binding alone and give Tunk its own.

1. Open Tunk's settings from the menubar. Under **Double tap**, choose
   **Send a hotkey** and record a combination.
2. In VoiceInk, go to **Settings → Shortcuts → Second Shortcut**, record the same
   combination, and set the recording mode to **toggle**.
3. Your manual trigger keeps working. Tunk drives the second one.

Three combinations Tunk suggests, chosen to avoid macOS and common app bindings:

| Combination | |
|---|---|
| `Ctrl+Opt+Cmd+;` | the default |
| `Ctrl+Opt+Cmd+\` | |
| `Ctrl+Opt+Shift+Cmd+'` | if the other two collide |

A bare modifier such as Right Shift also works — measured, it arrives as a real
`flagsChanged` with the correct right-hand device bit. Tunk will let you bind it
and will say why a combination misfires less: Shift, Control, Option and Command
are typing keys, so a false trigger sends a live modifier into whatever has focus.

**Or skip hotkeys.** Choose **Run a Shortcut** and pick anything from
Shortcuts.app, the way Back Tap does on iPhone. Tunk dispatches asynchronously
(measured 0.27 ms p50 to hand off) and never blocks on the shortcut finishing.

## The gesture

**Single tap** and **double tap** each bind to their own action. Triple is built
and not surfaced.

Single tap **defaults to unbound, deliberately.** Every mug set down and every
footfall is one transient, whereas requiring two deliberate onsets in a narrow
window is the whole false-positive defence. Measured on 28 minutes of real
recordings, single tap at a calibrated threshold produced **3.56 false triggers
per 20 minutes** against a bar of under 1. Double tap produced **0**. Arm single
knowingly.

Detection is suppressed for a configurable window after any keystroke, trackpad
click or trackpad touch. You cannot trigger Tunk mid-sentence, and that is the
trade that keeps typing quiet.

---

## Where it stands against the bar

The bar is `tunk-prd.md`. Numbers come from `tunk-score` run over recorded
sessions; the harness reports **INCOMPLETE** rather than inventing a value for
anything unmeasured.

**Held out** — 20 prompted double-taps per surface, replayed through the detector,
which the tuning never saw:

| Criterion | Bar | desk | soft | lap |
|---|---|---|---|---|
| Detection rate | ≥ 98 % | **100 %** ✅ | **100 %** ✅ | 80 % ✗ |
| Latency p95 | ≤ 250 ms | **199 ms** ✅ | **208 ms** ✅ | **209 ms** ✅ |
| False triggers | < 1/20 min | **0** ✅ | **0** ✅ | **0** ✅ |
| False triggers while typing | 0 | not recorded | not recorded | not recorded |

The harness returns **FAIL** on lap detection, and would return **INCOMPLETE**
even if lap passed, because the held-out set contains no typing or confound
sessions. The make-or-break metric has never been graded out of sample. On
training data it reads zero across 11.7 minutes of typing — but the input gate
mutes the detector for 86 % of that, so the honest exposure is 1.6 minutes.
`./bin/record-for-the-bar.sh` records what is missing, in about 28 minutes.

**Tunk meets the bar on a hard desk and on a soft surface, and does not on a lap.**

Lap fails, and **the reason is not yet known.** An earlier version of this file
blamed the sensor, on a spectrum measurement that turned out to have left gravity
in the DC bin; corrected, the sensor is usable to about 150 Hz. Three independent
critics were then asked to refute the claim that lap is physically unreachable
and two of them broke it. The word has been withdrawn.

What is measured: on this corpus lap does not reach 98 % inside a 250 ms latency
budget, and four attempts — including three critics trying to break the finding —
produced no better than 19/20 on held-out lap. At twenty gestures, nothing short
of 20/20 clears 98 %.

Twenty-one mechanisms were built against that, each by one agent and graded by a
separate critic with fresh context, on data the builder could not see. One
helped: a resonator front end, which lifts held-out lap to 95 % by the scoring
contract, though only one of its three recovered gestures survives a stricter
reading. It ships behind a switch that is off by default. The rest are preserved
with their verdicts:

```bash
git tag -l 'rejected/*' 'shipped/*'
git show rejected/ring-subtraction     # subtracting the ring makes it 1.20x louder
```

Full working, including what was tried and why each failed, is in
`notes/BAR_ASSESSMENT.md`.

These come from 163 prompted double-taps, 8.4 minutes of continuous typing and
49 minutes of ambient and confound recordings, on one operator and one machine.
Nothing here is synthetic.

Also measured, on this machine: sensor 796 Hz with p95 event-to-callback lag
0.34 ms; idle CPU 2.0 %; idle noise floor 0.00089 g median, 0.0109 g peak.

## Collecting taps without a scripted session

Leave the app running with collection on, use the machine normally, and tap it
when you would anyway. Each tap-shaped transient writes the seconds around it.

```bash
./dist/Tunk.app/Contents/MacOS/Tunk --collect-taps data/raw
```

**Good for the tap profile** — amplitude, rise, decay, and the inter-tap
interval of a real person on a real machine. Those come out of the waveform and
owe nothing to how the snippet was chosen. They are what `calibratedThreshold`,
`onsetCeilingG` and `calibratedInterTapNs` should be fitted to, and all three are
currently numbers somebody guessed.

**Not a detection-rate denominator.** The snippets are selected *by* the
detector, so a tap it missed leaves no file, and scoring against them asks only
whether the detector agrees with itself. Every snippet is written with
`expected_triggers = 0` under a non-tap category so the harness cannot mistake
one for prompted ground truth. Detection rate still needs `tunk-capture guide`.

## Grading what you recorded

One command from raw recordings to a graded pass line. Recording is the only
manual step; this does the rest in the right order.

```bash
./analyse.sh              # grade data/raw
./analyse.sh --holdout    # grade the held-out set, which is what decides pass or fail
./analyse.sh --watch      # re-run automatically as sessions appear
```

It refreshes the binaries first (a stale `bin/` has misled someone three times
here), checks the taps landed *before* labelling so a session of missed taps is
caught while you are still set up, writes ground truth, runs the referee with a
determinism check, and appends a round to the progress page.

## Recording a dataset

`notes/RECORDING_PLAN.md` is the script, and every command in it has been run
against the shipped binary before being written down.

```bash
./bin/tunk-capture doctor                    # 6 s rig check, needs Input Monitoring
./bin/tunk-capture guide --surface desk --only tap_deck --taps 20
./bin/tunk-label check data/raw/$(ls -t data/raw | head -1)
```

**Wear headphones.** The tool speaks prompts and plays beeps; through the
speakers those shake the chassis and land in the stream as fake transients.

`tunk-label check` measures the accelerometer inside each beep window and tells
you whether taps actually registered. It exists because `verify` once passed a
session of six prompted taps in which nobody touched the machine.

## Layout

| | |
|---|---|
| `Sources/TunkCore` | detector and DSP — pure, deterministic, reads no clock |
| `Sources/TunkIMU` | accelerometer over the private IOHID interface |
| `Sources/TunkEmit` | actions: hotkeys and Shortcuts |
| `Sources/TunkApp` | menubar app and settings |
| `Sources/TunkCapture` | `tunk-capture` — record and verify sessions |
| `Sources/TunkLabel` | `tunk-label` — ground truth, and did the taps land |
| `Sources/TunkScore` | `tunk-score` — the referee |
| `web/` | live progress page |
| `site/` | tunk.dev |
| `design/` | icon and identity |

`FORMAT.md` is the frozen data contract. `notes/DECISIONS.md` records the choices
and what was measured to make them.

## Licence

Not yet chosen.
