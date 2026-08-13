# Tunk dataset + replay contract (v1)

Frozen interface. Every subsystem reads or writes these files. Change it only by
editing this document first and telling the lead agent.

## Verified machine facts (measured, not assumed)

Measured on this machine (`Mac16,6`, M4 Max, macOS 26.5.2) by `spike/imuspike2.c`
and `spike/batchtest.c`:

| Fact | Value |
|---|---|
| Sensor service | `AppleSPU@10000004` → `accel`, `AppleSPUHIDInterface` |
| HID match | `PrimaryUsagePage = 0xFF00`, `PrimaryUsage = 3` |
| Activation | sensor is **idle until** `IOHIDServiceClientSetProperty(svc, "ReportInterval", <µs>)` |
| Rate at `ReportInterval = 1250` | **796.3 Hz** measured, event timestamps exactly 1.25 ms apart |
| Event type | `kIOHIDEventTypeAccelerometer = 13`; fields `(13<<16)｜0..2` = x, y, z |
| Units | g (rest reading `z ≈ -0.9796`) |
| Batching | none. arrival gap p50 1.255 ms / p95 1.313 ms / max 6.49 ms |
| Event→callback lag | p50 0.27 ms, p95 0.34 ms, max 5.53 ms |
| Gyro (unused) | same page, `PrimaryUsage = 4` |

Consequence for the latency budget: sensor transport costs under 1 ms at p95. The
250 ms p95 target is spent almost entirely on the deliberate 180 ms multi-tap
confirm window. Do not spend it anywhere else.

## Clock

One clock everywhere: `mach_absolute_time()` converted to nanoseconds via
`mach_timebase_info`. Every `t_ns` in every file is nanoseconds since the
**session epoch** (`meta.json → epoch_mach_ns`), monotonic, same timebase for
accelerometer samples, input events, labels and marks. Never mix in wall clock.

Accelerometer `t_ns` uses the value from `IOHIDEventGetTimeStamp` (device clock),
not arrival time. Arrival time is stored separately so the harness can model
real-world lag.

## Directory layout

```
data/
  raw/       <- training sessions. Builder agents MAY read these.
  holdout/   <- test sessions. Builder agents MUST NOT read these. Critics only.
  README.md
```

A session is one directory named
`<category>__<surface>__<YYYYMMDD-HHMMSS>__<shortid>/` containing:

```
meta.json      session metadata
accel.bin      packed accelerometer stream
input.jsonl    keyboard / trackpad activity (drives the gate in replay)
labels.jsonl   ground truth tap onsets
marks.jsonl    operator markers and prompt-track events
notes.md       optional free text from the operator
```

## `accel.bin`

Headerless, little-endian, fixed **28-byte** records, in ascending `t_ns`:

| offset | type | field |
|---|---|---|
| 0 | `int64` | `t_ns` — device timestamp, ns since session epoch |
| 8 | `int64` | `arrival_ns` — `mach_absolute_time()` at callback, ns since epoch |
| 0 | `int64` | `t_ns` |
| 8 | `int64` | `arrival_ns` |
| 16 | `float32` | `x` (g) |
| 20 | `float32` | `y` (g) |
| 24 | `float32` | `z` (g) |

Record size is exactly **28 bytes**, packed, no alignment padding. Writers must
use explicit packing; readers must assert `filesize % 28 == 0`.

Dropped samples are not interpolated. A gap shows up as a `t_ns` step larger than
`1.5 * nominal_interval_ns`; the harness reports gap count per session.

## `meta.json`

```json
{
  "schema": 1,
  "session_id": "typing__desk__20260813-181500__a1b2c3",
  "category": "typing",
  "surface": "desk",
  "epoch_mach_ns": 123456789012345,
  "epoch_wall_iso": "2026-08-13T18:15:00.123Z",
  "report_interval_us": 1250,
  "nominal_rate_hz": 796.3,
  "nominal_interval_ns": 1256000,
  "duration_ns": 300000000000,
  "sample_count": 238890,
  "machine": {"model": "Mac16,6", "chip": "Apple M4 Max", "os": "26.5.2"},
  "split": "train",
  "expected_triggers": 0,
  "operator_notes": "lid open ~110deg, desk is oak, no music",
  "tool_version": "tunk-capture 0.3.0"
}
```

`category` is exactly one of:

| category | meaning | `expected_triggers` |
|---|---|---|
| `tap_palmrest` | scripted deliberate double-taps on the palm rest | = number of prompted double-taps |
| `tap_deck` | same, keyboard deck | ditto |
| `tap_bottom` | same, bottom case | ditto |
| `typing` | continuous real prose, no intended taps | 0 |
| `trackpad` | clicks and hard trackpad taps | 0 |
| `confound_mug` | setting a mug down near/on the desk | 0 |
| `confound_lid` | closing a browser tab hard, hard key presses, lid nudge | 0 |
| `confound_phone` | phone buzzing on the same desk | 0 |
| `confound_music` | bass-heavy music through the desk | 0 |
| `confound_footfall` | someone walking past on a timber floor | 0 |
| `confound_handling` | repositioning, lifting, plugging cables | 0 |
| `idle` | machine untouched | 0 |

`surface` is exactly one of `desk`, `soft`, `lap`.

