#!/usr/bin/env python3
"""Tests for the progress page: schema, migration, staleness, rendering.

    python3 web/selftest.py                     # run everything
    python3 web/selftest.py --write-fixture     # refresh web/fixtures/demo.json

No test framework, no dependencies. Every number in the demo fixture is
SYNTHETIC and labelled as such in the file and on the rendered page; nothing
here was measured by a sensor.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import pathlib
import sys
import tempfile

import ingest
import render
import schema as S

HERE = pathlib.Path(__file__).resolve().parent
FIXTURE = HERE / "fixtures" / "demo.json"

FAILURES: list = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


# ---------------------------------------------------------------- synthetic data

# surface -> tap -> per-round tuple of
# (detection_rate, ft_typing, ft_confound, ft_per20, p50, p95, max, stuck)
DEMO = {
    "desk": {
        "1": [None,
              (88.0, 41, 19, 12.40, 120, 148, 190, 0),
              (90.5, 33, 14, 9.80, 118, 145, 186, 0),
              (91.2, 27, 11, 8.10, 117, 143, 181, 0)],
        "2": [None,
              (92.0, 2, 1, 0.90, 205, 238, 260, 0),
              (97.2, 0, 0, 0.40, 198, 231, 250, 0),
              (98.6, 0, 0, 0.20, 196, 228, 244, 0)],
        "3": [None,
              (71.0, 0, 0, 0.10, 320, 372, 410, 0),
              (79.4, 0, 0, 0.10, 318, 366, 402, 0),
              (84.0, 0, 0, 0.05, 315, 358, 396, 0)],
    },
    "soft": {
        "1": [None,
              (81.5, 55, 24, 16.20, 126, 158, 205, 0),
              (84.0, 47, 20, 13.90, 124, 154, 199, 0),
              (83.1, 52, 23, 15.10, 125, 157, 203, 0)],
        "2": [None,
              (90.4, 1, 2, 1.10, 212, 249, 279, 0),
              (96.0, 0, 0, 0.50, 209, 244, 271, 0),
              (91.3, 3, 2, 1.60, 224, 268, 302, 0)],
        "3": [None,
              (64.0, 0, 0, 0.20, 331, 388, 430, 0),
              (72.5, 0, 0, 0.10, 329, 381, 424, 0),
              (70.1, 1, 0, 0.40, 336, 394, 441, 0)],
    },
    "lap": {
        "1": [None,
              (74.0, 68, 31, 21.40, 133, 166, 214, 0),
              (77.2, 60, 27, 18.60, 131, 163, 210, 0),
              (78.8, 55, 25, 17.20, 130, 161, 207, 0)],
        "2": [None,
              (86.1, 4, 6, 2.80, 219, 261, 297, 0),
              (93.4, 1, 2, 1.20, 214, 252, 288, 0),
              (95.8, 0, 1, 0.70, 211, 247, 281, 0)],
        "3": [None, None, None, None],
    },
}

DEMO_ROUNDS = [
    ("bootstrap", "no data yet — dataset not recorded",
     "No dataset exists. Nothing has been measured.", "no_data"),
    ("first pass", "double-tap usable on desk, single-tap unusable everywhere",
     "Single tap fires 41 times in the held-out typing set on desk alone. "
     "Bound to an action it would be unusable.", "scored"),
    ("gate widened to 220 ms", "desk double-tap on the line, soft close behind",
     "Triple tap still misses one group in five; the confirm window swallows "
     "the third onset when the second is soft.", "scored"),
    ("onset threshold lowered", "soft surface went backwards, desk held",
     "Lowering the threshold bought 1.4 points of desk detection and cost the "
     "soft surface three typing false triggers. Wrong trade.", "scored"),
]


def demo_data() -> dict:
    base = json.loads((HERE / "progress.json").read_text(encoding="utf-8"))
    data = {
        "schema": S.SCHEMA_VERSION,
        "title": "Tunk — SYNTHETIC layout fixture",
        "synthetic": True,
        "generated_at": "2026-08-13T21:55:00Z",
        "stale_after_s": 900,
        "cold_after_s": 7200,
        "primary_tap_count": "2",
        "pass_line": base["pass_line"],
        "rounds": [],
    }
    for i, (label, headline, gap, status) in enumerate(DEMO_ROUNDS):
        stamp = (dt.datetime(2026, 8, 13, 18, 20, tzinfo=dt.timezone.utc)
                 + dt.timedelta(minutes=70 * i))
        surfaces = {}
        for surface, taps in DEMO.items():
            groups, blocks = {}, {}
            for tap, series in taps.items():
                row = series[i]
                if row is None:
                    metrics = {k: {"value": None, "n": 0} for k in S.METRIC_KEYS}
                    if i == 0:
                        metrics["detection_rate"]["note"] = "no groups recorded"
                    groups[tap] = 0
                else:
                    det, ftt, ftc, ft20, p50, p95, pmax, stuck = row
                    n = 60 if tap == "2" else 30
                    metrics = {
                        "detection_rate": {"value": det, "n": n},
                        "false_triggers_typing": {"value": ftt, "n": 4},
                        "false_triggers_confound": {"value": ftc, "n": 7},
                        "false_triggers_per_20min": {"value": ft20, "n": 12},
                        "latency_p50_ms": {"value": p50, "n": n},
                        "latency_p95_ms": {"value": p95, "n": n},
                        "latency_max_ms": {"value": pmax, "n": n},
                        "stuck_modifiers": {"value": stuck, "n": 1},
                    }
                    groups[tap] = n
                blocks[tap] = {"metrics": metrics}
            surfaces[surface] = {
                "coverage": {
                    "sessions": 0 if i == 0 else 12,
                    "typing_minutes": 0.0 if i == 0 else 8.0,
                    "confound_minutes": 0.0 if i == 0 else 6.0,
                    "tap_groups": groups,
                },
                "taps": blocks,
            }
        round_obj = {
            "round": i,
            "label": label,
            "timestamp": stamp.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "status": status,
            "headline": headline,
            "biggest_gap": gap,
            "surfaces": surfaces,
        }
        if i:
            round_obj["source"] = {
                "tool": "tunk-score 0.1.0 (SYNTHETIC)",
                "detector": "stub",
                "split": "test",
                "is_stub": True,
                "warnings": ["Synthetic fixture. No sensor produced these numbers."],
            }
        data["rounds"].append(round_obj)
    return data


def synthetic_report() -> dict:
    """A tunk-score RunReport, in that tool's own field names, for the converter."""
    def agg(label, sessions, groups, detected, typing_fp, confound_fp, p50, p95, mx):
        return {
            "label": label, "sessions": sessions, "tapSessions": 4,
            "typingSessions": 4, "confoundSessions": 7,
            "durationSeconds": 3600.0, "doubleGroups": groups,
            "detectedGroups": detected, "ambiguousGroups": 0,
            "triggerCount": detected + typing_fp + confound_fp,
            "falsePositives": typing_fp + confound_fp,
            "typingFalsePositives": typing_fp, "confoundFalsePositives": confound_fp,
            "tapSessionFalsePositives": 0, "gapCount": 0,
            "deliveryOrderViolations": 0, "latencyExcluded": 0,
            "detectionRate": detected / groups if groups else None,
            "falsePositivesPer20Min": (typing_fp + confound_fp) / 3.0,
            "latencyP50Ns": p50 * 1_000_000, "latencyP95Ns": p95 * 1_000_000,
            "latencyMaxNs": mx * 1_000_000,
        }
    return {
        "tool": "tunk-score 0.1.0", "generatedAt": "2026-08-13T22:10:00Z",
        "dataRoot": "/tmp/data/holdout", "split": "test",
        "detectorBackend": "stub", "detectorIsStub": True, "matchWindowMs": 150.0,
        "config": {}, "pooled": agg("pooled", 36, 180, 170, 3, 2, 200, 240, 280),
        "perSurface": [agg("desk", 12, 60, 59, 0, 0, 196, 228, 244),
                       agg("soft", 12, 60, 55, 3, 2, 224, 268, 302),
                       agg("lap", 12, 60, 56, 0, 1, 211, 247, 281)],
        "perCategory": [], "sessions": [],
        "checks": [
            {"name": "detection rate, double-taps", "scope": "soft",
             "requirement": "≥ 98 %", "actual": "91.67 % (55/60)", "status": "fail"},
            {"name": "latency p95", "scope": "desk", "requirement": "≤ 250 ms",
             "actual": "228.0 ms", "status": "pass"},
        ],
        "verdict": "FAIL",
        "warnings": ["Graded the HARNESS STUB detector, not a shipping detector."],
    }


