#!/usr/bin/env python3
"""Score body-gate ablation without changing the frozen corpus labels/results.

Usage: compare-body-gate-replay.py SOURCES_JSON REPLAY_OUTPUT --output REPORT_JSON
Requires every requested before/after trace, identical inputs/configuration,
and complete, flushed runs. Newly accepted unlabelled events need visual review.
"""
import argparse
import importlib.util
import json
import plistlib
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "benchmarks/touch-counting/corpus-20261014"
spec = importlib.util.spec_from_file_location("corpus_score", CORPUS / "score.py")
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


def read_trace(path):
    trace = plistlib.loads(path.read_bytes())
    if not trace["complete"] or not trace["operations"][-1]["flush"]:
        raise ValueError(f"Incomplete replay: {path}")
    return trace


def compact(trace, origin):
    return {
        "touches": [dict(t, timestampMs=t["timestampMs"]-origin*1000) for t in trace["touches"]],
        "diagnostics": [dict(d, time=d["time"]-origin) for d in trace.get("diagnostics", [])],
    }


def compare(source, folder):
    name = source["id"]
    archive = plistlib.loads(Path(source["trace_path"]).read_bytes())
    if archive["sourceDigest"] != source["sourceDigest"]:
        raise ValueError(f"Source identity mismatch: {name}")
    a, b = [read_trace(folder / f"{name}-{arm}.plist") for arm in ("before", "after")]
    if a["operations"] != b["operations"] or a["operations"] != archive["trace"]["operations"]:
        raise ValueError(f"Changed source inputs or scheduling: {name}")
    for key in ("config", "revision", "usesBodyVerifier", "usesGroundVerifier", "usesHandVerifier", "usesFootVerifier", "usesHandlingVerifier"):
        if a.get(key) != b.get(key):
            raise ValueError(f"Non-body configuration changed: {name}/{key}")
    old, new = [{t["frameIndex"]: t for t in x["touches"]} for x in (a, b)]
    original = {d["value"]["frameIndex"]: d["value"] for d in a["decisions"]}
    audits = [{d["frameIndex"]: d for d in json.loads((folder / f"{name}-{arm}-body-gate.json").read_text())}
              for arm in ("before", "after")]
    # Independent image passes should agree on original eligibility wherever
    # both evaluated it. Disagreement invalidates attribution to the bypass.
    differences = [frame for frame in audits[0].keys() & audits[1].keys()
                   if (audits[0][frame]["originalBodyAllowed"], audits[0][frame].get("originalBodyFailure"))
                   != (audits[1][frame]["originalBodyAllowed"], audits[1][frame].get("originalBodyFailure"))]
    if differences:
        raise ValueError(f"Original body evidence differs between passes: {name}/{differences}")
    origin = archive["timeOriginSeconds"]
    added = [dict(frame=frame, time_s=new[frame]["timestampMs"]/1000-origin,
                  previous_rejection=original.get(frame, {}).get("rejection"),
                  original_body_failure=audits[1].get(frame, {}).get("originalBodyFailure"),
                  hand_confirmed=audits[1].get(frame, {}).get("handConfirmed")) for frame in sorted(new.keys()-old.keys())]
    row = dict(id=name, source_sha256=source["sourceDigest"], inputs_identical=True,
               config_identical=True, original_body_evidence_identical=True,
               before_count=len(old), after_count=len(new), added=added,
               removed=[dict(frame=f,time_s=old[f]["timestampMs"]/1000-origin) for f in sorted(old.keys()-new.keys())],
               before_rejections=dict(Counter(d["value"].get("rejection", "accepted") for d in a["decisions"])),
               after_rejections=dict(Counter(d["value"].get("rejection", "accepted") for d in b["decisions"])))
    label_path = CORPUS / "labels" / f"{name}.json"
    if label_path.exists():
        labels = json.loads(label_path.read_text())
        if labels["source_sha256"] != source["sourceDigest"]:
            raise ValueError(f"Labels belong to another source: {name}")
        row["before_score"] = scorer.score(labels, compact(a, origin))
        row["after_score"] = scorer.score(labels, compact(b, origin))
    if name == "walkthrough":
        labels = json.loads((ROOT / "benchmarks/touch-counting/final-juggling-walkthrough-20261017/summary.json").read_text())["touchReview"]["labels"]
        row["previously_reviewed_misses"] = [dict(time_s=e["timeSeconds"],
            before_counted=any(abs(t["timestampMs"]/1000-origin-e["timeSeconds"]) <= .2 for t in old.values()),
            after_counted=any(abs(t["timestampMs"]/1000-origin-e["timeSeconds"]) <= .2 for t in new.values())) for e in labels]
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path)
    parser.add_argument("replay_output", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    rows = [compare(source, args.replay_output) for source in json.loads(args.sources.read_text())]
    totals = {}
    for arm in ("before", "after"):
        scored = [r[f"{arm}_score"] for r in rows if f"{arm}_score" in r]
        totals[arm] = dict(clips=len(scored), labelled_valid=sum(s["labelled_valid"] for s in scored),
            accepted_valid=sum(s["accepted_valid"] for s in scored),
            missed_valid=sum(len(s["missed_valid"]) for s in scored),
            false_accepted=sum(len(s["false_accepted"]) for s in scored),
            uncertain_accepted=sum(len(s["uncertain_accepted"]) for s in scored),
            unreviewed_accepted=sum(len(s["unmatched_needing_review"]) for s in scored))
    report = dict(scope="Current counting rules, frozen historical ball/person inputs, new iPhone Vision evidence; only body rejection bypassed in the after arm.",
        limitations=["Development corpus labels are assistant-reviewed, not independent held-out certification.",
                     "Frozen input replay does not test live detector changes, scheduling or camera performance.",
                     "The walkthrough has selected positive labels only; extra counts require visual review.",
                     "An unknown or unreviewed accepted event is not credited as a correct touch."],
        totals=totals, clips=rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(totals, indent=2))


if __name__ == "__main__":
    main()
