# Live progress page

A phone-readable page the operator watches while the gauntlet loop runs. Plain
HTML and CSS, no framework, no bundler, no build step.

```
web/
  progress.json   the data. The harness appends to it; this file is the contract.
  schema.py       the contract as code. Validates progress.json, exit 0 or 1.
  ingest.py       appends a round (from a tunk-score report or a round object)
  render.py       regenerates index.html from progress.json
  index.html      GENERATED. Do not hand-edit.
  style.css       hand-written
  progress.js     optional enhancement (polling, relative times, live staleness)
  selftest.py     tests for all of the above
  fixtures/
    demo.json     SYNTHETIC multi-round data for laying the page out. Not measured.
```

## The loop, end to end

```bash
# 1. score a round, however you score it
swift run tunk-score run --json /tmp/run.json …

# 2. append it and rebuild the page in one step
python3 web/ingest.py --from-score /tmp/run.json --label "gate widened to 220 ms"

# or, if you built the round object yourself
python3 web/ingest.py --round /tmp/round.json
```

`ingest.py` validates before it writes, restamps `generated_at`, and re-renders
`index.html`, so the JSON and the page cannot drift apart. Writing
`progress.json` directly is fine too — then run `python3 web/render.py` yourself.

```bash
python3 web/schema.py web/progress.json   # does my file match the contract?
python3 web/render.py                     # rebuild index.html
python3 web/render.py --check             # CI: fail if index.html is stale
python3 web/render.py --validate          # schema only, write nothing
python3 web/render.py --json fixtures/demo.json --out _preview.html
python3 web/render.py --built-at 2026-08-13T23:00:00Z   # preview the stale state
python3 web/selftest.py                   # run the tests
```

`index.html` is committed on purpose. The page must show the current numbers
with JavaScript off and over `file://`, so nothing is fetched at load time.
**Re-run `render.py` after every edit to `progress.json`**, or a watching phone
reloads into the same stale page.

## progress.json

Top level:

| field | type | required | meaning |
|---|---|---|---|
| `schema` | int | yes | `2` |
| `title` | string | no | shown in `<title>` |
| `generated_at` | ISO-8601 UTC | yes | when the harness last wrote this file |
| `stale_after_s` | int | no | page calls itself stale past this age. Default `900` |
| `cold_after_s` | int | no | second, louder threshold. Default `7200`, must exceed `stale_after_s` |
| `primary_tap_count` | `"1"`/`"2"`/`"3"` | no | which count's trends are open by default. Default `"2"` |
| `synthetic` | bool | no | `true` puts a "nothing here was measured" banner on the page |
| `pass_line` | object | yes | metric key → `{op, value, unit}` |
| `pass_line_overrides` | object | no | tap count → metric key → rule. See below |
| `rounds` | array | yes | one entry per round, any order; the renderer sorts by `round` |

`pass_line` operators: `>=`, `>`, `<=`, `<`, `==`. A metric absent from
`pass_line` renders as informational — a value, a trend, no verdict.

`pass_line_overrides` relaxes or tightens the line for one tap count, e.g.
`{"1": {"false_triggers_typing": {"op": "<=", "value": 3}}}`. It exists so a
written decision in `notes/DECISIONS.md` can be reflected on the page. Do not
use it to make a red column go green.

### Round

```json
{
  "round": 2,
  "label": "gate widened",
  "timestamp": "2026-08-14T14:20:00Z",
  "status": "scored",
  "headline": "typing clean on desk, lap still leaking",
  "biggest_gap": "Lap surface: 6 confound triggers from repositioning.",
  "source": {
    "tool": "tunk-score 0.1.0",
    "detector": "stub",
    "is_stub": true,
    "split": "test",
    "data_root": "/…/data/holdout",
    "warnings": ["Graded the HARNESS STUB detector, not a shipping detector."]
  },
  "dataset": { "sessions": 36, "minutes": 62.0, "tap_groups": {"1": 60, "2": 180, "3": 60} },
  "surfaces": { "desk": { … }, "soft": { … }, "lap": { … } }
}
```

| field | required | meaning |
|---|---|---|
| `round` | yes | integer, unique, ascending. Round 0 is the honest empty seed |
| `label` | yes | short name for the round, shown next to the number |
| `timestamp` | yes | ISO-8601, when the round was scored |
| `status` | no | `no_data`, `running` or `scored`. Anything else prints verbatim |
| `headline` | yes | one line, the lede on the page |
| `biggest_gap` | yes | the single biggest gap, free text. The critic writes this |
| `source` | no | what produced the numbers. **Send it.** See below |
| `dataset` | no | coverage across all surfaces, for the record |
| `surfaces` | yes | keyed by `surface` from FORMAT.md |

