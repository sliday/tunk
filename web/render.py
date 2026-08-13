#!/usr/bin/env python3
"""Regenerate web/index.html from web/progress.json.

No dependencies, no build step. Run it after every append to progress.json:

    python3 web/render.py

The generated page shows the current numbers with JavaScript disabled, and it
carries its own build timestamp so a reader can see how old the numbers are
without running any script. web/progress.js only sharpens that: it turns the
absolute stamps into relative ones and polls for a newer file.

The contract for progress.json lives in web/README.md and is enforced by
web/schema.py.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import math
import pathlib
import re
import sys

import schema as S

HERE = pathlib.Path(__file__).resolve().parent

# The four the run lives or dies on. These get sparklines.
SPARK_KEYS = [
    "detection_rate",
    "false_triggers_typing",
    "false_triggers_confound",
    "latency_p95_ms",
]

STATUS_LABEL = {"pass": "pass", "fail": "fail", "none": "no data", "info": "info"}
STATUS_GLYPH = {"pass": "●", "fail": "■", "none": "◇", "info": "○"}

ROUND_STATUS_LABEL = {"no_data": "no data", "running": "running", "scored": "scored"}

OP_GLYPH = {">=": "≥", "<=": "≤", ">": ">", "<": "<", "==": "="}

BUILD_META_RE = re.compile(r'<meta name="tunk-build" content="([^"]*)">')


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


def rule_for(key: str, tap: str, pass_line: dict, overrides: dict) -> dict | None:
    """The pass line for one metric at one tap count. A tap-count override wins;
    absent that, the surface-wide rule applies to every tap count."""
    over = (overrides or {}).get(tap, {})
    if key in over:
        return over[key]
    return (pass_line or {}).get(key)


def metric_status(key: str, entry: dict, tap: str, pass_line: dict, overrides: dict) -> str:
    """pass | fail | none | info. Honours an explicit 'pass' field if the harness
    wrote one, otherwise derives it from the pass line."""
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
    rule = rule_for(key, tap, pass_line, overrides)
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
    _, _, _, unit, _, decimals = S.METRIC_BY_KEY[key]
    text = f"{value:,.{decimals}f}" if decimals else f"{value:,.0f}"
    return f"{text}{unit}" if unit else text


def fmt_delta(key: str, cur, prev) -> tuple:
    """(class, glyph, text). class in improve|regress|flat|new.

    The glyph tracks which way the number moved, never whether that was good — a
    falling latency and a falling detection rate both get a down arrow. Good or
    bad is carried by the class, which the CSS renders as hue plus texture plus a
    rail, so it survives a greyscale screenshot."""
    if cur is None or prev is None:
        return ("new", "○", "first" if prev is None else "n/a")
    _, _, _, unit, direction, decimals = S.METRIC_BY_KEY[key]
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
    stamp = S.parse_iso(value)
    if stamp is None:
        return value or "unknown"
    return stamp.astimezone(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")


def fmt_age(seconds: float) -> str:
    """Coarse and honest. Never rounds an hour down to minutes."""
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds} s"
    if seconds < 3600:
        return f"{seconds // 60} min"
    if seconds < 86400:
        hours, mins = divmod(seconds // 60, 60)
        return f"{hours} h {mins:02d} min"
    days, hours = divmod(seconds // 3600, 24)
    return f"{days} d {hours:02d} h"


def e(text) -> str:
    return html.escape("" if text is None else str(text), quote=True)


# ---------------------------------------------------------------- lookups

def metrics_at(round_obj, surface: str, tap: str) -> dict:
    if not round_obj:
        return {}
    surf = (round_obj.get("surfaces") or {}).get(surface)
    if not surf:
        return {}
    block = (surf.get("taps") or {}).get(tap)
    if not block:
        return {}
    return block.get("metrics") or {}


def tap_columns(round_obj) -> list:
    """Every tap count the latest round mentions, in 1, 2, 3, any order."""
    keys = set()
    for surf in (round_obj.get("surfaces") or {}).values():
        keys.update((surf.get("taps") or {}).keys())
    return sorted(keys, key=S.tap_sort_key)


def surface_columns(round_obj) -> list:
    return sorted((round_obj.get("surfaces") or {}).keys(), key=S.surface_sort_key)


# ---------------------------------------------------------------- sparkline

def sparkline(key: str, tap: str, series: list, statuses: list,
              pass_line: dict, overrides: dict) -> str:
    """Inline SVG. Position carries the value, marker shape carries pass/fail, the
    final segment carries the direction of the last change. Static markup: no
    JavaScript, no webfont, no external asset."""
    w, h = 260.0, 66.0
    # left gutter holds the pass-line label so it never sits under a point
    pad_left, pad_right, pad_top, pad_bottom = 38.0, 12.0, 11.0, 20.0
    known = [v for v in series if v is not None]
    rule = rule_for(key, tap, pass_line, overrides)
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
        f'role="img" aria-label="{e(S.METRIC_BY_KEY[key][1])}, {e(S.TAP_LABEL[tap].lower())}, '
        f'across {n} round{"s" if n != 1 else ""}">'
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

def status_pill(status: str, label: str | None = None) -> str:
    return (
        f'<span class="pill pill--{status}"><span class="pill-glyph" aria-hidden="true">'
        f'{STATUS_GLYPH[status]}</span><span class="pill-label">'
        f"{e(label or STATUS_LABEL[status])}</span></span>"
    )


def metric_cell(key: str, tap: str, entry: dict, prev_entry: dict,
                pass_line: dict, overrides: dict) -> str:
    value = (entry or {}).get("value")
    prev_value = (prev_entry or {}).get("value")
    status = metric_status(key, entry, tap, pass_line, overrides)
    dcls, dglyph, dtext = fmt_delta(key, value, prev_value)
    n = (entry or {}).get("n")
    sub = dtext if n is None else f"{dtext} · n={n}"
    reader = f"{S.TAP_LABEL[tap]}: {fmt_value(key, value)}, {STATUS_LABEL[status]}, {dtext}"
    return (
        f'<td class="cell cell--{status} cell--d-{dcls}">'
        f'<span class="sr-only">{e(reader)}</span>'
        f'<span class="cell-top" aria-hidden="true">'
        f'<span class="cell-glyph">{STATUS_GLYPH[status]}</span>'
        f'<span class="cell-value">{e(fmt_value(key, value))}</span></span>'
        f'<span class="cell-sub" aria-hidden="true">'
        f'<span class="delta-glyph">{dglyph}</span>{e(sub)}</span>'
        f"</td>"
    )


def tap_strip(surface: str, round_obj: dict, prev_round: dict, taps: list,
              pass_line: dict, overrides: dict) -> str:
    chips = []
    for tap in taps:
        metrics = metrics_at(round_obj, surface, tap)
        prev_metrics = metrics_at(prev_round, surface, tap)
        statuses = [metric_status(k, metrics.get(k), tap, pass_line, overrides)
                    for k in S.METRIC_KEYS]
        status = worst(statuses)
        regressions = sum(
            1 for k in S.METRIC_KEYS
            if fmt_delta(k, (metrics.get(k) or {}).get("value"),
                         (prev_metrics.get(k) or {}).get("value"))[0] == "regress"
        )
        bits = []
        if statuses.count("fail"):
            bits.append(f'{statuses.count("fail")} below')
        if statuses.count("pass"):
            bits.append(f'{statuses.count("pass")} on')
        if statuses.count("none"):
            bits.append(f'{statuses.count("none")} unmeasured')
        chips.append(
            f'<li class="tapchip tapchip--{status}'
            f'{" tapchip--regress" if regressions else ""}">'
            f'<span class="tapchip-glyph" aria-hidden="true">{STATUS_GLYPH[status]}</span>'
            f'<span class="tapchip-name">{e(S.TAP_LABEL[tap])}</span>'
            f'<span class="tapchip-sub">{e(" · ".join(bits) or "no metrics")}</span>'
            + (f'<span class="tapchip-reg"><span aria-hidden="true">▼</span>'
               f'{regressions} worse</span>' if regressions else "")
            + "</li>"
        )
    return f'<ul class="tapstrip">{"".join(chips)}</ul>'


def surface_card(surface: str, round_obj: dict, prev_round: dict, taps: list,
                 pass_line: dict, overrides: dict) -> str:
    statuses, regress_by_tap = [], {}
    for tap in taps:
        metrics = metrics_at(round_obj, surface, tap)
        prev_metrics = metrics_at(prev_round, surface, tap)
        statuses += [metric_status(k, metrics.get(k), tap, pass_line, overrides)
                     for k in S.METRIC_KEYS]
        regress_by_tap[tap] = sum(
            1 for k in S.METRIC_KEYS
            if fmt_delta(k, (metrics.get(k) or {}).get("value"),
                         (prev_metrics.get(k) or {}).get("value"))[0] == "regress"
        )
    card_status = worst(statuses)
    regressions = sum(regress_by_tap.values())

    cov = (round_obj["surfaces"][surface].get("coverage") or {})
    cov_bits = []
    if cov.get("sessions") is not None:
        cov_bits.append(f'{cov["sessions"]} sessions')
    groups = cov.get("tap_groups") or {}
    if groups:
        pairs = " ".join(
            f"{S.TAP_SHORT.get(t, t)} {groups[t]}" for t in sorted(groups, key=S.tap_sort_key)
        )
        cov_bits.append(f"tap groups {pairs}")
    if cov.get("typing_minutes") is not None:
        cov_bits.append(f'{cov["typing_minutes"]:g} min typing')
    if cov.get("confound_minutes") is not None:
        cov_bits.append(f'{cov["confound_minutes"]:g} min confounds')

    head_cells = "".join(
        f'<th scope="col"><abbr title="{e(S.TAP_LABEL[t])}">{e(S.TAP_SHORT[t])}</abbr></th>'
        for t in taps
    )
    rows, notes = [], []
    for key in S.METRIC_KEYS:
        cells = []
        for tap in taps:
            entry = metrics_at(round_obj, surface, tap).get(key)
            prev_entry = metrics_at(prev_round, surface, tap).get(key)
            cells.append(metric_cell(key, tap, entry, prev_entry, pass_line, overrides))
            note = (entry or {}).get("note")
            if note:
                notes.append(f"{S.TAP_SHORT[tap]} {S.METRIC_BY_KEY[key][1]}: {note}")
        rule = rule_for(key, taps[0] if taps else "2", pass_line, overrides)
        target = rule_text(rule) if rule else "no pass line"
        rows.append(
            f'<tr class="metric">'
            f'<th scope="row"><span class="metric-name">{e(S.METRIC_BY_KEY[key][1])}</span>'
            f'<span class="metric-sub">{e(target)}</span></th>'
            + "".join(cells)
            + "</tr>"
        )

    reg_note = ""
    if regressions:
        detail = ", ".join(
            f"{S.TAP_SHORT[t]} {n}" for t, n in regress_by_tap.items() if n
        )
        reg_note = (
            f'<p class="card-regress"><span aria-hidden="true">▼</span> '
            f'{regressions} metric{"s" if regressions != 1 else ""} worse than round '
            f'{prev_round["round"]} ({e(detail)})</p>'
        )
    note_list = ""
    if notes:
        note_list = (
            '<ul class="card-notes">'
            + "".join(f"<li>{e(n)}</li>" for n in notes)
            + "</ul>"
        )

    return (
        f'<article class="card card--{card_status}">'
        f'<header class="card-head">'
        f"<h3>{e(S.SURFACE_LABEL.get(surface, surface))}</h3>"
        f"{status_pill(card_status)}"
        f"</header>"
        f'<p class="card-coverage">{e(" · ".join(cov_bits)) or "no coverage recorded"}</p>'
        f"{tap_strip(surface, round_obj, prev_round, taps, pass_line, overrides)}"
        f"{reg_note}"
        f'<table class="metrics metrics--matrix">'
        f'<caption class="sr-only">{e(S.SURFACE_LABEL.get(surface, surface))} metrics for round '
        f'{round_obj["round"]}, one column per tap count</caption>'
        f'<thead><tr><th scope="col">Metric</th>{head_cells}</tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
        f"{note_list}"
        f"</article>"
    )


def trend_block(surface: str, rounds: list, taps: list, primary: str,
                pass_line: dict, overrides: dict) -> str:
    blocks = []
    for tap in taps:
        cells = []
        regressed = False
        for key in SPARK_KEYS:
            series, statuses = [], []
            for r in rounds:
                entry = metrics_at(r, surface, tap).get(key)
                series.append((entry or {}).get("value"))
                statuses.append(metric_status(key, entry, tap, pass_line, overrides))
            known = [v for v in series if v is not None][-2:]
            if len(known) == 2:
                dcls, dglyph, dtext = fmt_delta(key, known[1], known[0])
            else:
                dcls, dglyph, dtext = ("new", "○", "first")
            regressed = regressed or dcls == "regress"
            cells.append(
                f'<figure class="trend trend--{dcls}">'
                f'<figcaption><span class="trend-name">{e(S.METRIC_BY_KEY[key][1])}</span>'
                f'<span class="delta delta--{dcls}"><span class="delta-glyph" aria-hidden="true">'
                f"{dglyph}</span>{e(dtext)}</span></figcaption>"
                f"{sparkline(key, tap, series, statuses, pass_line, overrides)}"
                f'<p class="trend-foot">round {rounds[0]["round"]} → {rounds[-1]["round"]} '
                f"· latest {e(fmt_value(key, series[-1]))}</p>"
                f"</figure>"
            )
        # A folded section still has to answer "is this one all right?", so the
        # summary carries the latest verdict, and a regressed count is never
        # folded away at all: shape and hatch on the summary carry it even when
        # the reader never opens the section.
        latest_metrics = metrics_at(rounds[-1], surface, tap)
        latest_statuses = [metric_status(k, latest_metrics.get(k), tap, pass_line, overrides)
                           for k in S.METRIC_KEYS]
        latest = worst(latest_statuses)
        n_bad = latest_statuses.count("fail")
        n_missing = latest_statuses.count("none")
        if n_bad:
            state = f'{n_bad} below the line'
        elif n_missing == len(latest_statuses):
            state = "unmeasured"
        elif n_missing:
            state = f"{n_missing} unmeasured"
        else:
            state = "on the line"
        open_attr = " open" if (tap == primary or regressed) else ""
        summary_flag = (
            '<span class="trend-flag"><span aria-hidden="true">▼</span> regressed</span>'
            if regressed else ""
        )
        blocks.append(
            f'<details class="trend-details{" trend-details--regress" if regressed else ""}"'
            f"{open_attr}>"
            f'<summary><span class="trend-tap">{e(S.TAP_LABEL[tap])}</span>'
            f'<span class="trend-state trend-state--{latest}">'
            f'<span aria-hidden="true">{STATUS_GLYPH[latest]}</span> {e(state)}</span>'
            f"{summary_flag}</summary>"
            f'<div class="trend-grid">{"".join(cells)}</div>'
            f"</details>"
        )
    return (
        f'<section class="trend-group">'
        f"<h3>{e(S.SURFACE_LABEL.get(surface, surface))}</h3>"
        f'{"".join(blocks)}'
        f"</section>"
    )


def round_log(rounds: list, pass_line: dict, overrides: dict) -> str:
    items = []
    for r in reversed(rounds):
        statuses = []
        for surface in r.get("surfaces", {}):
            for tap in (r["surfaces"][surface].get("taps") or {}):
                metrics = metrics_at(r, surface, tap)
                statuses += [metric_status(k, metrics.get(k), tap, pass_line, overrides)
                             for k in S.METRIC_KEYS]
        status = worst(statuses)
        rstatus = r.get("status")
        chip = (
            f'<span class="log-status">{e(ROUND_STATUS_LABEL.get(rstatus, rstatus))}</span>'
            if rstatus else ""
        )
        src = r.get("source") or {}
        src_bits = []
        if src.get("tool"):
            src_bits.append(src["tool"])
        if src.get("detector"):
            src_bits.append(f'detector {src["detector"]}')
        if src.get("split"):
            src_bits.append(f'split {src["split"]}')
        src_line = (
            f'<p class="log-source">{e(" · ".join(src_bits))}</p>' if src_bits else ""
        )
        warns = "".join(
            f'<li>{e(w)}</li>' for w in (src.get("warnings") or [])
        )
        warn_block = f'<ul class="log-warnings">{warns}</ul>' if warns else ""
        items.append(
            f'<li class="log-item log-item--{status}">'
            f'<div class="log-head"><h3>Round {e(r["round"])}'
            f'<span class="log-label">{e(r.get("label", ""))}</span>{chip}</h3>'
            f"{status_pill(status)}</div>"
            f'<p class="log-time"><time datetime="{e(r.get("timestamp", ""))}" '
            f'data-relative>{e(iso_to_display(r.get("timestamp", "")))}</time></p>'
            f'<p class="log-headline">{e(r.get("headline", ""))}</p>'
            f'<p class="log-gap"><span class="log-gap-tag">biggest gap</span>'
            f'{e(r.get("biggest_gap", "not stated"))}</p>'
            f"{src_line}{warn_block}"
            f"</li>"
        )
    return f'<ol class="log">{"".join(items)}</ol>'


def pass_line_table(pass_line: dict, overrides: dict, taps: list) -> str:
    # One line for every tap count unless a written decision says otherwise, so
    # the table stays one column wide until an override actually exists.
    if not overrides:
        rows = []
        for key in S.METRIC_KEYS:
            rule = (pass_line or {}).get(key)
            rows.append(
                f'<tr><th scope="row">{e(S.METRIC_BY_KEY[key][1])}</th>'
                f'<td class="metric-value">{e(rule_text(rule) if rule else "—")}</td></tr>'
            )
        return (
            f'<table class="metrics metrics--passline">'
            f'<caption class="sr-only">Pass line from FORMAT.md, the same for every '
            f"tap count</caption>"
            f'<thead><tr><th scope="col">Metric</th>'
            f'<th scope="col">Pass, every tap count</th></tr></thead>'
            f'<tbody>{"".join(rows)}</tbody></table>'
        )

    rows = []
    for key in S.METRIC_KEYS:
        base = (pass_line or {}).get(key)
        cells = []
        for tap in taps:
            rule = rule_for(key, tap, pass_line, overrides)
            same = rule is base
            cells.append(
                f'<td class="metric-value{"" if same else " metric-value--override"}">'
                f'{e(rule_text(rule) if rule else "—")}</td>'
            )
        rows.append(
            f'<tr><th scope="row">{e(S.METRIC_BY_KEY[key][1])}</th>{"".join(cells)}</tr>'
        )
    head = "".join(
        f'<th scope="col"><abbr title="{e(S.TAP_LABEL[t])}">{e(S.TAP_SHORT[t])}</abbr></th>'
        for t in taps
    )
    return (
        f'<table class="metrics metrics--passline">'
        f'<caption class="sr-only">Pass line from FORMAT.md, per tap count</caption>'
        f'<thead><tr><th scope="col">Metric</th>{head}</tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table>'
    )


# ---------------------------------------------------------------- freshness

def freshness_block(data: dict, rounds: list, built_at: dt.datetime) -> tuple:
    """(level, html). Everything here is decided at render time and baked in, so
    the page still answers "how old is this?" with JavaScript off."""
    stale_after = int(data.get("stale_after_s", S.DEFAULT_STALE_AFTER_S))
    cold_after = int(data.get("cold_after_s", S.DEFAULT_COLD_AFTER_S))
    generated = S.parse_iso(data.get("generated_at"))
    latest_stamp = S.parse_iso(rounds[-1].get("timestamp"))

    if generated is None:
        age = None
        level = "unknown"
    else:
        age = (built_at - generated).total_seconds()
        if age < -60:
            # A stamp in the future means somebody's clock is wrong. Saying
            # "fresh" here would be a guess dressed up as a fact.
            level = "future"
        else:
            age = max(age, 0.0)
            level = "cold" if age >= cold_after else ("stale" if age >= stale_after else "fresh")

    lag = None
    if generated is not None and latest_stamp is not None:
        lag = (generated - latest_stamp).total_seconds()

    if level == "fresh":
        head = f"Data written {fmt_age(age)} before this page was built"
    elif level == "unknown":
        head = "This file carries no generated_at stamp — its age is unknown"
    elif level == "future":
        head = "progress.json is stamped in the future — its age cannot be trusted"
    else:
        head = f"STALE — the numbers were already {fmt_age(age)} old when this page was built"

    # A fresh page carries both glyphs: the CSS clock below swaps them once the
    # page has been open past the threshold, so the shape changes with the state
    # even where hue is unavailable.
    if level == "fresh":
        glyphs = ('<span class="fresh-glyphs" aria-hidden="true">'
                  '<span class="fresh-glyph fresh-glyph--now">●</span>'
                  '<span class="fresh-glyph fresh-glyph--aged">■</span></span>')
    else:
        aged = "◇" if level in ("unknown", "future") else "■"
        glyphs = ('<span class="fresh-glyphs" aria-hidden="true">'
                  f'<span class="fresh-glyph fresh-glyph--now">{aged}</span></span>')

    warn_build = ""
    if level in ("stale", "cold"):
        warn_build = (
            f'<p class="fresh-warn fresh-warn--build">'
            f'progress.json was last written {e(iso_to_display(data.get("generated_at")))} '
            f"but this page was built {e(iso_to_display(built_at.isoformat()))}. "
            f"Either the run stopped writing, or someone rebuilt the page without new "
            f"numbers. Treat every number below as {e(fmt_age(age))} old at minimum.</p>"
        )
    elif level == "unknown":
        warn_build = (
            '<p class="fresh-warn fresh-warn--build">No <code>generated_at</code> in '
            "progress.json, so the page cannot say how old the numbers are.</p>"
        )
    elif level == "future":
        warn_build = (
            f'<p class="fresh-warn fresh-warn--build">progress.json says it was written '
            f'{e(iso_to_display(data.get("generated_at")))}, later than the '
            f"{e(iso_to_display(built_at.isoformat()))} build of this page. One of the two "
            f"clocks is wrong, so no age on this page can be trusted.</p>"
        )

    lag_line = ""
    if lag is not None and lag > stale_after and level != "future":
        lag_line = (
            f'<p class="fresh-line fresh-lag">Round {e(rounds[-1]["round"])} was scored '
            f"{e(fmt_age(lag))} before the file was written.</p>"
        )

    # No-JavaScript staleness clock. Page-load time is the only "now" a static
    # page has, so a step animation reveals these after the thresholds elapse.
    # Nothing moves and nothing is visible before then, so first paint is settled.
    open_warns = (
        f'<p class="fresh-warn fresh-open fresh-open--stale">'
        f"Open longer than {e(fmt_age(stale_after))}. These numbers are at least that old "
        f"now, and the page does not refresh itself without JavaScript. Reload.</p>"
        f'<p class="fresh-warn fresh-open fresh-open--cold">'
        f"Open for over {e(fmt_age(cold_after))}. Whatever is on screen is a snapshot, "
        f"not a live run.</p>"
    )

    body = (
        f'<div class="freshness freshness--{level}" '
        f'style="--stale-after:{stale_after}s;--cold-after:{cold_after}s" '
        f'data-generated-at="{e(data.get("generated_at", ""))}" '
        f'data-stale-after="{stale_after}" data-cold-after="{cold_after}">'
        f'<p class="fresh-line fresh-head">{glyphs}'
        f'<span class="fresh-head-text">{e(head)}</span></p>'
        f'<p class="fresh-line fresh-stamps">'
        f'data <time datetime="{e(data.get("generated_at", ""))}" data-relative>'
        f'{e(iso_to_display(data.get("generated_at", "")))}</time>'
        f' · page built <span data-buildstamp>{e(iso_to_display(built_at.isoformat()))}</span>'
        f' · {len(rounds)} round{"s" if len(rounds) != 1 else ""}</p>'
        f"{lag_line}{warn_build}{open_warns}"
        f"</div>"
    )
    return (level, body)


# ---------------------------------------------------------------- page

def render(data: dict, built_at: dt.datetime | None = None) -> str:
    data = S.migrate(data)
    errors, _ = S.validate(data)
    if errors:
        raise SystemExit(
            "progress.json does not match web/README.md:\n  " + "\n  ".join(errors)
        )
    built_at = (built_at or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc)

    rounds = sorted(data["rounds"], key=lambda r: r["round"])
    pass_line = data.get("pass_line", {})
    overrides = data.get("pass_line_overrides", {})
    primary = str(data.get("primary_tap_count", S.DEFAULT_PRIMARY_TAP))
    latest = rounds[-1]
    prev = rounds[-2] if len(rounds) > 1 else None
    surfaces = surface_columns(latest)
    taps = tap_columns(latest) or [primary]

    all_statuses = []
    for surface in surfaces:
        for tap in taps:
            metrics = metrics_at(latest, surface, tap)
            all_statuses += [metric_status(k, metrics.get(k), tap, pass_line, overrides)
                             for k in S.METRIC_KEYS]
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

    cards = "".join(
        surface_card(s, latest, prev, taps, pass_line, overrides) for s in surfaces
    )
    trends = "".join(
        trend_block(s, rounds, taps, primary, pass_line, overrides) for s in surfaces
    )
    level, freshness = freshness_block(data, rounds, built_at)

    src = latest.get("source") or {}
    src_warnings = list(src.get("warnings") or [])
    if src.get("is_stub"):
        src_warnings.insert(0, "These numbers came from the harness stub detector, "
                               "not from a shipping detector.")
    warn_banner = ""
    if src_warnings:
        warn_banner = (
            '<section class="banner banner--warn" aria-labelledby="warn-h">'
            '<h2 id="warn-h" class="banner-title">'
            '<span aria-hidden="true">■</span> What produced these numbers</h2>'
            "<ul>" + "".join(f"<li>{e(w)}</li>" for w in src_warnings) + "</ul></section>"
        )
    synth_banner = ""
    if data.get("synthetic"):
        synth_banner = (
            '<section class="banner banner--synthetic">'
            '<h2 class="banner-title"><span aria-hidden="true">◇</span> Synthetic fixture</h2>'
            "<p>Every number on this page is made up, for laying out the page. "
            "No sensor recorded any of it.</p></section>"
        )

    title = data.get("title", "Tunk progress")

    return f"""<!doctype html>