# ---------------------------------------------------------------- tests

def test_schema_of_checked_in_files() -> None:
    print("schema")
    data = json.loads((HERE / "progress.json").read_text(encoding="utf-8"))
    errors, _ = S.validate(S.migrate(data))
    check("web/progress.json validates", not errors, "; ".join(errors))
    check("web/progress.json is schema 2", data.get("schema") == S.SCHEMA_VERSION)
    errors, _ = S.validate(demo_data())
    check("demo fixture validates", not errors, "; ".join(errors))


def test_migration() -> None:
    print("migration from schema 1")
    legacy = {
        "schema": 1, "generated_at": "2026-08-13T18:20:00Z",
        "pass_line": {"detection_rate": {"op": ">=", "value": 98, "unit": "%"}},
        "rounds": [{
            "round": 0, "label": "old", "timestamp": "2026-08-13T18:20:00Z",
            "headline": "h", "biggest_gap": "g",
            "surfaces": {"desk": {"metrics": {"detection_rate": {"value": 99.0, "n": 3}}}},
        }],
    }
    moved = S.migrate(copy.deepcopy(legacy))
    errors, warnings = S.validate(moved)
    check("schema 1 migrates cleanly", not errors, "; ".join(errors))
    check("schema 1 lands in tap count 2",
          moved["rounds"][0]["surfaces"]["desk"]["taps"]["2"]["metrics"]
          ["detection_rate"]["value"] == 99.0)
    errors, warnings = S.validate(legacy)
    check("schema 1 warns rather than passing silently",
          any("pre-tap-count" in w for w in warnings))