`source` is how the page stays honest about its own numbers. `is_stub: true` or
a non-empty `warnings` array puts a hatched banner above the verdict saying what
produced them. `warnings` is exactly `RunReport.warnings` from tunk-score.

### Surface

Keys are the `surface` values in FORMAT.md: `desk`, `soft`, `lap`. The renderer
shows them in that order, then anything else it finds. A pooled roll-up may be
added under the key `pooled`; it is labelled "not the pass line" because
FORMAT.md applies the bar to each surface separately.

```json
"desk": {
  "coverage": {
    "sessions": 12,
    "typing_minutes": 8.0,
    "confound_minutes": 6.0,
    "tap_groups": { "1": 20, "2": 60, "3": 20 }
  },
  "taps": {
    "2": {
      "metrics": {
        "detection_rate": { "value": 98.6, "n": 60 },
        "latency_p95_ms": { "value": 224, "n": 60, "pass": "pass", "note": "held-out only" }
      }
    }
  }
}
```

`coverage` is optional and free-form apart from `tap_groups`, which must be an
object keyed by tap count. The renderer knows `sessions`, `tap_groups`,
`typing_minutes` and `confound_minutes`; anything else it ignores.

### Tap counts

`taps` is required and must not be empty. Its keys are **strings**: `"1"`,
`"2"`, `"3"`, and `"any"`. Each tap count is graded on its own, because each is
bound to its own action on the iPhone Back Tap model — a single-tap false
trigger is a different failure from a double-tap one and the page must not
average them together.

- `"1"`, `"2"`, `"3"` — single, double, triple.
- `"any"` — metrics that belong to no single count. Renders as a fourth column.

Send every count you graded, even when it is terrible. Omit a count you did not
grade; the page shows only the columns present in the newest round, so a
double-tap-only run stays one column wide.

### Metric keys

Straight out of FORMAT.md's scoring section. Every key is optional; a missing
key and a `null` value both render as "no data", never as a pass.

| key | unit | better | pass line |
|---|---|---|---|
| `detection_rate` | % | higher | `>= 98` |
| `false_triggers_typing` | count | lower | `== 0` |
| `false_triggers_confound` | count | lower | `== 0` |
| `false_triggers_per_20min` | rate | lower | `< 1` |
| `latency_p50_ms` | ms | lower | informational |
| `latency_p95_ms` | ms | lower | `<= 250` |
| `latency_max_ms` | ms | lower | informational |
| `stuck_modifiers` | count | lower | `== 0` |

`detection_rate` is a **percentage**, 0–100, not a fraction. Latencies are
**milliseconds**, not nanoseconds. An unknown metric key is a hard error, not a
silently dropped field — `schema.py` names it and tells you the known set.

Metric entry fields:

| field | type | meaning |
|---|---|---|
| `value` | number or `null` | required. `null` means unmeasured. Not zero. Not passing |
| `n` | int | sample count behind the number (groups, sessions, whatever fits) |
| `pass` | `"pass"`/`"fail"`/`true`/`false`/absent | overrides the derived verdict; leave it out and the renderer applies `pass_line` |
| `note` | string | short caveat, listed under the surface's table |

Adding a metric means adding a row to `METRICS` in `web/schema.py`. Adding a
round, a surface or a tap count needs no code change.

### Smallest valid file

```json
{
  "schema": 2,
  "generated_at": "2026-08-14T14:25:00Z",
  "pass_line": { "detection_rate": { "op": ">=", "value": 98, "unit": "%" } },
  "rounds": [{
    "round": 0,
    "label": "bootstrap",
    "timestamp": "2026-08-14T14:20:00Z",
    "headline": "nothing recorded yet",
    "biggest_gap": "No dataset exists.",
    "surfaces": {
      "desk": { "taps": { "2": { "metrics": {
        "detection_rate": { "value": null, "n": 0 }
      } } } }
    }
  }]
}
```

### Schema 1

The pre-tap-count schema put `metrics` straight on the surface. `render.py` and
`ingest.py` still read it, lifting that block into tap count `"2"`, and warn.
Nothing is invented: a schema-1 file gains empty columns, not numbers.

## Mapping a tunk-score report onto this

`web/ingest.py --from-score` does it, and is the executable copy of this table.
Field names on the left are tunk-score's own (`Aggregate` in
`Sources/TunkScore/Scoring.swift`).