<!-- GENERATED by web/render.py from web/progress.json. Do not hand-edit. -->
<html lang="en" data-freshness="{e(level)}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="robots" content="noindex">
<meta name="tunk-build" content="{e(built_at.strftime('%Y-%m-%dT%H:%M:%SZ'))}">
<meta name="tunk-generated" content="{e(data.get('generated_at', ''))}">
<title>Round {e(latest['round'])} · {e(title)}</title>
<link rel="stylesheet" href="style.css">
</head>
<body data-overall="{e(overall)}">
<a class="skip" href="#now">Skip to current numbers</a>

<header class="page-head">
  <p class="eyebrow">Tunk · gauntlet loop</p>
  <h1>Round {e(latest['round'])}: {e(latest.get('label', ''))}</h1>
  <p class="lede">{e(latest.get('headline', ''))}</p>
  {freshness}
</header>

<main>
  {synth_banner}
  {warn_banner}
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
    <h2 id="now-h">Current numbers, per surface and tap count</h2>
    <p class="section-note">Each tap count is bound to its own action, so each is graded on
      its own. The pass line applies to each surface on its own too, never to the pooled
      average. A cell with diagonal hatching got worse than the previous round.</p>
    <div class="cards">{cards}</div>
  </section>

  <section id="trend" aria-labelledby="trend-h">
    <h2 id="trend-h">Trend across rounds</h2>
    <p class="section-note">Dashed line is the pass line. A round circle means on the line,
      a square means below it, a hollow diamond means unmeasured. The last segment is drawn
      heavy when a metric moved. Any tap count that regressed is opened for you.</p>
    {trends}
  </section>

  <section id="log" aria-labelledby="log-h">
    <h2 id="log-h">Round log</h2>
    {round_log(rounds, pass_line, overrides)}
  </section>

  <section id="passline" aria-labelledby="passline-h">
    <h2 id="passline-h">The pass line</h2>
    <p class="section-note">From <code>FORMAT.md</code>. Not relaxed without data. The same
      line applies to every tap count; a per-count column appears only where
      <code>pass_line_overrides</code> records a written decision.</p>
    {pass_line_table(pass_line, overrides, taps)}
  </section>
