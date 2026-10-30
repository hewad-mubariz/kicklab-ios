#!/usr/bin/env python3
"""Fail on any appearance-result change; wall-time numbers are diagnostic only."""
import json
import statistics
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        raise SystemExit("compare.py reference.json candidate.json [candidate2.json ...]")
    reports = [(name, json.loads(Path(name).read_text())["runs"]) for name in sys.argv[1:]]
    for name, runs in reports:
        if not runs:
            raise SystemExit(f"No runs in {name}")
    reference = reports[0][1][0]
    for name, runs in reports:
        for index, run in enumerate(runs):
            if run["rows"] != reference["rows"] or run.get("exposure") != reference.get("exposure"):
                raise SystemExit(f"Appearance changed: {name}, run {index + 1}")
            if run["accepted"] != reference["accepted"]:
                raise SystemExit(f"Accepted-pair count changed: {name}, run {index + 1}")
        print(f"{name}: exact match; {len(reference['rows'])} frames; "
              f"{reference['accepted']} accepted; median {statistics.median(r['seconds'] for r in runs):.3f}s")
    print("Wall time is Mac-only and host-load dependent; not an iPhone speed claim.")


if __name__ == "__main__":
    main()
