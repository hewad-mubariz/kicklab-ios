#!/usr/bin/env python3
"""Compare saved ankle evidence at common contact timestamps, without inferring pixel identity."""
import json
import plistlib
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/vision-revisions-20261030/impact-neighbor-iphone17'


def ankle_records(path):
    trace = plistlib.loads(path.read_bytes())
    records = defaultdict(set)

    def visit(value):
        if isinstance(value, dict):
            if all(k in value for k in ['timestampMs', 'ankles', 'ballX']):
                records[value['timestampMs']].add(json.dumps(value['ankles'], sort_keys=True))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(trace['decisions'])
    return records


rows = []
for version, subdirectory in [(1, ''), (2, 'v2'), (3, 'v3'), (4, 'budget-only')]:
    directory = BASE / subdirectory
    if not (directory / 'summary.json').exists():
        continue
    summary = json.loads((directory / 'summary.json').read_text())
    for pair in summary['pairs']:
        runs = {r['experimentArm']: r for r in summary['runs']
                if r['clip'] == pair['clip'] and r['repeat'] == pair['repeat']}
        assert runs['baseline']['sourceSHA256'] == runs['reserved']['sourceSHA256']
        a, b = [ankle_records(ROOT / runs[arm]['directory'] / 'counter.plist')
                for arm in ['baseline', 'reserved']]
        common = sorted(a.keys() & b.keys())
        changed = [t for t in common if a[t] != b[t]]
        row = dict(version=version, clip=pair['clip'], repeat=pair['repeat'],
                   commonTimestamps=len(common), changedTimestampsMs=changed,
                   withinRunVariantTimestampsMs={arm: [t for t, v in data.items() if len(v) > 1]
                                                for arm, data in [('baseline', a), ('reserved', b)]},
                   changedRecords=[dict(timestampMs=t,
                                        baseline=[json.loads(v) for v in sorted(a[t])],
                                        candidate=[json.loads(v) for v in sorted(b[t])])
                                   for t in changed],
                   rawPoseEmptyCalls=[runs[arm]['poseTiming']['empty'] for arm in ['baseline', 'reserved']])
        rows.append(row)
        print(version, pair['clip'], 'common', len(common), 'changed', len(changed),
              'raw empty calls', row['rawPoseEmptyCalls'])

result = dict(
    scope='Saved selected-player ankle evidence at equal source timestamps in paired completed runs.',
    limitation='Input pixel hashes and raw per-frame pose counts were not saved. An empty selected ankle record can reflect missing pose, person selection or evidence preparation. Aggregate empty-call counters do not locate each raw empty result. This is not proof of an Apple model bug or identical pose input pixels.',
    pairs=rows)
(BASE / 'same-timestamp-pose-evidence.json').write_text(json.dumps(result, indent=2) + '\n')
