#!/usr/bin/env python3
"""Score paired ThermalVideoReview exports against a frozen source manifest.

python3 scripts/compare-juggling-accuracy.py MANIFEST BASELINE_DIR CANDIDATE_DIR
Outputs JSON to stdout. Incomplete runs fail instead of reporting partial accuracy.
Reference labels must declare their review scope and provenance. Negative controls
are reported separately, never folded into positive juggling recall.
"""
import argparse
import json
import math
import pathlib
import plistlib
from functools import lru_cache


def match_events(reference, predicted, tolerance):
    """Chronological one-to-one matching: maximize matches, then minimize error."""
    reference, predicted = sorted(reference), sorted(predicted)

    @lru_cache(None)
    def best(i, j):
        if i == len(reference) or j == len(predicted):
            return (0, 0.0, ())
        choices = [best(i + 1, j), best(i, j + 1)]
        delta = abs(reference[i] - predicted[j])
        if delta <= tolerance:
            n, cost, pairs = best(i + 1, j + 1)
            choices.append((n + 1, cost + delta, ((i, j),) + pairs))
        return max(choices, key=lambda x: (x[0], -x[1]))

    _, _, pairs = best(0, 0)
    ri, pi = {i for i, _ in pairs}, {j for _, j in pairs}
    return {
        "matched": len(pairs),
        "pairs": [[reference[i], predicted[j]] for i, j in pairs],
        "missed_reference_times": [t for i, t in enumerate(reference) if i not in ri],
        "unmatched_prediction_times": [t for j, t in enumerate(predicted) if j not in pi],
        "maximum_matched_delta_s": max((abs(reference[i] - predicted[j]) for i, j in pairs), default=None),
    }


def score(labels, predicted):
    if not labels or labels["scope"] not in ("reviewed_full_clip", "reviewed_visible_events", "negative_clip"):
        return {"status": "not_scored", "reason": "No exhaustive reference for a declared review scope."}
    intervals = labels.get("excluded_intervals", [])
    def excluded(t):
        return any(start <= t <= end for start, end in intervals)
    reference = [e["time_s"] for e in labels["events"] if e["counts"] and not excluded(e["time_s"])]
    included = [t for t in predicted if not excluded(t)]
    result = match_events(reference, included, labels["tolerance_s"])
    result.update(reference_count=len(reference), scored_prediction_count=len(included),
                  excluded_prediction_times=[t for t in predicted if excluded(t)],
                  precision=result["matched"] / len(included) if included else None,
                  recall=result["matched"] / len(reference) if reference else None,
                  scope=labels["scope"], provenance=labels["provenance"])
    return result


def box_iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    intersection = max(0, min(ax + aw/2, bx + bw/2) - max(ax - aw/2, bx - bw/2)) * max(0, min(ay + ah/2, by + bh/2) - max(ay - ah/2, by - bh/2))
    union = aw*ah + bw*bh - intersection
    return intersection/union if union > 0 else 1.0


def percentile(values, q):
    return sorted(values)[round((len(values)-1)*q)] if values else None


def compare_tracks(baseline, candidate, name):
    def read(folder):
        rows = plistlib.loads((folder / f"{name}-track.plist").read_bytes())
        result = {r["identity"]["index"]: r for r in rows}
        if len(result) != len(rows):
            raise ValueError(f"Duplicate frame identities: {folder}/{name}")
        return result
    a, b = read(baseline), read(candidate)
    common = sorted(a.keys() & b.keys())
    for k in common:
        if a[k]["identity"] != b[k]["identity"]:
            raise ValueError(f"Different frame identity/time/coordinate space at {name}:{k}")
    ious = [box_iou(a[k]["values"][1:5], b[k]["values"][1:5]) for k in common]
    distances = [math.dist(a[k]["values"][1:3], b[k]["values"][1:3]) for k in common]
    return dict(baseline_detection_frames=len(a), candidate_detection_frames=len(b),
                baseline_only_frames=sorted(a.keys()-b.keys()), candidate_only_frames=sorted(b.keys()-a.keys()),
                common_detection_frames=len(common), box_iou_min=min(ious, default=None),
                box_iou_p05=percentile(ious, .05), box_iou_median=percentile(ious, .5),
                center_delta_normalized_max=max(distances, default=None),
                exact_stored_record_matches=sum(a[k] == b[k] for k in common))


