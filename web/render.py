#!/usr/bin/env python3
"""Regenerate web/index.html from web/progress.json.

No dependencies, no build step. Run it after every append to progress.json:

    python3 web/render.py

The generated page shows the current numbers with JavaScript disabled.
web/progress.js only adds polling and a relative-time stamp on top.
Schema lives in web/README.md.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import math
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent

# key, label, short label, unit, direction ("higher" or "lower" is better), decimals
METRICS = [
    ("detection_rate", "Detection rate", "detect", "%", "higher", 1),
    ("false_triggers_typing", "False triggers, typing", "FT typing", "", "lower", 0),
    ("false_triggers_confound", "False triggers, confounds", "FT confound", "", "lower", 0),
    ("false_triggers_per_20min", "False triggers per 20 min", "FT /20min", "", "lower", 2),
    ("latency_p50_ms", "Latency p50", "p50", "ms", "lower", 0),
    ("latency_p95_ms", "Latency p95", "p95", "ms", "lower", 0),
    ("latency_max_ms", "Latency max", "max", "ms", "lower", 0),
    ("stuck_modifiers", "Stuck modifiers", "stuck", "", "lower", 0),
]
METRIC_BY_KEY = {m[0]: m for m in METRICS}

# The four the run lives or dies on. These get sparklines.
SPARK_KEYS = [
    "detection_rate",
    "false_triggers_typing",
    "false_triggers_confound",
    "latency_p95_ms",
]

SURFACE_ORDER = ["desk", "soft", "lap"]
SURFACE_LABEL = {
    "desk": "Hard desk",
    "soft": "Soft surface",
    "lap": "On the lap",
    "pooled": "Pooled (not the pass line)",
}

STATUS_LABEL = {"pass": "pass", "fail": "fail", "none": "no data", "info": "info"}

OP_GLYPH = {">=": "≥", "<=": "≤", ">": ">", "<": "<", "==": "="}


# ---------------------------------------------------------------- pass/fail

def compare(op: str, value: float, target: float) -> bool:
    if op == ">=":
        return value >= target
    if op == ">":
        return value > target
    if op == "<=":
        return value <= target
    if op == "<":
        return value < target
    if op == "==":
        return value == target
    raise ValueError(f"unknown pass-line operator {op!r}")


def metric_status(key: str, entry: dict, pass_line: dict) -> str:
    """pass | fail | none | info. Honours an explicit 'pass' field if the
    harness wrote one, otherwise derives it from the pass line."""
    if entry is None:
        return "none"
    value = entry.get("value")
    if value is None:
        return "none"
    explicit = entry.get("pass")
    if explicit is True:
        return "pass"
    if explicit is False:
        return "fail"
    if isinstance(explicit, str) and explicit in ("pass", "fail", "info", "none"):
        return explicit
    rule = pass_line.get(key)
    if not rule:
        return "info"
    return "pass" if compare(rule["op"], value, rule["value"]) else "fail"


def worst(statuses) -> str:
    statuses = list(statuses)
    if "fail" in statuses:
        return "fail"
    if any(s == "none" for s in statuses):
        return "none"
    if "pass" in statuses:
        return "pass"
    return "info"


# ---------------------------------------------------------------- formatting

def fmt_value(key: str, value) -> str:
    if value is None:
        return "—"
    _, _, _, unit, _, decimals = METRIC_BY_KEY[key]
    text = f"{value:,.{decimals}f}" if decimals else f"{value:,.0f}"
    return f"{text}{unit}" if unit else text


def fmt_delta(key: str, cur, prev) -> tuple:
    """(class, glyph, text). class in improve|regress|flat|new.

    The glyph tracks which way the number moved, never whether that was good —
    a falling latency and a falling detection rate both get a down arrow. Good
    or bad is carried by the class, which the CSS renders as hue plus texture
    plus a rail, so it survives a greyscale screenshot."""
    if cur is None or prev is None:
        return ("new", "○", "first" if prev is None else "n/a")
    _, _, _, unit, direction, decimals = METRIC_BY_KEY[key]
    diff = cur - prev
    if abs(diff) < 10 ** (-(decimals + 2)):
        return ("flat", "=", "flat")
    better = diff > 0 if direction == "higher" else diff < 0
    sign = "+" if diff > 0 else "−"
    body = f"{abs(diff):,.{decimals}f}" if decimals else f"{abs(diff):,.0f}"
    text = f"{sign}{body}{unit}"
    return ("improve" if better else "regress", "▲" if diff > 0 else "▼", text)


def rule_text(rule: dict) -> str:
    op = OP_GLYPH.get(rule["op"], rule["op"])
    return f'{op} {rule["value"]}{rule.get("unit", "")}'


def iso_to_display(value: str) -> str:
    if not value:
        return "unknown"
    try:
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return value
    return stamp.strftime("%Y-%m-%d %H:%M UTC" if stamp.tzinfo else "%Y-%m-%d %H:%M")


def e(text) -> str:
    return html.escape("" if text is None else str(text), quote=True)


# ---------------------------------------------------------------- sparkline

def sparkline(key: str, series: list, statuses: list, pass_line: dict) -> str:
    """Inline SVG. Position carries the value, marker shape carries pass/fail,
    the final segment carries the direction of the last change. Static markup:
    no JavaScript, no webfont, no external asset."""
    w, h = 260.0, 66.0
    # left gutter holds the pass-line label so it never sits under a point
    pad_left, pad_right, pad_top, pad_bottom = 38.0, 12.0, 11.0, 20.0
    known = [v for v in series if v is not None]
    rule = pass_line.get(key)
    domain = list(known)
    if rule:
        domain.append(float(rule["value"]))
    if not domain:
        domain = [0.0, 1.0]
    lo, hi = min(domain), max(domain)
    if math.isclose(lo, hi):
        lo, hi = lo - 1.0, hi + 1.0
    span = hi - lo
    lo -= span * 0.15
    hi += span * 0.15
    n = len(series)

    def px(i):
        if n == 1:
            return (pad_left + w - pad_right) / 2
        return pad_left + (w - pad_left - pad_right) * (i / (n - 1))

    def py(v):
        return h - pad_bottom - (h - pad_top - pad_bottom) * ((v - lo) / (hi - lo))

    parts = [
        f'<svg class="spark" viewBox="0 0 {w:.0f} {h:.0f}" width="{w:.0f}" height="{h:.0f}" '
        f'role="img" aria-label="{e(METRIC_BY_KEY[key][1])} across {n} round'
        f'{"s" if n != 1 else ""}">'
    ]
    if rule:
        y = py(float(rule["value"]))
        parts.append(
            f'<line class="spark-rule" x1="{pad_left - 4:.0f}" y1="{y:.1f}" '
            f'x2="{w - 2:.0f}" y2="{y:.1f}" />'
        )
        label = f'{OP_GLYPH.get(rule["op"], rule["op"])}{rule["value"]}'
        parts.append(
            f'<text class="spark-rule-label" x="{pad_left - 8:.0f}" '
            f'y="{min(max(y + 3, 10), h - 14):.1f}" text-anchor="end">{e(label)}</text>'
        )

    # polyline segments, broken across gaps
    segment, segments = [], []
    for i, v in enumerate(series):
        if v is None:
            if len(segment) > 1:
                segments.append(segment)
            segment = []
        else:
            segment.append((i, px(i), py(v)))
    if len(segment) > 1:
        segments.append(segment)
    for seg in segments:
        pts = " ".join(f"{x:.1f},{y:.1f}" for _, x, y in seg)
        parts.append(f'<polyline class="spark-line" points="{pts}" />')

    # last change gets its own stroke so a regression reads as a shape, not a hue
    last_two = [(i, v) for i, v in enumerate(series) if v is not None][-2:]
    if len(last_two) == 2:
        (i0, v0), (i1, v1) = last_two
        cls, _, _ = fmt_delta(key, v1, v0)
        parts.append(
            f'<polyline class="spark-last spark-last--{cls}" '
            f'points="{px(i0):.1f},{py(v0):.1f} {px(i1):.1f},{py(v1):.1f}" />'
        )

    for i, v in enumerate(series):
        status = statuses[i]
        if v is None:
            # unmeasured rounds sit in the bottom gutter, off the value scale, so
            # a blank round can never be misread as a low reading
            y = h - 7.0
            parts.append(
                f'<path class="spark-dot spark-dot--none" d="M {px(i):.1f} {y - 4:.1f} '
                f'l 4 4 l -4 4 l -4 -4 z" />'
            )
            continue
        x, y = px(i), py(v)
        if status == "fail":
            parts.append(
                f'<rect class="spark-dot spark-dot--fail" x="{x - 3.6:.1f}" y="{y - 3.6:.1f}" '
                f'width="7.2" height="7.2" />'
            )
        elif status == "pass":
            parts.append(
                f'<circle class="spark-dot spark-dot--pass" cx="{x:.1f}" cy="{y:.1f}" r="3.6" />'
            )
        else:
            parts.append(
                f'<circle class="spark-dot spark-dot--info" cx="{x:.1f}" cy="{y:.1f}" r="3.2" />'
            )
    parts.append("</svg>")
    return "".join(parts)


# ---------------------------------------------------------------- components

def status_pill(status: str) -> str:
    glyph = {"pass": "●", "fail": "■", "none": "◇", "info": "○"}[status]
    return (
        f'<span class="pill pill--{status}"><span class="pill-glyph" aria-hidden="true">'
        f'{glyph}</span><span class="pill-label">{e(STATUS_LABEL[status])}</span></span>'
    )


def metric_row(key: str, entry: dict, prev_entry: dict, pass_line: dict) -> str:
    label = METRIC_BY_KEY[key][1]
    value = (entry or {}).get("value")
    prev_value = (prev_entry or {}).get("value")
    status = metric_status(key, entry, pass_line)
    dcls, dglyph, dtext = fmt_delta(key, value, prev_value)
    rule = pass_line.get(key)
    target = rule_text(rule) if rule else "no pass line"
    note = (entry or {}).get("note")
    n = (entry or {}).get("n")
    sub = target
    if n is not None:
        sub += f" · n={n}"
    if note:
        sub += f" · {note}"
    return (
        f'<tr class="metric metric--{status} metric--d-{dcls}">'
        f'<th scope="row"><span class="metric-name">{e(label)}</span>'
        f'<span class="metric-sub">{e(sub)}</span></th>'
        f'<td class="metric-value">{e(fmt_value(key, value))}</td>'
        f'<td class="metric-delta"><span class="delta delta--{dcls}">'
        f'<span class="delta-glyph" aria-hidden="true">{dglyph}</span>{e(dtext)}</span></td>'
        f'<td class="metric-status">{status_pill(status)}</td>'
        f"</tr>"
    )


def surface_card(surface: str, round_obj: dict, prev_round: dict, pass_line: dict) -> str:
    metrics = round_obj["surfaces"][surface].get("metrics", {})
    prev_metrics = {}
    if prev_round and surface in prev_round.get("surfaces", {}):
        prev_metrics = prev_round["surfaces"][surface].get("metrics", {})
    statuses = [metric_status(k, metrics.get(k), pass_line) for k, *_ in METRICS]
    card_status = worst(statuses)
    regressions = sum(
        1
        for k, *_ in METRICS
        if fmt_delta(k, (metrics.get(k) or {}).get("value"),
                     (prev_metrics.get(k) or {}).get("value"))[0] == "regress"
    )
    cov = round_obj["surfaces"][surface].get("coverage", {})
    cov_bits = []
    if cov.get("sessions") is not None:
        cov_bits.append(f'{cov["sessions"]} sessions')
    if cov.get("double_tap_groups") is not None:
        cov_bits.append(f'{cov["double_tap_groups"]} double-tap groups')
    if cov.get("typing_minutes") is not None:
        cov_bits.append(f'{cov["typing_minutes"]:g} min typing')
    if cov.get("confound_minutes") is not None:
        cov_bits.append(f'{cov["confound_minutes"]:g} min confounds')

    rows = "".join(
        metric_row(k, metrics.get(k), prev_metrics.get(k), pass_line) for k, *_ in METRICS
    )
    reg_note = (
        f'<p class="card-regress"><span aria-hidden="true">▼</span> '
        f'{regressions} metric{"s" if regressions != 1 else ""} worse than round '
        f'{prev_round["round"]}</p>'
        if regressions
        else ""
    )
    return (
        f'<article class="card card--{card_status}">'
        f'<header class="card-head">'
        f'<h3>{e(SURFACE_LABEL.get(surface, surface))}</h3>'
        f"{status_pill(card_status)}"
        f"</header>"
        f'<p class="card-coverage">{e(" · ".join(cov_bits)) or "no coverage recorded"}</p>'
        f"{reg_note}"
        f'<table class="metrics">'
        f'<caption class="sr-only">{e(SURFACE_LABEL.get(surface, surface))} metrics for round '
        f'{round_obj["round"]}</caption>'
        f"<thead><tr><th scope=\"col\">Metric</th><th scope=\"col\">Value</th>"
        f"<th scope=\"col\">vs prev</th><th scope=\"col\">Verdict</th></tr></thead>"
        f"<tbody>{rows}</tbody></table>"
        f"</article>"
    )


def trend_block(surface: str, rounds: list, pass_line: dict) -> str:
    cells = []
    for key in SPARK_KEYS:
        series, statuses = [], []
        for r in rounds:
            entry = r.get("surfaces", {}).get(surface, {}).get("metrics", {}).get(key)
            series.append((entry or {}).get("value"))
            statuses.append(metric_status(key, entry, pass_line))
        last_two = [v for v in series if v is not None][-2:]
        if len(last_two) == 2:
            dcls, dglyph, dtext = fmt_delta(key, last_two[1], last_two[0])
        else:
            dcls, dglyph, dtext = ("new", "○", "first")
        cells.append(
            f'<figure class="trend trend--{dcls}">'
            f'<figcaption><span class="trend-name">{e(METRIC_BY_KEY[key][1])}</span>'
            f'<span class="delta delta--{dcls}"><span class="delta-glyph" aria-hidden="true">'
            f"{dglyph}</span>{e(dtext)}</span></figcaption>"
            f"{sparkline(key, series, statuses, pass_line)}"
            f'<p class="trend-foot">round {rounds[0]["round"]} → {rounds[-1]["round"]} '
            f"· latest {e(fmt_value(key, series[-1]))}</p>"
            f"</figure>"
        )
    return (
        f'<section class="trend-group">'
        f"<h3>{e(SURFACE_LABEL.get(surface, surface))}</h3>"
        f'<div class="trend-grid">{"".join(cells)}</div>'
        f"</section>"
    )


def round_log(rounds: list, pass_line: dict) -> str:
    items = []
    for r in reversed(rounds):
        statuses = []
        for surface in r.get("surfaces", {}):
            for k, *_ in METRICS:
                statuses.append(
                    metric_status(k, r["surfaces"][surface].get("metrics", {}).get(k), pass_line)
                )
        status = worst(statuses)
        items.append(
            f'<li class="log-item log-item--{status}">'
            f'<div class="log-head"><h3>Round {e(r["round"])}'
            f'<span class="log-label">{e(r.get("label", ""))}</span></h3>'
            f"{status_pill(status)}</div>"
            f'<p class="log-time"><time datetime="{e(r.get("timestamp", ""))}" '
            f'data-relative>{e(iso_to_display(r.get("timestamp", "")))}</time></p>'
            f'<p class="log-headline">{e(r.get("headline", ""))}</p>'
            f'<p class="log-gap"><span class="log-gap-tag">biggest gap</span>'
            f'{e(r.get("biggest_gap", "not stated"))}</p>'
            f"</li>"
        )
    return f'<ol class="log">{"".join(items)}</ol>'


def pass_line_table(pass_line: dict) -> str:
    rows = []
    for key, *_ in METRICS:
        rule = pass_line.get(key)
        target = rule_text(rule) if rule else "—"
        rows.append(
            f'<tr><th scope="row">{e(METRIC_BY_KEY[key][1])}</th>'
            f'<td class="metric-value">{e(target)}</td></tr>'
        )
    return (
        f'<table class="metrics metrics--passline">'
        f'<caption class="sr-only">Pass line from FORMAT.md</caption>'
        f'<thead><tr><th scope="col">Metric</th><th scope="col">Pass</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
    )


# ---------------------------------------------------------------- page

def render(data: dict) -> str:
    rounds = sorted(data.get("rounds", []), key=lambda r: r["round"])
    if not rounds:
        raise SystemExit("progress.json has no rounds")
    pass_line = data.get("pass_line", {})
    latest = rounds[-1]
    prev = rounds[-2] if len(rounds) > 1 else None
    surfaces = [s for s in SURFACE_ORDER if s in latest.get("surfaces", {})]
    surfaces += [s for s in latest.get("surfaces", {}) if s not in surfaces]

    all_statuses = []
    for surface in surfaces:
        metrics = latest["surfaces"][surface].get("metrics", {})
        all_statuses += [metric_status(k, metrics.get(k), pass_line) for k, *_ in METRICS]
    overall = worst(all_statuses)
    n_fail = all_statuses.count("fail")
    n_pass = all_statuses.count("pass")
    n_none = all_statuses.count("none")

    verdict_text = {
        "pass": "Every scored metric is on the pass line.",
        "fail": f"{n_fail} metric{'s' if n_fail != 1 else ''} below the pass line.",
        "none": "Nothing measured yet. Blank is not green.",
        "info": "No pass-line metric has been scored.",
    }[overall]

    cards = "".join(surface_card(s, latest, prev, pass_line) for s in surfaces)
    trends = "".join(trend_block(s, rounds, pass_line) for s in surfaces)

    generated = data.get("generated_at", "")
    title = data.get("title", "Tunk progress")

    return f"""<!doctype html>
