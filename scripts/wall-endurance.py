#!/usr/bin/env python3
"""Collect and summarize bounded wall-game diagnostics. Never awards beta acceptance."""
import argparse
import collections
import datetime as dt
import json
import math
import re
from pathlib import Path
import statistics
import subprocess


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def distribution(values):
    values = sorted(v for v in values if number(v))
    if not values:
        return None
    return {"samples": len(values), "minimum": values[0], "median": statistics.median(values),
            "p95_sample": values[max(0, math.ceil(len(values) * .95) - 1)], "maximum": values[-1]}


def load_rows(folder):
    rows, issues, seen = [], [], set()
    for path in sorted(Path(folder).rglob("power-*.jsonl")):
        for line_number, line in enumerate(path.read_text().splitlines(), 1):
            try:
                row = json.loads(line)
                json.dumps(row, allow_nan=False)
                valid = (isinstance(row, dict) and isinstance(row.get("run"), str)
                         and number(row.get("uptime")) and number(row.get("wallTime"))
                         and all(row.get(key) is None or isinstance(row[key], dict)
                                 for key in ("power", "gameplay", "environment")))
                if not valid:
                    raise ValueError("missing run or finite timestamp")
            except (ValueError, TypeError) as error:
                issues.append(f"{path.name}:{line_number}: {error}")
                continue
            key = (row["run"], row["uptime"], row.get("event"))
            if key not in seen:
                rows.append(row)
                seen.add(key)
    return rows, issues


