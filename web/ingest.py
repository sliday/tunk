#!/usr/bin/env python3
"""Append a round to web/progress.json and regenerate web/index.html.

Two ways in.

    # 1. straight from a tunk-score run report
    swift run tunk-score run --json /tmp/run.json …
    python3 web/ingest.py --from-score /tmp/run.json --label "gate widened"

    # 2. from a round object built by whoever produced the numbers
    python3 web/ingest.py --round /tmp/round.json

Both validate against web/schema.py before anything is written, stamp
`generated_at`, and re-render the page, so the file on disk and the page on the
phone can never disagree. `--dry-run` prints the round and writes nothing.

The round shape is documented in web/README.md. This file is the executable
copy of the mapping from a tunk-score report onto it.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys

import render
import schema as S

HERE = pathlib.Path(__file__).resolve().parent


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _entry(value, n=None, note=None) -> dict:
    out = {"value": value}
    if n is not None:
        out["n"] = int(n)
    if note:
        out["note"] = note
    return out


def _ms(ns):
    return None if ns is None else round(float(ns) / 1e6, 1)


def metrics_from_aggregate(agg: dict) -> dict:
    """One tunk-score Aggregate -> one `metrics` block.

    Field names are tunk-score's own (`Aggregate` in Sources/TunkScore/Scoring.swift).
    Anything the harness does not measure comes through as null, which the page
    renders as "no data" — never as a pass.
    """
    rate = agg.get("detectionRate")
    return {
        "detection_rate": _entry(
            None if rate is None else round(rate * 100, 2),
            agg.get("doubleGroups"),
            None if agg.get("doubleGroups") else "no labelled tap groups in this scope",
        ),
        "false_triggers_typing": _entry(
            agg.get("typingFalsePositives") if agg.get("typingSessions") else None,
            agg.get("typingSessions"),
            None if agg.get("typingSessions") else "no typing sessions in this scope",
        ),
        "false_triggers_confound": _entry(
            agg.get("confoundFalsePositives") if agg.get("confoundSessions") else None,
            agg.get("confoundSessions"),
            None if agg.get("confoundSessions") else "no confound sessions in this scope",
        ),
        "false_triggers_per_20min": _entry(
            None if agg.get("falsePositivesPer20Min") is None
            else round(agg["falsePositivesPer20Min"], 3),
            agg.get("sessions"),
        ),
        "latency_p50_ms": _entry(_ms(agg.get("latencyP50Ns")), agg.get("detectedGroups")),
        "latency_p95_ms": _entry(_ms(agg.get("latencyP95Ns")), agg.get("detectedGroups")),
        "latency_max_ms": _entry(_ms(agg.get("latencyMaxNs")), agg.get("detectedGroups")),
        "stuck_modifiers": _entry(
            None, 0, "replay does not emit keys; graded by the emission tests"
        ),
    }


def coverage_from_aggregate(agg: dict, tap_groups: dict) -> dict:
    cov = {"sessions": agg.get("sessions", 0)}
    if tap_groups:
        cov["tap_groups"] = tap_groups
    minutes = agg.get("durationSeconds")
    if minutes:
        cov["minutes"] = round(minutes / 60.0, 1)
    return cov


def round_from_report(report: dict, label: str, headline: str | None,
                      biggest_gap: str | None, number: int) -> dict:
    """Map a tunk-score RunReport onto a progress round.

    Per-tap-count aggregates are used when the report has them: an array
    `perSurfaceTapCount`, each element an Aggregate plus a `tapCount` integer and
    a `label` naming the surface. Without that array every aggregate lands in tap
    count "2", because that is the only count the double-tap-only harness graded.
    """
    per_tap = report.get("perSurfaceTapCount")
    surfaces: dict = {}

    if isinstance(per_tap, list) and per_tap:
        for agg in per_tap:
            surface = agg.get("label") or agg.get("surface")
            tap = str(agg.get("tapCount", 2))
            if surface is None or tap not in S.TAP_KEYS:
                continue
            block = surfaces.setdefault(surface, {"coverage": {}, "taps": {}})
            block["taps"][tap] = {"metrics": metrics_from_aggregate(agg)}
            block["coverage"].setdefault("sessions", agg.get("sessions", 0))
            groups = block["coverage"].setdefault("tap_groups", {})
            groups[tap] = agg.get("doubleGroups", 0)
    else:
        for agg in report.get("perSurface", []):
            surface = agg.get("label")
            if surface is None:
                continue
            surfaces[surface] = {
                "coverage": coverage_from_aggregate(agg, {"2": agg.get("doubleGroups", 0)}),
                "taps": {"2": {"metrics": metrics_from_aggregate(agg)}},
            }

    if not surfaces:
        raise SystemExit(
            "the report has no per-surface aggregates, so there is nothing to show. "
            "Run tunk-score against a data root that has sessions."
        )

    checks = report.get("checks", [])
    if biggest_gap is None:
        failed = [c for c in checks if c.get("status") == "fail"]
        missing = [c for c in checks if c.get("status") == "no_data"]
        if failed:
            c = failed[0]
            biggest_gap = (f'{c.get("scope")}: {c.get("name")} — needs {c.get("requirement")}, '
                           f'got {c.get("actual")}.')
        elif missing:
            c = missing[0]
            biggest_gap = (f'{c.get("scope")}: {c.get("name")} has no data '
                           f'({c.get("actual")}). Unmeasured is not passing.')
        else:
            biggest_gap = ("No check failed and none is missing data. The critic has not "
                           "written a gap for this round.")

    verdict = report.get("verdict", "UNKNOWN")
    sessions = sum(s.get("coverage", {}).get("sessions", 0) for s in surfaces.values())
    if headline is None:
        headline = (f"{verdict.lower()} — {sessions} session(s) graded across "
                    f"{len(surfaces)} surface(s)")

    source = {k: v for k, v in {
        "tool": report.get("tool"),
        "detector": report.get("detectorBackend"),
        "split": report.get("split"),
        "data_root": report.get("dataRoot"),
    }.items() if isinstance(v, str)}
    if isinstance(report.get("detectorIsStub"), bool):
        source["is_stub"] = report["detectorIsStub"]
    warnings = [w for w in report.get("warnings", []) if isinstance(w, str)]
    if warnings:
        source["warnings"] = warnings

    return {
        "round": number,
        "label": label,
        "timestamp": report.get("generatedAt") or now_iso(),
        "status": "scored" if sessions else "no_data",
        "headline": headline,
        "biggest_gap": biggest_gap,
        "source": source,
        "surfaces": surfaces,
    }


def append(progress_path: pathlib.Path, round_obj: dict, replace: bool) -> dict:
    data = S.migrate(json.loads(progress_path.read_text(encoding="utf-8")))
    rounds = [r for r in data.get("rounds", [])]
    existing = [r for r in rounds if r.get("round") == round_obj["round"]]
    if existing and not replace:
        raise SystemExit(
            f'round {round_obj["round"]} is already in {progress_path}. '
            "Pass --replace to overwrite it, or pick another --round-number."
        )
    rounds = [r for r in rounds if r.get("round") != round_obj["round"]]
    rounds.append(round_obj)
    data["rounds"] = sorted(rounds, key=lambda r: r["round"])
    data["generated_at"] = now_iso()
    data.setdefault("schema", S.SCHEMA_VERSION)
    return data


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--from-score", metavar="REPORT.json",
                     help="a tunk-score run report (tunk-score run --json)")
    src.add_argument("--round", metavar="ROUND.json",
                     help="a round object already in the progress schema")
    ap.add_argument("--progress", default=str(HERE / "progress.json"))
    ap.add_argument("--out", default=str(HERE / "index.html"))
    ap.add_argument("--label", help="short name for the round, required with --from-score")
    ap.add_argument("--headline", help="the lede; derived from the verdict if omitted")
    ap.add_argument("--biggest-gap", help="the single biggest gap; derived from the "
                                          "failing checks if omitted")
    ap.add_argument("--round-number", type=int,
                    help="defaults to one past the highest round already recorded")
    ap.add_argument("--replace", action="store_true",
                    help="overwrite a round with the same number instead of refusing")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the round and the resulting file, write nothing")
    ap.add_argument("--no-render", action="store_true",
                    help="write progress.json but leave index.html alone (it will be stale)")
    args = ap.parse_args(argv)

    progress_path = pathlib.Path(args.progress)
    current = S.migrate(json.loads(progress_path.read_text(encoding="utf-8")))
    next_number = max((r.get("round", -1) for r in current.get("rounds", [])), default=-1) + 1
    number = args.round_number if args.round_number is not None else next_number

    if args.round:
        round_obj = json.loads(pathlib.Path(args.round).read_text(encoding="utf-8"))
        if args.round_number is not None:
            round_obj["round"] = number
        round_obj.setdefault("round", number)
    else:
        if not args.label:
            ap.error("--label is required with --from-score")
        report = json.loads(pathlib.Path(args.from_score).read_text(encoding="utf-8"))
        round_obj = round_from_report(report, args.label, args.headline,
                                      args.biggest_gap, number)

    data = append(progress_path, round_obj, args.replace)
    errors, warnings = S.validate(data)
    for w in warnings:
        print(f"warn  {w}", file=sys.stderr)
    if errors:
        for err in errors:
            print(f"ERROR {err}", file=sys.stderr)
        print("\nNothing was written. Fix the round and try again; the shape is in "
              "web/README.md.", file=sys.stderr)
        return 1

    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if args.dry_run:
        print(json.dumps(round_obj, indent=2, ensure_ascii=False))
        print(f"\n-- dry run: {progress_path} unchanged, would hold "
              f'{len(data["rounds"])} round(s)', file=sys.stderr)
        return 0

    progress_path.write_text(text, encoding="utf-8")
    print(f'wrote {progress_path} (round {round_obj["round"]}, '
          f'{len(data["rounds"])} round(s) total)')
    if args.no_render:
        print(f"{args.out} NOT regenerated; run python3 web/render.py before anyone looks")
        return 0
    return render.main(["--json", str(progress_path), "--out", args.out])


if __name__ == "__main__":
    raise SystemExit(main())
