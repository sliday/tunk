# Live progress page

A phone-readable page the operator watches while the gauntlet loop runs. Plain
HTML and CSS, no framework, no bundler, no build step.

```
web/
  progress.json   the data. The harness and the lead agent append to it.
  render.py       regenerates index.html from progress.json
  index.html      GENERATED. Do not hand-edit.
  style.css       hand-written
  progress.js     optional enhancement (polling + relative timestamps)
```

## Workflow

```bash
# after appending a round to web/progress.json
python3 web/render.py

# CI / pre-commit: fail if index.html no longer matches progress.json
python3 web/render.py --check

# read a different file (handy for previewing a round before you commit it)
python3 web/render.py --json /tmp/candidate.json --out web/_preview.html
```

`index.html` is committed on purpose. The page must show the current numbers
with JavaScript off and over `file://`, so nothing is fetched at load time.
`progress.js` only polls `progress.json` every 20 s and reloads when
`generated_at` or the round count changes — so **re-run `render.py` after every
edit**, or a watching phone reloads into the same stale page.

## progress.json

Top level:

| field | type | meaning |
|---|---|---|
| `schema` | int | `1` |
| `title` | string | shown in `<title>` |
| `generated_at` | ISO-8601 UTC | when the harness last wrote this file |
| `pass_line` | object | metric key → `{op, value, unit}` |
| `rounds` | array | one entry per round, any order; the renderer sorts by `round` |

`pass_line` operators: `>=`, `>`, `<=`, `<`, `==`. A metric absent from
`pass_line` renders as informational — a value, a trend, no verdict.

### Round

```json
{
  "round": 2,
  "label": "gate widened",
  "timestamp": "2026-08-14T14:20:00Z",
  "status": "scored",
  "headline": "typing clean on desk, lap still leaking",
  "biggest_gap": "Lap surface: 6 confound triggers from repositioning.",
  "dataset": { "sessions": 36, "double_tap_groups": 180, "minutes": 62.0 },
  "surfaces": { "desk": { … }, "soft": { … }, "lap": { … } }
}
```

| field | required | meaning |
|---|---|---|
| `round` | yes | integer, ascending. Round 0 is the honest empty seed. |
| `label` | yes | short name for the round, shown next to the number |
| `timestamp` | yes | ISO-8601, when the round was scored |
| `status` | no | free text; `no_data`, `running`, `scored` are what we use |
| `headline` | yes | one line, the lede on the page |
| `biggest_gap` | yes | the free-text single biggest gap. The critic writes this. |
| `dataset` | no | coverage across all surfaces, for the record |
| `surfaces` | yes | keyed by `surface` from FORMAT.md |

### Surface

Keys are the `surface` values in FORMAT.md: `desk`, `soft`, `lap`. The renderer
shows them in that order, then anything else it finds. A pooled roll-up may be
added under the key `pooled`; it is labelled "not the pass line" because
FORMAT.md applies the bar to each surface separately.

```json
"desk": {
  "coverage": { "sessions": 12, "double_tap_groups": 60,
                "typing_minutes": 8.0, "confound_minutes": 6.0 },
  "metrics": {
    "detection_rate": { "value": 98.6, "n": 60 },
    "latency_p95_ms": { "value": 224, "n": 60, "pass": "pass", "note": "held-out only" }
  }
}
```

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

Metric entry fields:

| field | type | meaning |
|---|---|---|
| `value` | number or `null` | `null` means unmeasured. Not zero. Not passing. |
| `n` | int | sample count behind the number (groups, sessions, whatever fits) |
| `pass` | `"pass"`/`"fail"`/`true`/`false`/absent | overrides the derived verdict; leave it out and the renderer applies `pass_line` |
| `note` | string | short caveat, printed under the metric name |

Adding a metric means adding a row to `METRICS` in `render.py`. Adding a round
or a surface needs no code change.

## How the page encodes a regression

The brief: a regression must be obvious without reading digits, through colour
**and** shape, so it survives a greyscale phone screenshot and colour-blind eyes.

| signal | pass | fail / regression |
|---|---|---|
| verdict glyph | filled circle `●` | filled square `■` (unmeasured: hollow diamond `◇`) |
| metric row | flat tint | 45° hatch across the row |
| row rail | 3 px rail, improved | 3 px rail, regressed |
| delta chip | `▲`/`▼` for which way the number moved, never whether that was good | same glyph, hatched chip |
| sparkline point | circle | square |
| sparkline last segment | thick, improving | thick, regressing, crossing the dashed pass line |
| unmeasured round | — | hollow diamond parked in the bottom gutter, off the value scale, so a blank round cannot be misread as a low reading |

Verified in a `filter: grayscale(1)` render: the three regressed rows on the
soft surface stay unmistakable with every hue removed.

## Constraints this page is held to

From `UI_STANDARD.md`, checked in the built page:

- readable at 390 px, no horizontal scroll (`scrollWidth == clientWidth`)
- dark mode via `prefers-color-scheme`, both rendered and reviewed
- `-webkit-font-smoothing: antialiased` on the root
- `text-wrap: balance` on headings, `text-wrap: pretty` on body
- `font-variant-numeric: tabular-nums` on every number that changes
- `outline: 1px solid rgba(0,0,0,.1)` light / `rgba(255,255,255,.1)` dark on the
  sparkline frames — pure black and white, never a tinted neutral
- named transition properties, never `transition: all`; no `will-change`
- no entrance animation on first paint
- 40 px minimum hit area on every link
- `prefers-reduced-motion` drops the one transition to a cross-fade
