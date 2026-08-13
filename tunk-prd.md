# Tunk — build brief (Gauntlet Loop)

Working name, rename freely. A macOS menubar utility that detects a deliberate double-tap on the laptop body via the built-in accelerometer and emits a configurable global hotkey, used to toggle VoiceInk dictation hands-off. Ship double-tap only. Design so triple-tap slots in later without a rewrite.

## Goal

Double-tapping the MacBook chassis fires a chosen keystroke as reliably, and misfires as rarely, as double-tapping the back of an iPhone with Back Tap. Everything below serves that sentence.

## The bar

There is no visual reference to A/B against. The bar is a quantitative harness the critic runs on held-out recordings plus a live driving test on the real app. iPhone Back Tap is the felt reference for final acceptance.

Record your own ground-truth dataset first (you have full access to this machine). Build a small capture tool that logs the raw ~800Hz accelerometer stream with timestamps, and record scripted sessions:

- Deliberate double-taps on the palm rest, keyboard deck, and bottom case (label each tap onset).
- Continuous typing of real prose, several minutes, no intended taps.
- Trackpad clicks and hard trackpad taps.
- Confounds: setting a mug down, closing a browser tab hard, a phone buzzing on the same desk, bass-heavy music through the desk, someone walking past on a timber floor, repositioning and lifting the machine.
- Repeat the core sets on at least three surfaces: hard desk, laptop on a soft surface (bed or cushion), and on the lap.

Hold out a portion of every category as a test set the builder never sees during tuning.

Targets (my numbers, treat as the pass line, tune only with evidence):

- False triggers while typing: 0 in the held-out typing set, and under 1 per 20 minutes in live use. This is the make-or-break metric.
- Deliberate double-tap detection: at least 98% on the held-out tap set.
- Latency, second-tap onset to emitted key event: p95 at or under 250ms.
- Robustness: pass detection and false-positive targets on all three surfaces, and zero triggers across the entire confound set.
- Never emit a stuck modifier: assert every synthetic key-down is followed by its key-up.

If a target proves physically unreachable on some surface (a concrete slab may attenuate taps badly), the critic must say so explicitly with the data, not quietly relax the number.

## What to build

- Read the accelerometer at ~800Hz over the IOKit HID interface (the same undocumented sensor exposed on Apple Silicon MacBooks; reference implementations exist in macimu and spank).
- Detect a deliberate double-tap: sharp transient onsets grouped by inter-tap interval. Single stray taps do nothing.
- Gate detection on input activity: suppress tap onsets for a short window (start around 150-200ms, make it configurable) after any keystroke, trackpad click, or trackpad touch. This is how typing false positives get killed. Accept the consequence that the user cannot trigger mid-type.
- On a confirmed double-tap, post the mapped global hotkey via CGEventPost.
- Calibration: a "learn my tap" step where the user taps ten times and the threshold is derived from that distribution, rather than a shipped fixed threshold. Coupling varies by model and surface.
- Menubar app (LSUIElement), global enable/disable toggle, launch at login. No dock icon, no main window beyond a small settings panel.
- Settings: sensitivity, gate window, and the emitted hotkey mapping. Include a live "tap monitor" readout during setup so the user can see onsets register.

### VoiceInk integration (confirmed against their docs)

VoiceInk supports a primary and an optional secondary global shortcut, each a dedicated modifier or a custom combination, with toggle / push-to-talk / hybrid modes. Do not synthesize a bare Right Shift. Instead:

1. Leave the user's existing Right Shift binding as the manual primary.
2. Instruct the user (in the README) to add a Second Shortcut in VoiceInk Settings → Shortcuts, bound to a rare custom combination, recording mode set to toggle.
3. Tunk emits exactly that combination on double-tap.

Make the emitted combination configurable so the user picks it and pastes it into both places. A rare combo avoids the fragility and collision risk of a lone modifier.

### Hard constraints

- False triggers during typing are the primary failure mode. A build that hits every other target but misfires while typing has failed.
- Survive sleep/wake and sensor disconnect without crashing or wedging; re-acquire the HID device on wake.
- Continuous sampling must stay cheap: keep steady-state CPU low (aim under 2-3% on an idle machine) and consider duty-cycling on battery.
- Permissions required: Input Monitoring (read the sensor), Accessibility (post key events), App Sandbox disabled. Document the exact grant steps.

### Explicitly deferred, but do not wall off

Triple-tap. Build the multi-tap grouping as a state machine that can distinguish tap counts, but only wire double for now. So the double path should fire after a short confirm window (around 180ms) rather than instantly, so that adding triple later does not change the felt latency of double.

## How to run this (the loop)

- Lead agent owns the split. The natural subsystems: sensor IO, onset detection, multi-tap state machine, input-activity gate, keystroke emission, calibration, menubar/settings, and the capture-and-harness tooling. Decide which run in parallel and which are coupled.
- Each meaningful subsystem gets a builder and a separate critic with fresh context. The critic never sees the builder's reasoning.
- The critic grades the real thing, not a summary: it runs the harness against the held-out recordings and reports the metrics above, then names the single biggest gap and sends it back. Loop, no fixed round count.
- Final acceptance is a live driving test on the built app, run by a fresh critic: perform 50 deliberate double-taps and record hit rate and latency, then type continuously for 5 minutes and record false triggers. Compare against the bar. If it loses, keep going.
- Maintain a simple live progress page (plain HTML or workbench.md) showing metric trends per round, so the run can be watched from a phone without interrupting it.
- After each wave, one smoothing agent checks the whole app hangs together (settings actually drive the detector, gate and calibration interact correctly) before the next wave.
- Use subagents, /loop, and ultracode.

## Not prescribed (your call)

Filter design and onset method, exact thresholds and windows before calibration, the decomposition beyond the hint above, native language and framework choice, and the number of rounds. Pick what the data supports.

## Deliverables

- The signed-or-self-signed menubar app.
- The capture tool, the labelled dataset, and the scoring harness, checked in.
- The live progress log from the run.
- A short README: setup and permissions, the VoiceInk second-shortcut steps, and the final measured metrics against the bar.