<!-- GENERATED by web/render.py from web/progress.json. Do not hand-edit. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<title>Round {e(latest['round'])} · {e(title)}</title>
<link rel="stylesheet" href="style.css">
</head>
<body data-overall="{e(overall)}">
<a class="skip" href="#now">Skip to current numbers</a>

<header class="page-head">
  <p class="eyebrow">Tunk · gauntlet loop</p>
  <h1>Round {e(latest['round'])}: {e(latest.get('label', ''))}</h1>
  <p class="lede">{e(latest.get('headline', ''))}</p>
  <p class="stamp">
    <time datetime="{e(generated)}" data-relative>{e(iso_to_display(generated))}</time>
    · {len(rounds)} round{'s' if len(rounds) != 1 else ''} recorded
  </p>
</header>

<main>
  <section class="verdict verdict--{e(overall)}" aria-labelledby="verdict-h">
    <h2 id="verdict-h" class="verdict-title">{status_pill(overall)} {e(verdict_text)}</h2>
    <ul class="tally">
      <li class="tally-item tally-item--pass"><span class="tally-n">{n_pass}</span> on the line</li>
      <li class="tally-item tally-item--fail"><span class="tally-n">{n_fail}</span> below it</li>
      <li class="tally-item tally-item--none"><span class="tally-n">{n_none}</span> unmeasured</li>
    </ul>
    <p class="verdict-gap"><span class="log-gap-tag">biggest gap</span>
      {e(latest.get('biggest_gap', 'not stated'))}</p>
  </section>

  <section id="now" aria-labelledby="now-h">
    <h2 id="now-h">Current numbers, per surface</h2>
    <p class="section-note">The pass line applies to each surface on its own, never to the
      pooled average. A row with diagonal hatching got worse than the previous round.</p>
    <div class="cards">{cards}</div>
  </section>

  <section id="trend" aria-labelledby="trend-h">
    <h2 id="trend-h">Trend across rounds</h2>
    <p class="section-note">Dashed line is the pass line. Round circle means on the line,
      square means below it, hollow diamond means unmeasured. The last segment is drawn
      heavy when a metric moved.</p>
    {trends}
  </section>

  <section id="log" aria-labelledby="log-h">
    <h2 id="log-h">Round log</h2>
    {round_log(rounds, pass_line)}
  </section>

  <section id="passline" aria-labelledby="passline-h">
    <h2 id="passline-h">The pass line</h2>
    <p class="section-note">From <code>FORMAT.md</code>. Not relaxed without data.</p>
    {pass_line_table(pass_line)}
  </section>
</main>

<footer class="page-foot">
  <p>Regenerate with <code>python3 web/render.py</code> after appending to
    <code>web/progress.json</code>. This page needs no JavaScript; the script only adds
    polling and relative timestamps.</p>
  <p class="foot-links">
    <a href="progress.json">progress.json</a>
    <a href="README.md">schema</a>
  </p>
</footer>
<script src="progress.js" defer></script>
</body>
</html>
"""


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", default=str(HERE / "progress.json"))
    ap.add_argument("--out", default=str(HERE / "index.html"))
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if index.html is stale, write nothing")
    args = ap.parse_args(argv)

    data = json.loads(pathlib.Path(args.json).read_text(encoding="utf-8"))
    page = render(data)
    out = pathlib.Path(args.out)
    if args.check:
        current = out.read_text(encoding="utf-8") if out.exists() else ""
        if current != page:
            print(f"{out} is stale; run python3 {__file__}", file=sys.stderr)
            return 1
        print(f"{out} is up to date")
        return 0
    out.write_text(page, encoding="utf-8")
    print(f"wrote {out} ({len(page):,} bytes) from {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
