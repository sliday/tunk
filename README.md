# Tunk

Double-tap the body of your MacBook and it fires a keyboard shortcut, or runs a
macOS Shortcut. It reads the accelerometer built into Apple Silicon MacBooks at a
measured 796 Hz and picks a deliberate tap out of everything else the machine
feels: typing, trackpad clicks, a mug set down, footfall, bass through the desk.

The reference is **Back Tap on iPhone**, applied to a laptop.

Built for hands-free dictation — bind it to VoiceInk and you start and stop
dictation by tapping the chassis instead of reaching for a key — but the action
is yours to choose.

**Status: in development. Not released. There is nothing to download.** The
sensor layer, the action dispatch, the capture tool and the scoring harness work.
The detector is being tuned against recorded sessions. See
[Where it stands](#where-it-stands-against-the-bar), which lists what has and has
not been measured.

---

## Requirements

- An Apple Silicon **MacBook**. The sensor lives in laptop hardware; a Mac mini,
  Studio or Pro has nothing to read.
- macOS 13 or later.

Tunk reads only the accelerometer. Never the microphone, never the camera, and
nothing leaves the machine.

## Build and run

```bash
swift build -c release
./dist/build-app.sh          # assembles and ad-hoc signs dist/Tunk.app
open dist/Tunk.app
```

`xcodebuild` is not required. Tests need Xcode's toolchain for XCTest:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Permissions

Two grants, and Tunk explains which is missing rather than silently doing
nothing.

| Permission | What it is for | Where |
|---|---|---|
| **Input Monitoring** | read the accelerometer, and see keystrokes so typing can suppress detection | System Settings → Privacy & Security → Input Monitoring |
| **Accessibility** | post the synthetic key event | System Settings → Privacy & Security → Accessibility |

Add `Tunk.app` to both, then quit and reopen it. macOS caches the decision per
binary, so **re-grant after replacing the app** — a rebuilt bundle is a new binary
even at the same path.

The App Sandbox is disabled deliberately. The private `IOHIDEventSystemClient`
interface the sensor needs is not reachable from inside it.

Without Input Monitoring, Tunk refuses to arm rather than run half-blind: a
detector that cannot see keystrokes cannot suppress typing, and typing false
positives are the metric that decides whether the app is worth running.

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

| Criterion | Bar | desk | soft | lap |
|---|---|---|---|---|
| False triggers while typing | 0 | **0** ✅ | **0** ✅ | **0** ✅ |
| False triggers, live use | < 1/20 min | **0.00** ✅ | **0.00** ✅ | 4.36 ✗ |
| Latency p95 | ≤ 250 ms | **200 ms** ✅ | **209 ms** ✅ | **225 ms** ✅ |
| Detection rate | ≥ 98 % | 95.65 % ✗ | **100 %** ✅ | 73.75 % ✗ |

A held-out desk set of 20 double-taps, which the threshold was never fitted to,
scores **100 % detection at 189 ms p95**.

**Tunk meets the bar on a hard desk and on a soft surface, and does not on a lap.**
Desk misses by exactly one gesture: a real double-tap with 426 ms between the
strikes, which cannot be grouped without spending more latency than the 250 ms
budget allows. Lap fails for physical reasons — coupling halves the tap while lap
ambient noise reaches tap amplitude — and every lever was tried and measured.

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
