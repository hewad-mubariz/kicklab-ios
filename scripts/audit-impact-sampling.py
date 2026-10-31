#!/usr/bin/env python3
"""Separate observed detector results from opportunities no run measured."""
import json
from collections import defaultdict
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/impact-neighbor-iphone17'
roots=[ROOT/'artifacts/vision-revisions-20261029/compact-window-iphone17',BASE,BASE/'v2',BASE/'v3',BASE/'budget-only']
windows={'raw-juggling':[(4.1,4.8),(5.3,5.9),(6.3,6.9)],
         'low':[(3.9,4.3),(53.7,54.4)],'clip-618a1688fcc6':[(7.15,7.65)]}
observations=defaultdict(list)
for root in roots:
    for path in root.glob('*/iphone17/*/report.json'):
        if not (path.parent/'complete.json').exists():continue
        s=json.loads((path.parent/'summary.json').read_text())
        if s['clip'] not in windows:continue
        report=json.loads(path.read_text())
        samples={r['frame']:r for r in report['samples']}
        for e in report['rf_events']:
            t=e['source_seconds']
            if not any(a<=t<=b for a,b in windows[s['clip']]):continue
            row={'run':str(path.parent.relative_to(ROOT)), 'candidateCount':e['candidate_count'],
                 'use':e['use'],'purpose':e.get('purpose','regular')}
            if e['use']=='used_direct_at_original_frame':
                sample=samples.get(e['source_frame'],{})
                row.update(box=sample.get('box_xywh_normalized'),score=sample.get('seed_detector_score'))
            observations[(s['clip'],s['sourceSHA256'],round(t,6))].append(row)
rows=[]
for (clip,sha,t),runs in sorted(observations.items()):
    counts={r['candidateCount'] for r in runs}
    boxes={tuple(r['box']) for r in runs if r.get('box')}
    rows.append(dict(clip=clip,sourceSHA256=sha,sourceSeconds=t,measurements=runs,
        candidateCountConsistent=len(counts)==1,acceptedBoxConsistent=len(boxes)<=1))
summary=dict(scope='Only frames actually measured by RF. A missing measurement is not a negative detection.',
    sources=rows, repeatedSourceFrames=sum(len(r['measurements'])>1 for r in rows),
    repeatedCandidateCountDisagreements=sum(len(r['measurements'])>1 and not r['candidateCountConsistent'] for r in rows),
    acceptedBoxDisagreements=sum(not r['acceptedBoxConsistent'] for r in rows))
(BASE/'same-source-rf-audit.json').write_text(json.dumps(summary,indent=2)+'\n')
print({k:v for k,v in summary.items() if k!='sources'})
for r in rows:
    if r['clip']=='raw-juggling' and 4.3<r['sourceSeconds']<4.5:
        print(r['clip'],r['sourceSeconds'],'counts',sorted({s['candidateCount'] for s in r['measurements']}),
              'measurements',len(r['measurements']))
