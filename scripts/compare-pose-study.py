#!/usr/bin/env python3
"""Compare complete ThermalVideoReview runs with only foreground pose compute changed.

Usage: compare-pose-study.py BASELINE_DIRECTORY CANDIDATE_DIRECTORY [--accelerated-ball-model]
Output parity is a regression check, not independently labelled accuracy.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib


def differences(a, b, path=""):
    if a == b:
        return []
    if isinstance(a, dict) and isinstance(b, dict):
        return [d for key in sorted(a.keys() | b.keys())
                for d in differences(a.get(key), b.get(key), f"{path}/{key}")]
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        return [d for i, (x, y) in enumerate(zip(a, b))
                for d in differences(x, y, f"{path}/{i}")]
    return [{"path": path, "baseline": a, "candidate": b}]


def compare(baseline, candidate, accelerated_ball_model=False):
    spec = importlib.util.spec_from_file_location("accuracy", Path(__file__).with_name("compare-juggling-accuracy.py"))
    accuracy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(accuracy)
    reports = [accuracy.load_report(folder, accelerated_ball_model) for folder in (baseline, candidate)]
    for report in reports:
        if any(s["application_state"] != 0 for s in report["samples"]):
            raise ValueError("A foreground comparison must stay active throughout")
        for sample in report["samples"]:
            backend = sample.get("pipeline", {}).get("model_cpu_only")
            if backend is not None and backend != int(not accelerated_ball_model):
                raise ValueError("Ball model backend changed during the pose comparison")
    runs = [{r["id"]: r for r in report["runs"]} for report in reports]
    if runs[0].keys() != runs[1].keys():
        raise ValueError("Different clip sets")
    result = []
    for name, a in runs[0].items():
        b = runs[1][name]
        if any(a[k] != b[k] for k in ("source", "model", "frames")):
            raise ValueError("Source, model or frame count differs")
        ap, bp = a["performance"], b["performance"]
        if ap.get("pose_accelerated_requests", 0) != 0 or ap.get("pose_cpu_requests", 0) != ap.get("pose_requests"):
            raise ValueError("Baseline CPU pose execution unverified")
        if bp.get("pose_accelerated_requests", 0) != bp.get("pose_requests") or bp.get("pose_cpu_requests", 0):
            raise ValueError("Candidate foreground-only pose execution unverified")
        if not bp.get("pose_requests") and not reports[1].get("pose_acceleration_study"):
            raise ValueError("No pose requests and no explicit candidate provenance")
        clip = name.split("-", 1)[1]
        traces = [plistlib.loads((p / f"{clip}-trace.plist").read_bytes()) for p in (baseline, candidate)]
        recoveries = [plistlib.loads((p / f"{clip}-recoveries.plist").read_bytes()) for p in (baseline, candidate)]
        if any(traces[0].get(k) != traces[1].get(k) for k in
               ("usesBodyVerifier", "usesGroundVerifier", "usesHandlingVerifier")):
            raise ValueError("Contact verifier policy differs")
        trace_differences = {}
        for key in ("decisions", "diagnostics", "streakInterruptions"):
            diffs = differences(traces[0].get(key), traces[1].get(key))
            discrete = [d for d in diffs if not (isinstance(d["baseline"], float) and isinstance(d["candidate"], float))]
            trace_differences[key] = {"exact": not diffs, "changed_fields": len(diffs),
                                      "discrete_changed_fields": len(discrete), "examples": discrete[:8]}
        verdict_keys = ("frameIndex", "timestampMs", "rejection", "handRejected", "bodyContactAllowed",
                        "footConfirmed", "plantedFeetConfirmed", "handlingChecked")
        verdicts = [[{"operation": d["operation"], **{k: d["value"].get(k) for k in verdict_keys}}
                     for d in t["decisions"]] for t in traces]
        streaks = [[(s["timestampMs"], s["kind"]) for s in t.get("streakInterruptions", [])] for t in traces]
        result.append({"id": name, "frames": a["frames"], "counts": [a["count"], b["count"]],
            "exact_touches": a["touches"] == b["touches"],
            "exact_contact_verdicts": verdicts[0] == verdicts[1],
            "exact_streak_boundaries": streaks[0] == streaks[1],
            "exact_counter_inputs": traces[0]["operations"] == traces[1]["operations"],
            "exact_visual_recoveries": recoveries[0] == recoveries[1],
            "schedule": accuracy.compare_frame_schedule(baseline, candidate, clip, a["frames"]),
            "track": accuracy.compare_tracks(baseline, candidate, clip),
            "trace": trace_differences,
            "elapsed_s": [a["elapsed_s"], b["elapsed_s"]], "cpu_s": [a["cpu_s"], b["cpu_s"]],
            "performance": [ap, bp],
            "sample_thermal_states": [sorted({s["thermal"] for s in r["samples"]}) for r in reports],
            "sample_app_states": [sorted({s["application_state"] for s in r["samples"]}) for r in reports]})
    model_policy = "accelerated" if accelerated_ball_model else "CPU"
    return {"scope": f"Foreground body-pose compute experiment; ball model {model_policy} in both arms, image compute CPU. No export timing or independent accuracy labels.", "clips": result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--accelerated-ball-model", action="store_true",
                        help="Require accelerated ball inference in both arms, as on iPhone 17")
    args = parser.parse_args()
    print(json.dumps(compare(args.baseline, args.candidate, args.accelerated_ball_model), indent=2))