def compare_frame_schedule(baseline, candidate, name, expected_frames):
    traces = [plistlib.loads((folder / f"{name}-trace.plist").read_bytes()) for folder in (baseline, candidate)]
    if any(not t["complete"] or not t["operations"][-1]["flush"] for t in traces):
        raise ValueError(f"Incomplete counter evidence: {name}")
    if any(traces[0][k] != traces[1][k] for k in ("revision", "config", "usesHandVerifier", "usesFootVerifier")):
        raise ValueError(f"Counter configuration changed: {name}")
    schedules = []
    for trace in traces:
        schedules.append([(op["input"]["frameIndex"], op["input"].get("sourceFrameIndex"), op["input"]["timestampMs"])
                          for op in trace["operations"] if op.get("input") is not None])
    if schedules[0] != schedules[1] or len(schedules[0]) != expected_frames:
        raise ValueError(f"Analyzed source frame/timestamp schedule differs: {name}")
    return {"identical": True, "frames": len(schedules[0]), "counter_revision": traces[0]["revision"]}


def load_report(folder, model_study):
    report = json.loads((folder / "report.json").read_text())
    if report["status"] != "completed":
        raise ValueError(f"Incomplete run: {folder}")
    if not report.get("accuracy_comparison") or not report.get("cache_bypassed"):
        raise ValueError("Paired comparisons require pinned image compute and bypassed caches")
    if report.get("foreground_acceleration_study") or report.get("model_acceleration_study") != model_study:
        raise ValueError(f"Wrong compute mode: {folder}")
    for run in report["runs"]:
        performance = run["performance"]
        if run.get("visual_only") or any(performance.get(k) != 0 for k in ("cache_hit", "detection_errors", "contact_error")):
            raise ValueError(f"Cached, visual-only or failed analysis cannot qualify accuracy: {folder}/{run['id']}")
    samples = [s["pipeline"] for s in report["samples"] if s.get("pipeline", {}).get("frames", s.get("frames", 0)) > 0 and "cpu_only" in s.get("pipeline", {})]
    if not samples or any(s["cpu_only"] != 1 for s in samples):
        raise ValueError(f"Image/Vision CPU policy unverified: {folder}")
    model_values = {s["model_cpu_only"] for s in samples}
    if (model_study and 0 not in model_values) or (not model_study and model_values != {1}):
        raise ValueError(f"Model compute policy unverified: {folder}")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=pathlib.Path)
    parser.add_argument("baseline", type=pathlib.Path)
    parser.add_argument("candidate", type=pathlib.Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    baseline, candidate = load_report(args.baseline, False), load_report(args.candidate, True)
    a, b = ({r["id"]: r for r in report["runs"]} for report in (baseline, candidate))
    expected = {"0-" + c["id"] for c in manifest["clips"]}
    if set(a) != expected or set(b) != expected:
        raise ValueError("Run IDs do not exactly match the frozen manifest")
    results = []
    for clip in manifest["clips"]:
        name = clip["id"]
        ar, br = a["0-" + name], b["0-" + name]
        if ar["source"] != clip["device_file"] or br["source"] != clip["device_file"]:
            raise ValueError(f"Wrong source filename for {name}")
        if ar["frames"] != br["frames"] or ar["model"] != br["model"]:
            raise ValueError(f"Model or analyzed frame count differs for {name}")
        at, bt = ([t[0] for t in r["touches"]] for r in (ar, br))
        results.append(dict(id=name, role=clip["role"], baseline_count=ar["count"], candidate_count=br["count"],
                            analysis_frames=ar["frames"], baseline_elapsed_s=ar["elapsed_s"], candidate_elapsed_s=br["elapsed_s"],
                            baseline_score=score(clip["labels"], at), candidate_score=score(clip["labels"], bt),
                            event_parity=match_events(at, bt, .12), exact_touch_timestamps=at == bt,
                            frame_schedule=compare_frame_schedule(args.baseline, args.candidate, name, ar["frames"]),
                            track_comparison=compare_tracks(args.baseline, args.candidate, name)))
    print(json.dumps(dict(scope=manifest["scope"],
                         caveats=["Assistant-reviewed development references, not independent held-out accuracy.",
                                  "Output parity alone does not establish accuracy.",
                                  "Run timings are descriptive; starting thermal conditions are not controlled.",
                                  "Excluded intervals do not contribute to recall or precision."],
                         clips=results), indent=2))


if __name__ == "__main__":
    main()
