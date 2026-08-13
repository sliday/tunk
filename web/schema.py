#!/usr/bin/env python3
"""The progress.json contract, as code.

`web/README.md` is the prose contract; this file is the executable one, and the
two are kept in step deliberately. Anything that writes progress.json — the
scoring harness, `web/ingest.py`, a human with an editor — can check itself with

    python3 web/schema.py web/progress.json

Exit 0 means the renderer will accept the file. Exit 1 lists what is wrong, one
line per problem, with the JSON path.
"""

from __future__ import annotations

import datetime as dt
import json
import pathlib
import re
import sys

SCHEMA_VERSION = 2

# ---------------------------------------------------------------- vocabulary

# Tap counts are graded separately, on the iPhone Back Tap model: each count is
# bound to its own action, so each count has its own detection rate and its own
# false triggers. "any" holds metrics that belong to no single count.
TAP_KEYS = ["1", "2", "3", "any"]
TAP_LABEL = {
    "1": "Single tap",
    "2": "Double tap",
    "3": "Triple tap",
    "any": "Not tap-specific",
}
TAP_SHORT = {"1": "1×", "2": "2×", "3": "3×", "any": "any"}

# key, long label, short label, unit, direction ("higher"/"lower" is better), decimals
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
METRIC_KEYS = [m[0] for m in METRICS]
METRIC_BY_KEY = {m[0]: m for m in METRICS}

SURFACE_ORDER = ["desk", "soft", "lap"]
SURFACE_LABEL = {
    "desk": "Hard desk",
    "soft": "Soft surface",
    "lap": "On the lap",
    "pooled": "Pooled (not the pass line)",
}

OPS = {">=", ">", "<=", "<", "=="}
STATUSES = {"no_data", "running", "scored"}

DEFAULT_STALE_AFTER_S = 900       # 15 min
DEFAULT_COLD_AFTER_S = 7200       # 2 h
DEFAULT_PRIMARY_TAP = "2"

ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$")


# ---------------------------------------------------------------- helpers

def parse_iso(value):
    """ISO-8601 string -> aware datetime, or None. Naive stamps are read as UTC."""
    if not isinstance(value, str) or not value:
        return None
    try:
        stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=dt.timezone.utc)
    return stamp


def tap_sort_key(key: str) -> tuple:
    return (TAP_KEYS.index(key) if key in TAP_KEYS else len(TAP_KEYS), key)


def surface_sort_key(key: str) -> tuple:
    return (SURFACE_ORDER.index(key) if key in SURFACE_ORDER else len(SURFACE_ORDER), key)


# ---------------------------------------------------------------- migration

def migrate(data: dict) -> dict:
    """Accept a schema-1 file and return it as schema 2.

    Schema 1 had one flat `metrics` block per surface and graded double-tap only,
    so its numbers become the `"2"` tap count. Nothing is invented: a schema-1
    file gains no single- or triple-tap data, it gains empty columns.
    """
    if data.get("schema") == SCHEMA_VERSION:
        return data
    if data.get("schema") != 1:
        return data
    out = dict(data)
    out["schema"] = SCHEMA_VERSION
    rounds = []
    for r in out.get("rounds", []):
        r = dict(r)
        surfaces = {}
        for name, surf in (r.get("surfaces") or {}).items():
            surf = dict(surf)
            if "metrics" in surf and "taps" not in surf:
                surf["taps"] = {"2": {"metrics": surf.pop("metrics")}}
            surfaces[name] = surf
        r["surfaces"] = surfaces
        rounds.append(r)
    out["rounds"] = rounds
    return out


# ---------------------------------------------------------------- validation

def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _check_rule(where: str, rule, errors: list) -> None:
    if not isinstance(rule, dict):
        errors.append(f"{where}: must be an object like " '{"op": ">=", "value": 98, "unit": "%"}')
        return
    if rule.get("op") not in OPS:
        errors.append(f'{where}.op: {rule.get("op")!r} is not one of {sorted(OPS)}')
    if not _is_num(rule.get("value")):
        errors.append(f"{where}.value: must be a number")
    if "unit" in rule and not isinstance(rule["unit"], str):
        errors.append(f"{where}.unit: must be a string")


