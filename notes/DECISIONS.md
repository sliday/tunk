# Decisions

Choices the PRD left open, or that changed during the run. Each says what was
measured, because the PRD asks for evidence rather than opinion.

## D1 — Sensor access: private IOHIDEventSystemClient, 1250 µs report interval

The SPU accelerometer matches `PrimaryUsagePage 0xFF00` / `PrimaryUsage 3` and is
**idle until `ReportInterval` is set**. That single property is the whole trick;
without it the service matches and delivers nothing, which is what the first
spike did.

Measured at `ReportInterval = 1250`: 796 Hz, unbatched, event-to-callback lag p50
0.27 ms / p95 0.34 ms. Values are in g.

Consequence: sensor transport is under 1 ms at p95, so essentially the entire
250 ms budget is available to the deliberate 180 ms multi-tap confirm window.

## D2 — Action model: pluggable, on the iPhone Back Tap pattern

Originally the PRD specified one output, a configurable hotkey posted via
`CGEventPost`, chosen to drive VoiceInk's Second Shortcut. The owner asked for
something "more universal ... similar to Back Tap on iPhone", where a tap runs a
chosen action and the choices include your Shortcuts.

So the output is now `TunkAction`: `.hotkey(HotkeySpec)`, `.shortcut(name:)`, or
`.none`. Hotkey stays the default and stays the VoiceInk path.

**Dispatch mechanism, measured on this machine:**

| mechanism | p50 | max | verdict |
|---|---|---|---|
| fire-and-forget `Process` spawn of `/usr/bin/shortcuts run` | 0.27 ms | 0.81 ms | chosen |
| `NSWorkspace.open("shortcuts://run-shortcut?name=…")` | 37.96 ms | 345.23 ms | rejected |

The URL scheme would consume up to 345 ms on its own, blowing the p95 target
before the shortcut does any work. It also pops a **modal dialog** when the name
does not resolve, which on an easily-triggered gesture is a worse failure than
doing nothing. Async process spawn costs about as much as posting a key.

## D3 — Latency is measured to dispatch, not to completion

This is a clarification of the PRD's metric, flagged rather than quietly applied.

The PRD says latency is "second-tap onset to emitted key event". For a hotkey
that is unambiguous and unchanged. For a Shortcut there is no emitted key event;
a shortcut can take seconds, or hang, and Tunk cannot control that.

So two numbers, reported separately:

- **`dispatchLatency`** — second-tap onset to handoff. This is what the 250 ms p95
  pass line is measured against, for every action kind. For a hotkey, handoff is
  the posted key event, so the original definition is preserved exactly.
- **`completionLatency`** — how long the action itself took. Best effort,
  reported, never gates anything, never blocks the detector.

The justification is the reference the PRD itself names: iPhone Back Tap does not
promise the action is fast, it promises the *tap* is. A Back Tap bound to a slow
Shortcut still feels instant because the recognition is instant.

## D4 — Right Shift is refused as an emitted binding

The PRD reserves Right Shift as the user's manual VoiceInk primary and says not
to synthesize a bare one. The recorder now refuses it with an explanation rather
than silently ignoring it, which is what it did before.

Left and right modifiers are now distinguished throughout (`RShift` vs `LShift`),
because a listener bound to the right-hand key ignores the left one, so emitting
the wrong side is equivalent to emitting nothing. `ROpt` and `RCmd` give the same
one-key feel without colliding with VoiceInk's primary.

## D5 — Stale shortcut bindings fail passively

A bound Shortcut can be renamed or deleted long after binding. Resolution is
checked against a cached `shortcuts list` before dispatch; a missing name sets an
error state on the menubar glyph and explains itself in Settings. It never spawns
and never raises a dialog.

Validation means checking the name against the list. It never means running the
shortcut to see whether it works — a user's library contains actions with real
side effects.
