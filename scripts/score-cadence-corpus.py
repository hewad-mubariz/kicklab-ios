#!/usr/bin/env python3
"""Score fresh CadenceBenchmark corpus traces against the frozen corpus labels.

Usage: score-cadence-corpus.py RESULTS_DIR --output REPORT_JSON [--profile normal-phase0]
Each clip needs <id>-<profile>-trace.plist and <id>-<profile>-summary.json in RESULTS_DIR.
Time-based matching only; frame indices differ from the frozen inputs.
"""
import argparse, importlib.util, json, plistlib
from collections import Counter
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "benchmarks/touch-counting/corpus-20261014"
spec = importlib.util.spec_from_file_location("corpus_score", CORPUS / "score.py")
scorer = importlib.util.module_from_spec(spec); spec.loader.exec_module(scorer)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("results", type=Path); p.add_argument("--output", required=True, type=Path)
    p.add_argument("--profile", default="normal-phase0-paced")
    a = p.parse_args()
    manifest = json.loads((CORPUS / "manifest.json").read_text())
    rows, totals = [], Counter()
    for clip in manifest["clips"]:
        name = clip["id"]
        trace_path = a.results / f"{name}-{a.profile}-trace.plist"
        summary_path = a.results / f"{name}-{a.profile}-summary.json"
        if not trace_path.exists():
            rows.append(dict(id=name, status="missing")); continue
        trace = plistlib.loads(trace_path.read_bytes()); summary = json.loads(summary_path.read_text())
        if not trace["complete"] or not trace["operations"][-1]["flush"]:
            raise ValueError(f"Incomplete trace: {name}")
        if summary["sourceDigest"] != clip["sha256"]:
            raise ValueError(f"Source mismatch: {name}")
        labels = json.loads((CORPUS / "labels" / f"{name}.json").read_text())
        if labels["source_sha256"] != clip["sha256"]:
            raise ValueError(f"Labels belong to another source: {name}")
        compact = {"touches": [dict(t) for t in trace["touches"]],
                   "diagnostics": [dict(d) for d in trace.get("diagnostics", [])]}
        s = scorer.score(labels, compact)
        row = dict(id=name, status="scored", count=len(trace["touches"]), analysis_fps=round(summary["analysisFPS"], 2),
                   analysis_frames=summary["analysisFrames"], pipeline=summary["pipeline"], model=summary["model"],
                   rejections=dict(Counter(d["value"].get("rejection", "accepted") for d in trace["decisions"])), score=s)
        rows.append(row)
        for k in ("labelled_valid", "accepted_valid"): totals[k] += s[k]
        totals["missed_valid"] += len(s["missed_valid"]); totals["false_accepted"] += len(s["false_accepted"])
        totals["uncertain_accepted"] += len(s["uncertain_accepted"]); totals["unreviewed_accepted"] += len(s["unmatched_needing_review"])
        totals["clips"] += 1
    report = dict(scope="Fresh production live pipeline (RF-DETR, rf-v1 association) at normal <=30 fps cadence on the staged corpus videos; current default counting policy; time-based label matching.",
                  totals=dict(totals), clips=rows)
    a.output.parent.mkdir(parents=True, exist_ok=True); a.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(dict(totals), indent=1))
    for r in rows:
        if r["status"] == "scored":
            s = r["score"]; print(f"{r['id']:34s} fps={r['analysis_fps']:5.1f} count={r['count']:4d} valid={s['accepted_valid']}/{s['labelled_valid']} missed={len(s['missed_valid'])} false={len(s['false_accepted'])} uncertain={len(s['uncertain_accepted'])} unreviewed={len(s['unmatched_needing_review'])}")
        else: print(f"{r['id']:34s} {r['status']}")
if __name__ == "__main__": main()