def test_schema_rejects() -> None:
    print("schema rejection")
    good = demo_data()

    bad = copy.deepcopy(good)
    bad["rounds"][1]["surfaces"]["desk"]["taps"]["2"]["metrics"]["detection_rat"] = {"value": 1}
    errors, _ = S.validate(bad)
    check("unknown metric key is an error", any("detection_rat" in e for e in errors))

    bad = copy.deepcopy(good)
    bad["rounds"][1]["surfaces"]["desk"]["taps"]["4"] = {"metrics": {}}
    errors, _ = S.validate(bad)
    check("unknown tap count is an error", any("taps.4" in e for e in errors))

    bad = copy.deepcopy(good)
    del bad["rounds"][1]["biggest_gap"]
    errors, _ = S.validate(bad)
    check("missing biggest_gap is an error", any("biggest_gap" in e for e in errors))

    bad = copy.deepcopy(good)
    bad["rounds"][2]["round"] = 1
    errors, _ = S.validate(bad)
    check("duplicate round number is an error", any("twice" in e for e in errors))

    bad = copy.deepcopy(good)
    del bad["generated_at"]
    errors, _ = S.validate(bad)
    check("missing generated_at is an error", any("generated_at" in e for e in errors))

    bad = copy.deepcopy(good)
    bad["rounds"][1]["surfaces"]["desk"]["taps"]["2"]["metrics"]["detection_rate"] = {"n": 3}
    errors, _ = S.validate(bad)
    check("metric without a value is an error", any("value" in e for e in errors))