| Aggregate field | metric key | conversion |
|---|---|---|
| `detectionRate` | `detection_rate` | × 100 |
| `typingFalsePositives` | `false_triggers_typing` | as is, `null` when `typingSessions == 0` |
| `confoundFalsePositives` | `false_triggers_confound` | as is, `null` when `confoundSessions == 0` |
| `falsePositivesPer20Min` | `false_triggers_per_20min` | as is |
| `latencyP50Ns` / `P95Ns` / `MaxNs` | `latency_p50_ms` / `p95` / `max` | ÷ 1e6 |
| — | `stuck_modifiers` | `null`; replay emits no keys |

`perSurface[].label` names the surface. Without per-tap-count aggregates
everything lands in tap `"2"`; with them, `ingest.py` reads an optional
`perSurfaceTapCount` array whose elements are Aggregates carrying an extra
`tapCount` integer, and files each one under its own column.

If the harness would rather write `progress.json` itself, that is the better
path: build the round object above, hand it to
`python3 web/ingest.py --round <file>`, and let it validate, append and render.

## How the page shows its own age

A static page has one clock: its own load time. The page uses every honest
signal that gives it, and none that it does not.

| signal | needs JS | what it tells you |
|---|---|---|
| `generated_at`, printed absolutely | no | when the harness last wrote the file |
| build stamp, printed absolutely | no | when `render.py` last ran |
| age at build, in the headline | no | how old the data already was when the page was built. Past `stale_after_s` the whole bar renders stale, hatched and red-railed, with the number spelled out |
| CSS staleness clock | no | after `stale_after_s` **of the page being open**, a step animation flips the bar to the stale treatment (● → ■, hatch on, rail to red) and reveals "reload". A second step at `cold_after_s` |
| live age | yes | `progress.js` replaces the above with the real data age every 15 s |
| poll | yes | reloads when `generated_at` or the round count changes; says so after three failed fetches |

A `generated_at` in the future is called out as a broken clock rather than
smoothed into "fresh".

The CSS clock uses `steps(1, end)` and does nothing visible until the threshold,
so first paint is settled: the "no entrance animation" rule holds.

## How the page encodes a regression

The brief: a regression must be obvious without reading digits, through colour
**and** shape, so it survives a greyscale phone screenshot and colour-blind eyes.

| signal | pass | fail / regression |
|---|---|---|
| verdict glyph | filled circle `●` | filled square `■` (unmeasured: hollow diamond `◇`) |
| metric cell | flat tint | 45° hatch across the cell |
| cell rail | 3 px bottom rail, improved | 3 px bottom rail, regressed |
| tap-count chip | flat tint | hatch plus "▼ n worse" |
| card banner | absent | "▼ 20 metrics worse than round 2 (1× 7, 2× 7, 3× 6)" |
| delta text | `▲`/`▼` for which way the number moved, never whether that was good | same glyph, hatched cell |
| sparkline point | circle | square |
| sparkline last segment | thick, improving | thick, regressing, crossing the dashed pass line |
| folded trend section | "● on the line" in the summary | hatched summary, "▼ regressed", and forced open |
| unmeasured round | — | hollow diamond parked in the bottom gutter, off the value scale, so a blank round cannot be misread as a low reading |

Verified in a `filter: grayscale(1)` render at 390 px: the regressed rows on the
soft surface stay unmistakable with every hue removed.

## Reading it on a phone

Per-tap-count numbers are a matrix, not three stacked tables: metrics down the
side, `1×` `2×` `3×` across, two lines per cell (value with its verdict glyph,
then the delta and `n`). Above it sits a three-chip strip that says how each tap
count is doing before you read a single number. Trend sparklines fold into a
`<details>` per tap count — the primary count is open, a regressed count is
forced open, and a folded one still states its verdict in the summary.

## Constraints this page is held to

From `UI_STANDARD.md`, checked in the built page and by `web/selftest.py`:

- readable at 390 px, no horizontal scroll (`scrollWidth == clientWidth`)
- dark mode via `prefers-color-scheme`, both rendered and reviewed
- `-webkit-font-smoothing: antialiased` on the root
- `text-wrap: balance` on headings, `text-wrap: pretty` on body
- `font-variant-numeric: tabular-nums` on every number that changes
- `outline: 1px solid rgba(0,0,0,.1)` light / `rgba(255,255,255,.1)` dark on the
  sparkline frames — pure black and white, never a tinted neutral
- named transition properties, never `transition: all`; no `will-change`
- no entrance animation on first paint
- 40 px minimum hit area on every link and every `<summary>`
- `prefers-reduced-motion` drops the transitions to a cross-fade