</main>

<footer class="page-foot">
  <p>Regenerate with <code>python3 web/render.py</code> after appending to
    <code>web/progress.json</code>, or let <code>python3 web/ingest.py</code> do both.
    This page needs no JavaScript and does not refresh itself without it; the script only
    adds polling, relative timestamps and a live staleness readout.</p>
  <p class="foot-links">
    <a href="progress.json">progress.json</a>
    <a href="README.md">schema</a>
  </p>
</footer>
<script src="progress.js" defer></script>
</body>
</html>
"""


# ---------------------------------------------------------------- cli

def baked_build_time(page: str):
    """The build stamp inside an already-written page, so --check can re-render
    with the same clock and compare content instead of timestamps."""
    m = BUILD_META_RE.search(page)
    return S.parse_iso(m.group(1)) if m else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", default=str(HERE / "progress.json"))
    ap.add_argument("--out", default=str(HERE / "index.html"))
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if index.html no longer matches progress.json, write nothing")
    ap.add_argument("--validate", action="store_true",
                    help="validate progress.json against web/README.md and exit")
    ap.add_argument("--built-at", metavar="ISO",
                    help="pretend the page was built at this time. For previewing the "
                         "stale and cold states without waiting for them.")
    args = ap.parse_args(argv)

    raw = json.loads(pathlib.Path(args.json).read_text(encoding="utf-8"))
    data = S.migrate(raw)
    errors, warnings = S.validate(data)
    for w in warnings:
        print(f"warn  {w}", file=sys.stderr)
    if errors:
        for err in errors:
            print(f"ERROR {err}", file=sys.stderr)
        print(f"\n{args.json}: {len(errors)} schema problem(s). See web/README.md.",
              file=sys.stderr)
        return 1
    if args.validate:
        print(f"{args.json}: schema ok")
        return 0

    out = pathlib.Path(args.out)
    if args.check:
        current = out.read_text(encoding="utf-8") if out.exists() else ""
        stamped = baked_build_time(current)
        if stamped is None:
            print(f"{out} has no build stamp; run python3 {__file__}", file=sys.stderr)
            return 1
        if current != render(data, built_at=stamped):
            print(f"{out} is stale; run python3 {__file__}", file=sys.stderr)
            return 1
        print(f"{out} is up to date")
        return 0

    built_at = None
    if args.built_at:
        built_at = S.parse_iso(args.built_at)
        if built_at is None:
            print(f"--built-at {args.built_at!r} is not ISO-8601", file=sys.stderr)
            return 1
    page = render(data, built_at=built_at)
    out.write_text(page, encoding="utf-8")
    print(f"wrote {out} ({len(page):,} bytes) from {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
