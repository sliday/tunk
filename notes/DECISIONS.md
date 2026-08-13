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
250 ms budget is available to the deliberate multi-tap confirm window (220 ms as
shipped — see D7, which is where that number is decided and is likely to move).

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

## D6 — Single and double tap ship; triple is built but unwired

The PRD said double only, with the multi-tap grouping built as a state machine
that could distinguish counts so triple could arrive later without a rewrite. The
owner has since asked for single and double wired now, triple still deferred.

So a gesture carries a count, and each count binds to its own action, exactly
like Back Tap's separate Double Tap and Triple Tap rows. Counts 1 and 2 are
surfaced; 3 is representable and costs nothing to enable later.

**Single tap defaults to unbound, and that is deliberate.** A single tap is a
different risk class from a double: every mug set down, every footfall and every
hard keystroke is one transient, whereas the entire false-positive defence rests
on requiring two deliberate onsets in a narrow window. The owner chose to have
it, which is their call to make. What the build owes them is the real number, so
the harness reports single-tap false triggers separately from double rather than
pooling them into one flattering average.

This also resolved a bug rather than adding one. A critic measured that a 60 s
stream of periodic 0.5 g thumps 250 ms apart produced 48 triggers, and at 200 ms
spacing 60 triggers, ungated — because `confirmWindowNs` (180 ms) was shorter
than `maxInterTapNs` (400 ms), so a group fired before a later tap could retract
it. Supporting triple requires the opposite invariant:

    maxInterTapNs <= confirmWindowNs

which makes "two knocks then silence" distinguishable from "a stream of knocks at
double-tap cadence". One change, and it both kills the trigger storm and makes
triple possible. Double still fires one confirm window after its last onset
whether or not a third tap is coming, so adding triple never changes how double
feels — which is what the PRD asked for.

## D7 — The join window is 220 ms, and it is the number most likely to move

The detector agent asked for `maxInterTapNs = 180 ms` to match the confirm
window. Applied the invariant, took 220 ms instead, and the deviation is worth
recording because it is a genuine trade with no free side.

The confirm window essentially *is* the latency: a gesture fires one window after
its last onset. The PRD's 250 ms p95 budget therefore caps the window near
240 ms. Pulling the other way: a double-tap slower than the window does not group
at all, so a tight window costs detection rate silently — the user just feels the
app ignoring them, which is exactly the felt-reliability failure the Back Tap
comparison exists to catch. Unhurried double-taps commonly land in the
180–250 ms range.

220 ms takes most of the available room and keeps 30 ms of headroom. It is a
guess made without data, and it is flagged as such. `calibratedInterTapNs` exists
so the learn-my-tap step can replace it with the user's own measured interval,
which is the per-person variation that step exists to absorb.

**Open, to be measured once the dataset exists:**

1. Re-run the trigger-storm sweep at 220 ms. The 0-triggers result was measured
   at 180 ms and does not automatically carry.
2. The predicted failure mode for single tap, which must be measured rather than
   assumed: a knock train spaced *wider* than the join window gives every thump
   its own group of one. Harmless while only count 2 is armed. Once count 1 is
   armed it fires on every thump. If that holds, it is the strongest argument
   that single-tap cannot ship armed by default.
3. What statistic calibration should use for the interval — probably a high
   percentile of the observed distribution plus margin, clamped to the latency
   budget — decided from real taps, not from a guess.

## D8 — The referee was drilled before the data arrived

Detection rate and labelled latency had never run through the real path, because
no labelled session has ever existed. Drilled against a planted synthetic
holdout, so the machinery is proven rather than assumed the day real taps land:

| check | result |
|---|---|
| holdout guard, no flag | refuses, names the path |
| holdout guard, `--i-am-a-critic` | grades, loud banner |
| detection rate, all armed | 44.44 % (4/9) — computes |
| detection rate, 3-tap | 100 % (4/4) — triples detected |
| detection rate, 1-tap | 0 % (0/5) — expected; the bounce fixture closes them as pairs |
| **latency p95** | **222.2 ms** |

The latency figure is the valuable one. It is measured the PRD's way — labelled
last onset to trigger — and lands within 1.5 ms of the 223.7 ms that
`tunk --latency-probe` measured by a completely independent route (wall clock,
real `CGEventPost`, observed by an event tap). Two methods that share no code
agreeing to a millisecond is worth more than either alone, and it is the only
pass-line number currently backed that way.

## D5 — Stale shortcut bindings fail passively

A bound Shortcut can be renamed or deleted long after binding. Resolution is
checked against a cached `shortcuts list` before dispatch; a missing name sets an
error state on the menubar glyph and explains itself in Settings. It never spawns
and never raises a dialog.

Validation means checking the name against the list. It never means running the
shortcut to see whether it works — a user's library contains actions with real
side effects.