def test_staleness() -> None:
    print("staleness")
    data = demo_data()
    generated = S.parse_iso(data["generated_at"])

    fresh = render.render(data, built_at=generated + dt.timedelta(seconds=30))
    check("fresh render marks itself fresh", 'data-freshness="fresh"' in fresh)
    check("fresh render does not shout STALE", "STALE" not in fresh)

    stale = render.render(data, built_at=generated + dt.timedelta(minutes=40))
    check("40 min old render marks itself stale", 'data-freshness="stale"' in stale)
    check("stale render says STALE in text", "STALE" in stale)
    check("stale render names the age", "40 min" in stale)

    cold = render.render(data, built_at=generated + dt.timedelta(hours=5))
    check("5 h old render marks itself cold", 'data-freshness="cold"' in cold)
    check("cold render names the age in hours", "5 h 00 min" in cold)

    check("build stamp is baked into the page",
          '<meta name="tunk-build"' in fresh and '<meta name="tunk-generated"' in fresh)
    check("no-JS staleness clock is configured from the file's own thresholds",
          "--stale-after:900s;--cold-after:7200s" in fresh
          and 'class="fresh-warn fresh-open fresh-open--stale"' in fresh)
    check("a fresh page carries both glyphs for the clock to swap",
          'fresh-glyph--now">●' in fresh and 'fresh-glyph--aged">■' in fresh)
    check("a stale page shows only the aged glyph", 'fresh-glyph--aged' not in stale)

    future = render.render(data, built_at=S.parse_iso(data["generated_at"])
                           - dt.timedelta(hours=2))
    check("a stamp from the future is called out, not smoothed over",
          'data-freshness="future"' in future and "cannot be trusted" in future)
    check("baked build time round-trips",
          render.baked_build_time(fresh) == (generated + dt.timedelta(seconds=30)))


def test_render_check_mode() -> None:
    print("render --check")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        jsonf, outf = tmp / "p.json", tmp / "index.html"
        jsonf.write_text(json.dumps(demo_data()), encoding="utf-8")
        rc = render.main(["--json", str(jsonf), "--out", str(outf)])
        check("render writes a page", rc == 0 and outf.exists())
        rc = render.main(["--json", str(jsonf), "--out", str(outf), "--check"])
        check("--check passes straight after a render (build time is not content)", rc == 0)

        data = demo_data()
        data["rounds"][-1]["headline"] = "something else entirely"
        jsonf.write_text(json.dumps(data), encoding="utf-8")
        rc = render.main(["--json", str(jsonf), "--out", str(outf), "--check"])
        check("--check fails once progress.json moves on", rc == 1)


def test_tap_counts() -> None:
    print("tap counts")
    data = demo_data()
    page = render.render(data, built_at=S.parse_iso(data["generated_at"]))
    for short in ("1×", "2×", "3×"):
        check(f"matrix has a {short} column", f">{short}</abbr>" in page)
    check("single tap is graded and fails loudly", 'cell--fail' in page)
    check("a regressed cell is hatched", "cell--d-regress" in page)
    check("regressed tap count is not folded away",
          'class="trend-details trend-details--regress" open' in page)
    check("tap strip names each count", "Single tap" in page and "Triple tap" in page)
    check("lap triple tap reads as unmeasured, not zero", "cell--none" in page)

    seed = json.loads((HERE / "progress.json").read_text(encoding="utf-8"))
    empty = render.render(seed, built_at=S.parse_iso(seed["generated_at"]))
    check("empty seed never claims a pass", "verdict--none" in empty)
    check("empty seed says blank is not green", "Blank is not green" in empty)