def summarize_run(rows, minimum_minutes=30):
    rows = sorted(rows, key=lambda r: r["uptime"])
    start, end = rows[0], rows[-1]
    elapsed = end["uptime"] - start["uptime"]
    observed, gaps, foreground, camera_active, playing = 0., 0., 0., 0., 0.
    thermal, contexts, phases = collections.Counter(), collections.Counter(), collections.Counter()
    largest_gap = 0.
    cpu_observed = 0.
    cpu_coverage = 0.
    for left, right in zip(rows, rows[1:]):
        seconds = right["uptime"] - left["uptime"]
        if seconds > 15:
            gaps += seconds
            largest_gap = max(largest_gap, seconds)
            continue  # Never assume a stale state persisted through a log outage.
        observed += seconds
        active = left.get("appState") == "active"
        foreground += seconds if active else 0
        camera_active += seconds if active and left.get("cameraResting") is False else 0
        phase = (left.get("gameplay") or {}).get("phase", "unknown")
        playing += seconds if active and phase == "playing" else 0
        thermal[str(left.get("thermalState", "unknown"))] += seconds
        contexts[left.get("context", "unknown")] += seconds
        phases[phase] += seconds
        a, b = left.get("cpuSeconds"), right.get("cpuSeconds")
        if number(a) and number(b) and b >= a and left.get("processID") == right.get("processID"):
            cpu_observed += b - a
            cpu_coverage += seconds

    reasons = []
    if elapsed < minimum_minutes * 60:
        reasons.append("too_short")
    if gaps:
        reasons.append("logging_gaps")
    if elapsed <= 0 or foreground / max(elapsed, 1) < .95:
        reasons.append("not_continuously_foreground")
    power = [r.get("power") or {} for r in rows]
    levels = [p.get("batteryPercent") for p in power]
    if any(not number(v) or not 0 <= v <= 100 for v in levels):
        reasons.append("battery_unavailable")
    if any(p.get("charging") != "unplugged" for p in power):
        reasons.append("charging_or_unknown_power")
    if any(p.get("lowPowerMode") is not False for p in power):
        reasons.append("low_power_mode_or_unknown")
    brightness = [r.get("brightness") for r in rows]
    if any(not number(v) for v in brightness):
        reasons.append("brightness_unavailable")
    elif max(brightness) - min(brightness) > .05:
        reasons.append("brightness_changed")
    if all(number(v) for v in levels) and levels[-1] > levels[0]:
        reasons.append("battery_increased")
    environment = [r.get("environment") for r in rows if r.get("environment")]
    fingerprints = sorted({e["buildFingerprint"] for e in environment
                           if isinstance(e.get("buildFingerprint"), str)
                           and re.fullmatch(r"[0-9a-f]{64}", e["buildFingerprint"])})
    if len(environment) != len(rows) or any(e.get("buildFingerprint") not in fingerprints for e in environment):
        reasons.append("build_identity_unavailable")
    elif len(fingerprints) != 1:
        reasons.append("build_changed")
    if any(r.get("displayCount") is None or r.get("screenCaptured") is None for r in rows):
        reasons.append("display_state_unavailable")
    elif len({(r["displayCount"], r["screenCaptured"]) for r in rows}) > 1:
        reasons.append("display_state_changed")
    drop = levels[0] - levels[-1] if number(levels[0]) and number(levels[-1]) else None
    eligible = not reasons

    def live(row):
        return (row.get("appState") == "active" and row.get("cameraResting") is False
                and (row.get("gameplay") or {}).get("phase") == "playing")

    active_rows = [r for r in rows if live(r)]
    active_start = active_rows[0]["uptime"] if active_rows else None
    active_end = active_rows[-1]["uptime"] if active_rows else None
    early = [r["memoryMiB"] for r in active_rows if 120 <= r["uptime"] - active_start < 420
             and number(r.get("memoryMiB"))]
    late = [r["memoryMiB"] for r in active_rows if active_end - r["uptime"] <= 300
            and number(r.get("memoryMiB"))]
    recovery = [r.get("memoryMiB") for r in rows if active_end is not None
                and r["uptime"] >= active_end + 120 and r.get("cameraResting") is True
                and r.get("appState") == "active"]
    buckets = []
    for index in sorted({int((r["uptime"] - start["uptime"]) // 300) for r in rows}):
        window = [r for r in rows if int((r["uptime"] - start["uptime"]) // 300) == index]
        active = [r for r in window if live(r)]
        buckets.append({"minute_from": index * 5,
                        "memoryMiB": distribution([r.get("memoryMiB") for r in window]),
                        "playingAnalysisFPS": distribution([r.get("analysisFPS") for r in active]),
                        "playingInferenceMS": distribution([r.get("inferenceMS") for r in active]),
                        "playingCaptureFPS": distribution([r.get("captureFPS") for r in active])})
    return {
        "run": start["run"], "startUTC": dt.datetime.fromtimestamp(start["wallTime"], dt.timezone.utc).isoformat(),
        "samples": len(rows), "elapsedSeconds": elapsed, "observedSeconds": observed,
        "gapSeconds": gaps, "largestGapSeconds": largest_gap, "foregroundSeconds": foreground,
        "activeCameraSeconds": camera_active, "playingSeconds": playing if "unknown" not in phases else None,
        "contextsSeconds": dict(contexts), "phasesSeconds": dict(phases),
        "thermalSeconds": dict(thermal),
        "worstThermalState": max((r["thermalState"] for r in rows if r.get("thermalState") in (0, 1, 2, 3)), default=None),
        "memoryWarnings": sum(r.get("event") == "memory_warning" for r in rows),
        "memoryMiB": distribution([r.get("memoryMiB") for r in rows]),
        "playingEarlyToLateMemoryDeltaMiB": statistics.median(late) - statistics.median(early) if early and late else None,
        "postPlayRestingMemoryMiB": distribution(recovery),
        "cpuAverageCores": cpu_observed / cpu_coverage if cpu_coverage > 0 else None,
        "cpuObservedSeconds": cpu_coverage,
        "battery": {"startPercent": levels[0], "endPercent": levels[-1], "dropPercentagePoints": drop,
                    "comparableRun": eligible, "ineligibleReasons": reasons,
                    "percentagePointsPerHour": drop * 3600 / elapsed if eligible else None},
        "environment": environment[0] if environment else None,
        "buildFingerprints": fingerprints, "fiveMinuteWindows": buckets,
        "qualification": "NOT_ACCEPTED: physical shot accuracy, rendering, controls and recovery require review",
    }


def make_report(folder, run="latest", minimum_minutes=30):
    rows, issues = load_rows(folder)
    groups = collections.defaultdict(list)
    for row in rows:
        groups[row["run"]].append(row)
    if not groups:
        raise ValueError("No usable power history found")
    keys = sorted(groups, key=lambda k: max(r["wallTime"] for r in groups[k]))
    selected = keys if run == "all" else [keys[-1] if run == "latest" else run]
    if any(k not in groups for k in selected):
        raise ValueError("Requested run is not in this history")
    results = [summarize_run(groups[k], minimum_minutes) for k in selected]
    if issues:
        for result in results:
            result["battery"]["comparableRun"] = False
            result["battery"]["percentagePointsPerHour"] = None
            result["battery"]["ineligibleReasons"].append("malformed_input")
    return {"schemaVersion": 1, "createdAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "inputIssues": issues, "availableRuns": keys, "runs": results,
            "limitations": ["Thermal state is iOS pressure, not temperature in Celsius.",
                "Battery percentage is coarse; rates are approximate, not a battery-lifespan prediction.",
                "A comparable battery timeline still needs matched room, phone, battery health and workload controls.",
                "FPS and inference p95 are five-second snapshot distributions, not per-frame latency percentiles.",
                "Intentional idle model pacing can reduce analysis FPS without losing tracking.",
                "CPU cores exclude GPU/ANE work and are not watts or whole-device energy.",
                "Unobserved gaps and missing fields are not zero load or evidence of a pass.",
                "Diagnostics cannot establish real-shot accuracy or visible projector latency."]}


def markdown(report):
    lines = ["# Wall-game endurance observations", "", "**Beta acceptance: pending physical testing and review.**", ""]
    for r in report["runs"]:
        battery = r["battery"]
        lines += [f"## Run {r['run']}", "", f"Start: {r['startUTC']}",
                  f"Elapsed: {r['elapsedSeconds']/60:.1f} min; observed: {r['observedSeconds']/60:.1f} min; "
                  f"camera active: {r['activeCameraSeconds']/60:.1f} min; playing: "
                  + (f"{r['playingSeconds']/60:.1f} min." if r['playingSeconds'] is not None else "unknown (legacy or missing phase data)."),
                  f"Battery: {battery['startPercent']} → {battery['endPercent']}%; "
                  f"comparable timeline: {battery['comparableRun']}.",
                  "Battery exclusions: " + (", ".join(battery["ineligibleReasons"]) or "none; matched workload still needs review"),
                  f"Worst thermal state: {r['worstThermalState']} (0 normal, 1 fair, 2 serious, 3 critical). "
                  f"Memory warnings: {r['memoryWarnings']}."]
        memory = r["memoryMiB"]
        if memory:
            lines += [f"Sampled memory: median {memory['median']:.1f} MiB; peak {memory['maximum']:.1f} MiB."]
        lines += [f"Logging gaps: {r['gapSeconds']:.1f} seconds.", ""]
    lines += ["## Measurement limits", ""] + [f"- {s}" for s in report["limitations"]]
    if report["inputIssues"]:
        lines += ["", "## Input issues", ""] + [f"- {s}" for s in report["inputIssues"]]
    return "\n".join(lines) + "\n"


def collect(device, destination, bundle):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)  # Never overwrite an earlier pull.
    outcomes = []
    for source, name, required in [("Documents/PowerDiagnostics", "power", True),
                                    ("Documents/WallTargets/detector-startup.json", "detector-startup.json", False),
                                    ("Documents/WallTargets/runtime-latest.json", "runtime-latest.json", False)]:
        result = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", device,
            "--domain-type", "appDataContainer", "--domain-identifier", bundle, "--source", source,
            "--destination", str(destination / name), "--timeout", "30"], capture_output=True, text=True)
        outcomes.append({"source": source, "success": result.returncode == 0, "required": required,
                         "diagnostic": (result.stderr or result.stdout)[-2500:] if result.returncode else None})
    (destination / "collection.json").write_text(json.dumps({"device": device, "bundle": bundle,
        "collectedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "files": outcomes}, indent=2) + "\n")
    if any(o["required"] and not o["success"] for o in outcomes):
        raise RuntimeError("Power history could not be copied; see collection.json. No device data was deleted.")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    pull = commands.add_parser("collect", help="Copy small diagnostic files only; does not launch or alter the app")
    pull.add_argument("--device", required=True, help="Explicit CoreDevice UUID; never selects the first phone")
    pull.add_argument("--output", required=True, type=Path)
    pull.add_argument("--bundle", default="com.juggledude.balldetection.debug")
    report = commands.add_parser("report")
    report.add_argument("folder", type=Path)
    report.add_argument("--run", default="latest", help="latest, all, or a run UUID")
    report.add_argument("--minimum-minutes", type=float, default=30)
    report.add_argument("--output", required=True, type=Path, help="JSON path; a Markdown sibling is also written")
    args = parser.parse_args()
    if args.command == "collect":
        print(collect(args.device, args.output, args.bundle))
    else:
        if args.minimum_minutes <= 0:
            parser.error("minimum-minutes must be positive")
        result = make_report(args.folder, args.run, args.minimum_minutes)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        args.output.with_suffix(".md").write_text(markdown(result))
        print(args.output)


if __name__ == "__main__":
    main()