`split` is `train` or `test`, and must agree with the parent directory
(`data/raw` ⇒ `train`, `data/holdout` ⇒ `test`).

## `input.jsonl`

One JSON object per line, ascending `t_ns`. This is what the gate consumes during
offline replay, so it must be captured live alongside the accelerometer or the
harness cannot reproduce the gate.

```json
{"t_ns": 1234567890, "kind": "key_down", "code": 4}
{"t_ns": 1234599999, "kind": "key_up", "code": 4}
{"t_ns": 1240000000, "kind": "flags_changed", "flags": 262144}
{"t_ns": 1250000000, "kind": "mouse_down", "button": 0}
{"t_ns": 1251000000, "kind": "mouse_up", "button": 0}
{"t_ns": 1252000000, "kind": "mouse_moved"}
{"t_ns": 1253000000, "kind": "scroll"}
{"t_ns": 1254000000, "kind": "trackpad_touch", "count": 2}
```

`kind` ∈ `key_down`, `key_up`, `flags_changed`, `mouse_down`, `mouse_up`,
`mouse_moved`, `scroll`, `trackpad_touch`. Key codes are recorded but **no
characters, no text, and no modifier-plus-key combinations are reconstructed**;
the field exists only to distinguish held keys from repeats. `mouse_moved` is
rate-limited to 100 Hz to keep files small.

## `labels.jsonl`

Ground truth. One object per line, ascending `t_ns`.

```json
{"t_ns": 5012345678, "kind": "tap_onset", "group": 0, "index_in_group": 0, "intent": "double", "confidence": "auto_refined"}
{"t_ns": 5152345678, "kind": "tap_onset", "group": 0, "index_in_group": 1, "intent": "double", "confidence": "auto_refined"}
```

- `group` — taps sharing a `group` are one intended gesture. A double-tap has two
  rows, `index_in_group` 0 and 1.
- `intent` — `double` (should fire), `single` (must not fire), `none`.
- `confidence` — `prompt_window` (timing from the prompt track only),
  `auto_refined` (onset snapped to the strongest transient inside the prompt
  window), `human_verified` (an agent or the operator eyeballed the waveform).

Non-tap categories have an empty `labels.jsonl` and `expected_triggers = 0`. For
those sessions **any** emitted trigger is a false positive.

## `marks.jsonl`

What the capture tool asked the operator to do and when. Written live.

```json
{"t_ns": 1000000000, "kind": "prompt", "text": "double-tap the palm rest", "group": 0}
{"t_ns": 1000000000, "kind": "beep", "group": 0}
{"t_ns": 3000000000, "kind": "phase", "text": "rest"}
{"t_ns": 9000000000, "kind": "operator_mark", "text": "dropped mug too hard, discard group 4"}
```

Labeling rule: for each `beep` with a `group`, the labeler searches
`[beep_t, beep_t + 1.2 s]` for the two strongest transients separated by
80–400 ms and writes them as that group's `tap_onset` rows with
`confidence = "auto_refined"`. Groups where it cannot find two clean transients
are written with `confidence = "prompt_window"` and flagged in `notes.md` for
human review; the harness counts a `prompt_window` group toward the detection
denominator but excludes it from latency statistics.

## Replay contract

The scoring harness feeds a session to the detector and gets back triggers:

```
replay(session, config) -> [ {t_ns, kind: "trigger", tap_onsets:[t_ns,...], score: float} ]
```

Hard requirements on the detector implementation:

1. **Sample-driven, not wall-clock.** The detector advances only on samples and
   input events handed to it in `t_ns` order. No `Date()`, no timers, no
   `DispatchQueue.asyncAfter` in the decision path. Live mode and replay mode
   must run the exact same code and produce identical triggers for identical
   input. The harness asserts this.
2. **Emit time is explicit.** A trigger carries the `t_ns` at which the detector
   decided, so latency = `trigger.t_ns - last_tap_onset.t_ns`. The live app adds
   measured transport lag on top and reports both.
3. **Config comes from one struct**, the same one the settings panel writes.
   Nothing in the detector reads defaults on its own.

## Scoring definitions

Run against a set of sessions:

- **Detection rate** = groups with `intent = "double"` matched by exactly one
  trigger whose second tap onset falls within ±150 ms of the labelled second
  onset, divided by all `intent = "double"` groups.
- **False triggers** = every trigger in a session with `expected_triggers = 0`,
  plus every trigger in a tap session not matched to a labelled group. Reported
  as an absolute count and as a rate per 20 minutes of wall time.
- **Latency** = `trigger.t_ns - second_onset_t_ns`, over matched groups with
  `confidence != "prompt_window"`. Report p50, p95, max.
- **Per surface** — every metric is reported broken down by `surface`, and the
  pass line applies to each surface separately, not to the pooled average.
- **Stuck modifier** = any emitted key-down without a matching key-up. Asserted
  by the emission unit tests and by a live tap on the event stream.

Pass line (from the PRD, do not relax without data):

| metric | pass |
|---|---|
| false triggers, held-out typing | 0 |
| false triggers, live use | < 1 per 20 min |
| false triggers, confound set | 0 |
| detection rate, held-out taps | ≥ 98 %, per surface |
| latency p95 | ≤ 250 ms |
| stuck modifiers | 0 |
