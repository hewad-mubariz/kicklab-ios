#!/usr/bin/env python3
"""Compare complete, identical-input contact-evidence replays using frozen labels.

This evaluates evidence recovery/classification, not the live tracking retry.
Uncertain and unmatched events never receive true-positive credit.
"""
import argparse
import importlib.util
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "benchmarks/touch-counting/corpus-20261014"
spec = importlib.util.spec_from_file_location("corpus_score", CORPUS / "score.py")
scorer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scorer)


def compare(source, folder):
    name = source["id"]
    archive = plistlib.loads((ROOT / source["trace_path"]).read_bytes())
    if archive["sourceDigest"] != source["sourceDigest"]:
        raise ValueError(f"Source mismatch: {name}")
    traces = [plistlib.loads((folder / f"{name}-{arm}.plist").read_bytes()) for arm in ("before", "after")]
    for arm, trace in zip(("before", "after"), traces):
        if not trace["complete"] or not trace["operations"][-1]["flush"]:
            raise ValueError(f"Incomplete trace: {name}/{arm}")
        if trace["operations"] != archive["trace"]["operations"]:
            raise ValueError(f"Trajectory inputs changed: {name}/{arm}")
        # These files are emitted only by the instrumented comparison harness.
        json.loads((folder / f"{name}-{arm}-rechecks.json").read_text())
    for key in ("config", "revision", "usesHandVerifier", "usesBodyVerifier", "usesFootVerifier", "usesGroundVerifier", "usesHandlingVerifier"):
        if traces[0].get(key) != traces[1].get(key):
            raise ValueError(f"Counter configuration changed: {name}/{key}")
    origin = archive["timeOriginSeconds"]
    accepted = [{x["frameIndex"]: x["timestampMs"]/1000-origin for x in t["touches"]} for t in traces]
    row = dict(id=name, source_sha256=source["sourceDigest"], inputs_identical=True,
               before_count=len(accepted[0]), after_count=len(accepted[1]),
               added=[dict(frame=k, time_s=v) for k, v in accepted[1].items() if k not in accepted[0]],
               removed=[dict(frame=k, time_s=v) for k, v in accepted[0].items() if k not in accepted[1]])
    label_path = CORPUS / "labels" / f"{name}.json"
    if label_path.exists():
        labels = json.loads(label_path.read_text())
        if labels["source_sha256"] != source["sourceDigest"]:
            raise ValueError(f"Label identity mismatch: {name}")
        for arm, trace in zip(("before", "after"), traces):
            compact = dict(touches=[dict(t, timestampMs=t["timestampMs"]-origin*1000) for t in trace["touches"]],
                           diagnostics=[dict(d, time=d["time"]-origin) for d in trace.get("diagnostics", [])])
            row[arm+"_score"] = scorer.score(labels, compact)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path)
    parser.add_argument("results", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if (args.results / "status.txt").read_text().strip() != "DONE":
        raise ValueError("Replay has not completed")
    configs = [json.loads(p.read_text()) for p in [args.results / "config.json", *sorted(args.results.glob("run-config-*.json"))]]
    sources = json.loads(args.sources.read_text())
    scheduled = {c["id"] for config in configs for c in config["clips"]}
    comparisons = {config["comparison"] for config in configs}
    if len(comparisons) != 1 or not comparisons <= {"contactEvidence", "impactWindow"} or scheduled != {s["id"] for s in sources}:
        raise ValueError("Comparison configuration does not match requested sources")
    rows = [compare(source, args.results) for source in sources]
    totals = {}
    for arm in ("before", "after"):
        scores = [r[arm+"_score"] for r in rows if arm+"_score" in r]
        totals[arm] = dict(clips=len(scores), labelled_valid=sum(s["labelled_valid"] for s in scores),
            accepted_valid=sum(s["accepted_valid"] for s in scores),
            missed_valid=sum(len(s["missed_valid"]) for s in scores),
            false_accepted=sum(len(s["false_accepted"]) for s in scores),
            uncertain_accepted=sum(len(s["uncertain_accepted"]) for s in scores),
            unreviewed_accepted=sum(len(s["unmatched_needing_review"]) for s in scores))
    versions = "v16 versus v17" if comparisons == {"impactWindow"} else "v15 versus v16"
    report = dict(scope=f"Frozen inputs; fresh Vision and bounded RF contact rechecks in both arms; {versions} contact rules. No live tracking retry in this comparison.", totals=totals, clips=rows)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+"\n")
    print(json.dumps(totals, indent=2))


if __name__ == "__main__":
    main()