def _check_metric_entry(where: str, entry, errors: list) -> None:
    if not isinstance(entry, dict):
        errors.append(f"{where}: must be an object like " '{"value": 98.6, "n": 60}')
        return
    if "value" not in entry:
        errors.append(f'{where}.value: required. Use null for "not measured".')
    elif entry["value"] is not None and not _is_num(entry["value"]):
        errors.append(f"{where}.value: must be a number or null")
    if "n" in entry and entry["n"] is not None:
        if not isinstance(entry["n"], int) or isinstance(entry["n"], bool) or entry["n"] < 0:
            errors.append(f"{where}.n: must be a non-negative integer")
    if "pass" in entry:
        ok = entry["pass"] in (True, False, "pass", "fail", "info", "none")
        if not ok:
            errors.append(f'{where}.pass: must be true/false or "pass"/"fail"/"info"/"none"')
    if "note" in entry and not isinstance(entry["note"], str):
        errors.append(f"{where}.note: must be a string")
    for extra in set(entry) - {"value", "n", "pass", "note"}:
        errors.append(f"{where}.{extra}: unknown field")


def validate(data) -> tuple:
    """Return (errors, warnings). An empty error list means the page will render."""
    errors: list = []
    warnings: list = []

    if not isinstance(data, dict):
        return (["root: must be a JSON object"], [])

    schema = data.get("schema")
    if schema == 1:
        warnings.append(
            "root.schema: 1 is the pre-tap-count schema. The renderer migrates it "
            "into tap count \"2\"; write schema 2 instead."
        )
    elif schema != SCHEMA_VERSION:
        errors.append(f"root.schema: must be {SCHEMA_VERSION} (got {schema!r})")

    generated = parse_iso(data.get("generated_at"))
    if generated is None:
        errors.append("root.generated_at: required, ISO-8601 UTC, e.g. 2026-08-13T18:20:00Z")

    for key in ("stale_after_s", "cold_after_s"):
        if key in data:
            v = data[key]
            if not isinstance(v, int) or isinstance(v, bool) or v <= 0:
                errors.append(f"root.{key}: must be a positive integer number of seconds")
    if isinstance(data.get("stale_after_s"), int) and isinstance(data.get("cold_after_s"), int):
        if data["cold_after_s"] <= data["stale_after_s"]:
            errors.append("root.cold_after_s: must be greater than root.stale_after_s")

    primary = data.get("primary_tap_count", DEFAULT_PRIMARY_TAP)
    if str(primary) not in TAP_KEYS:
        errors.append(f"root.primary_tap_count: must be one of {TAP_KEYS}")

    if "title" in data and not isinstance(data["title"], str):
        errors.append("root.title: must be a string")
    if "synthetic" in data and not isinstance(data["synthetic"], bool):
        errors.append("root.synthetic: must be true or false")

    pass_line = data.get("pass_line")
    if not isinstance(pass_line, dict):
        errors.append("root.pass_line: required object, metric key -> {op, value, unit}")
        pass_line = {}
    for key, rule in pass_line.items():
        if key not in METRIC_BY_KEY:
            errors.append(f"root.pass_line.{key}: unknown metric key; known keys are {METRIC_KEYS}")
        _check_rule(f"root.pass_line.{key}", rule, errors)

    overrides = data.get("pass_line_overrides", {})
    if not isinstance(overrides, dict):
        errors.append("root.pass_line_overrides: must be an object keyed by tap count")
        overrides = {}
    for tap, block in overrides.items():
        if tap not in TAP_KEYS:
            errors.append(f"root.pass_line_overrides.{tap}: tap count must be one of {TAP_KEYS}")
        if not isinstance(block, dict):
            errors.append(f"root.pass_line_overrides.{tap}: must be an object")
            continue
        for key, rule in block.items():
            if key not in METRIC_BY_KEY:
                errors.append(f"root.pass_line_overrides.{tap}.{key}: unknown metric key")
            _check_rule(f"root.pass_line_overrides.{tap}.{key}", rule, errors)

    rounds = data.get("rounds")
    if not isinstance(rounds, list) or not rounds:
        errors.append("root.rounds: required, a non-empty array")
        return (errors, warnings)

    seen_numbers = set()
    for i, r in enumerate(rounds):
        where = f"rounds[{i}]"
        if not isinstance(r, dict):
            errors.append(f"{where}: must be an object")
            continue
        num = r.get("round")
        if not isinstance(num, int) or isinstance(num, bool):
            errors.append(f"{where}.round: required integer")
        elif num in seen_numbers:
            errors.append(f"{where}.round: {num} appears twice; round numbers are unique")
        else:
            seen_numbers.add(num)
            where = f"rounds[round={num}]"

        for key in ("label", "headline", "biggest_gap"):
            if not isinstance(r.get(key), str) or not r.get(key).strip():
                errors.append(f"{where}.{key}: required non-empty string")

        stamp = parse_iso(r.get("timestamp"))
        if stamp is None:
            errors.append(f"{where}.timestamp: required, ISO-8601")
        elif generated is not None and stamp > generated + dt.timedelta(seconds=60):
            warnings.append(
                f"{where}.timestamp is later than root.generated_at; the page will "
                "report the file as older than the round it contains"
            )

        if "status" in r and r["status"] not in STATUSES:
            warnings.append(
                f'{where}.status: {r["status"]!r} is free text; the page styles '
                f"{sorted(STATUSES)} and shows anything else verbatim"
            )

        source = r.get("source")
        if source is not None:
            if not isinstance(source, dict):
                errors.append(f"{where}.source: must be an object")
            else:
                for key in ("tool", "detector", "split", "data_root"):
                    if key in source and not isinstance(source[key], str):
                        errors.append(f"{where}.source.{key}: must be a string")
                if "is_stub" in source and not isinstance(source["is_stub"], bool):
                    errors.append(f"{where}.source.is_stub: must be true or false")
                w = source.get("warnings", [])
                if not isinstance(w, list) or any(not isinstance(x, str) for x in w):
                    errors.append(f"{where}.source.warnings: must be an array of strings")

        surfaces = r.get("surfaces")
        if not isinstance(surfaces, dict) or not surfaces:
            errors.append(f"{where}.surfaces: required, a non-empty object keyed by surface")
            continue
        for name, surf in surfaces.items():
            sw = f"{where}.surfaces.{name}"
            if name not in SURFACE_ORDER and name != "pooled":
                warnings.append(
                    f'{sw}: {name!r} is not one of {SURFACE_ORDER} or "pooled"; it renders last'
                )
            if not isinstance(surf, dict):
                errors.append(f"{sw}: must be an object")
                continue
            cov = surf.get("coverage", {})
            if not isinstance(cov, dict):
                errors.append(f"{sw}.coverage: must be an object")
            elif "tap_groups" in cov and not isinstance(cov["tap_groups"], dict):
                errors.append(f'{sw}.coverage.tap_groups: must be an object keyed by tap count')
            taps = surf.get("taps")
            if not isinstance(taps, dict) or not taps:
                errors.append(
                    f'{sw}.taps: required, a non-empty object keyed by tap count '
                    f'({TAP_KEYS}). Schema 1 put metrics directly on the surface; '
                    f'wrap them in {{"2": {{"metrics": …}}}}.'
                )
                continue
            for tap, block in taps.items():
                tw = f"{sw}.taps.{tap}"
                if tap not in TAP_KEYS:
                    errors.append(f"{tw}: tap count must be one of {TAP_KEYS} (JSON string keys)")
                if not isinstance(block, dict):
                    errors.append(f"{tw}: must be an object with a `metrics` field")
                    continue
                metrics = block.get("metrics")
                if not isinstance(metrics, dict):
                    errors.append(f"{tw}.metrics: required object, metric key -> entry")
                    continue
                for key, entry in metrics.items():
                    if key not in METRIC_BY_KEY:
                        errors.append(
                            f"{tw}.metrics.{key}: unknown metric key. "
                            f"Known keys: {METRIC_KEYS}. Adding one means adding a row "
                            f"to METRICS in web/schema.py."
                        )
                        continue
                    _check_metric_entry(f"{tw}.metrics.{key}", entry, errors)

    return (errors, warnings)


def load(path) -> dict:
    """Read, migrate and hard-fail on an invalid file."""
    data = json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    data = migrate(data)
    errors, _ = validate(data)
    if errors:
        raise SystemExit(
            f"{path} does not match the schema in web/README.md:\n  "
            + "\n  ".join(errors)
        )
    return data


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    target = argv[0] if argv else str(pathlib.Path(__file__).resolve().parent / "progress.json")
    raw = json.loads(pathlib.Path(target).read_text(encoding="utf-8"))
    errors, warnings = validate(migrate(raw))
    for w in warnings:
        print(f"warn  {w}")
    for e in errors:
        print(f"ERROR {e}", file=sys.stderr)
    if errors:
        print(f"\n{target}: {len(errors)} problem(s). See web/README.md.", file=sys.stderr)
        return 1
    rounds = len(raw.get("rounds", []))
    print(f"{target}: schema {SCHEMA_VERSION} ok, {rounds} round(s), {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