def test_ingest() -> None:
    print("ingest")
    report = synthetic_report()
    round_obj = ingest.round_from_report(report, "converter test", None, None, 1)
    data = demo_data()
    data["rounds"] = [data["rounds"][0], round_obj]
    errors, _ = S.validate(data)
    check("a converted tunk-score report validates", not errors, "; ".join(errors))
    desk = round_obj["surfaces"]["desk"]["taps"]["2"]["metrics"]
    check("detection rate converts to percent",
          abs(desk["detection_rate"]["value"] - 98.33) < 0.01,
          str(desk["detection_rate"]))
    check("latency converts nanoseconds to ms", desk["latency_p95_ms"]["value"] == 228.0)
    check("unmeasured stuck modifiers stay null",
          desk["stuck_modifiers"]["value"] is None)
    check("harness warnings ride along",
          any("STUB" in w for w in round_obj["source"]["warnings"]))
    check("the biggest gap falls back to the first failing check",
          "soft" in round_obj["biggest_gap"])

    per_tap = dict(report)
    per_tap["perSurfaceTapCount"] = [
        dict(a, tapCount=n) for a in report["perSurface"] for n in (1, 2, 3)
    ]
    r2 = ingest.round_from_report(per_tap, "per tap", None, None, 2)
    check("per-tap-count aggregates land in their own columns",
          sorted(r2["surfaces"]["desk"]["taps"]) == ["1", "2", "3"])

    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        jsonf, outf = tmp / "p.json", tmp / "index.html"
        jsonf.write_text((HERE / "progress.json").read_text(encoding="utf-8"), encoding="utf-8")
        reportf = tmp / "run.json"
        reportf.write_text(json.dumps(report), encoding="utf-8")
        rc = ingest.main(["--from-score", str(reportf), "--label", "round one",
                          "--progress", str(jsonf), "--out", str(outf)])
        after = json.loads(jsonf.read_text(encoding="utf-8"))
        check("ingest appends and renders in one step",
              rc == 0 and len(after["rounds"]) == 2 and outf.exists())
        check("ingest restamps generated_at",
              after["generated_at"] != "2026-08-13T18:20:00Z")
        try:
            rc = ingest.main(["--from-score", str(reportf), "--label", "again",
                              "--progress", str(jsonf), "--out", str(outf),
                              "--round-number", "1"])
        except SystemExit as exc:
            rc = exc.code
        check("ingest refuses to overwrite a round by accident", rc not in (0, None))


def test_ui_standard() -> None:
    print("UI standard")
    css = (HERE / "style.css").read_text(encoding="utf-8")
    check("no transition: all", "transition: all" not in css)
    check("no will-change", "will-change" not in css)
    check("font smoothing on the root", "-webkit-font-smoothing: antialiased" in css)
    check("text-wrap balance on headings", "text-wrap: balance" in css)
    check("text-wrap pretty on body", "text-wrap: pretty" in css)
    check("dark mode via prefers-color-scheme", "prefers-color-scheme: dark" in css)
    check("reduced motion honoured", "prefers-reduced-motion: reduce" in css)
    check("sparkline outline is pure black, never tinted",
          "--outline: rgba(0, 0, 0, 0.1)" in css and "--outline: rgba(255, 255, 255, 0.1)" in css)
    check("tabular numbers on the metric cells",
          ".cell-value {" in css and "font-variant-numeric: tabular-nums" in css)

    page = render.render(demo_data())
    check("page has no inline transition", "transition:" not in page)
    check("skip link first", page.index('class="skip"') < page.index("<main>"))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--write-fixture", action="store_true",
                    help=f"write the synthetic fixture to {FIXTURE}")
    args = ap.parse_args(argv)

    if args.write_fixture:
        FIXTURE.parent.mkdir(parents=True, exist_ok=True)
        FIXTURE.write_text(json.dumps(demo_data(), indent=2, ensure_ascii=False) + "\n",
                           encoding="utf-8")
        print(f"wrote {FIXTURE}")

    test_schema_of_checked_in_files()
    test_migration()
    test_schema_rejects()
    test_staleness()
    test_render_check_mode()
    test_tap_counts()
    test_ingest()
    test_ui_standard()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} failure(s): {', '.join(FAILURES)}")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
