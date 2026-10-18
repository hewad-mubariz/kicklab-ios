#!/usr/bin/env python3
"""Score selected, visually labelled contacts using identical frozen detections.

Usage: score-touch-benchmark.py LABELS SOURCE_ARCHIVE BEFORE_TRACE AFTER_TRACE
Only labelled events are scored. Unlabelled counts are not assumed correct.
"""
import argparse
import json
from pathlib import Path
import plistlib


def read_trace(path):
    trace = plistlib.loads(path.read_bytes())
    if not trace['complete'] or not trace['operations'][-1]['flush']:
        raise ValueError(f'Incomplete trace: {path}')
    return trace


def score(trace, events):
    accepted = {t['frameIndex'] for t in trace['touches']}
    valid = [e for e in events if e['counts']]
    invalid = [e for e in events if not e['counts']]
    return dict(total_count=len(accepted), labelled_valid=len(valid), labelled_invalid=len(invalid),
                accepted_valid=sum(e['frame'] in accepted for e in valid),
                missed_valid=[e['frame'] for e in valid if e['frame'] not in accepted],
                false_counts=[e['frame'] for e in invalid if e['frame'] in accepted])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['labels', 'archive', 'before', 'after']:
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    labels = json.loads(args.labels.read_text())
    archive = plistlib.loads(args.archive.read_bytes())
    before, after = read_trace(args.before), read_trace(args.after)
    if archive['sourceDigest'] != labels['sourceDigest']:
        raise ValueError('Labels belong to a different recording')
    if before['operations'] != after['operations'] or before['operations'] != archive['trace']['operations']:
        raise ValueError('Frozen detections or source frame/timestamp schedule differs')
    events = labels['events']
    frames = [e['frame'] for e in events]
    source = {op['input']['frameIndex']: op['input']['timestampMs'] for op in before['operations'] if 'input' in op}
    if len(set(frames)) != len(frames) or any(e['frame'] not in source for e in events):
        raise ValueError('Duplicate or missing labelled frame')
    for event in events:
        time = source[event['frame']]/1000-archive['timeOriginSeconds']
        if abs(time-event['time_s']) > 0.002:
            raise ValueError('Label timestamp differs from source')
    old, new = ({t['frameIndex'] for t in tr['touches']} for tr in [before, after])
    print(json.dumps(dict(scope=labels['scope'], provenance=labels['provenance'],
                         before=score(before,events), after=score(after,events),
                         removed=sorted(old-new), added=sorted(new-old),
                         caveat='Selected development events, not full-clip or held-out accuracy.'), indent=2))


if __name__ == '__main__':
    main()
