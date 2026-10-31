#!/usr/bin/env python3
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/pose-input-iphone17/fallback'
rows=[]
for arm in ['baseline','fallback']:
    for path in (BASE/arm/'iphone17').glob('*/summary.json'):
        if not (path.parent/'complete.json').exists():continue
        s=json.loads(path.read_text())
        if 'fallbackCalls' not in s:continue
        score=json.loads((path.parent/'label-score.json').read_text())
        status=json.loads((path.parent/'status.json').read_text())
        report=json.loads((path.parent/'report.json').read_text())
        assert status['trace_replay_exact'] and not report['quality_failed']
        assert s['build']=='2026103006' and s['worstThermal']<=1
        s.update(directory=str(path.parent.relative_to(ROOT)),acceptedLabels={r['label_id']:r['label_time_s'] for r in score['matched']},
            overflow=report['overflow_drops'],lateRF=report['late_replies'])
        rows.append(s)
pairs=[]
for clip,repeat in sorted({(r['clip'],r['repeat']) for r in rows}):
    arms={r['experimentArm']:r for r in rows if r['clip']==clip and r['repeat']==repeat}
    if len(arms)!=2:continue
    a,b=arms['baseline'],arms['fallback'];aa,bb=a['acceptedLabels'],b['acceptedLabels']
    assert a['sourceSHA256']==b['sourceSHA256']
    pair=dict(clip=clip,repeat=repeat,legal=[a['acceptedValid'],b['acceptedValid']],false=[a['knownFalse'],b['knownFalse']],
        unmatched=[a['unmatchedNeedingReview'],b['unmatchedNeedingReview']],
        gainedSeconds=sorted(bb[k] for k in bb.keys()-aa.keys()),lostSeconds=sorted(aa[k] for k in aa.keys()-bb.keys()),
        fallbackCalls=b['fallbackCalls'],fallbackMatched=b['fallbackMatched'],fallbackMS=b['fallbackMS'],
        rawEmpty=[a['poseTiming']['empty'],b['poseTiming']['empty']])
    pairs.append(pair);print(pair)
(BASE/'summary.json').write_text(json.dumps(dict(runs=rows,pairs=pairs,completedRuns=len(rows)),indent=2)+'\n')
print('Completed',len(rows))
