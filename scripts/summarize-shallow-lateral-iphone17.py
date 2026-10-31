#!/usr/bin/env python3
"""Event-level and performance summary; higher totals alone are not a pass."""
import json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/contact-evidence-audit-iphone17'
rows=[]
for arm in ['baseline','lateral']:
    for path in sorted((BASE/arm/'iphone17').glob('*/summary.json')):
        if not (path.parent/'complete.json').exists():continue
        s=json.loads(path.read_text());report=json.loads((path.parent/'report.json').read_text())
        score=json.loads((path.parent/'label-score.json').read_text())
        run=json.loads((path.parent/'run.json').read_text())
        status=json.loads((path.parent/'status.json').read_text())
        assert status['trace_replay_exact'] and not report['quality_failed']
        v=status['visionRevisions']
        assert v['sourceCadenceVersion']==0 and not v['sharedPoseHistory']
        assert v['shallowLateralContact']==(arm=='lateral')
        s.update(experimentArm=arm,repeat=run['repeat'],resultDirectory=str(path.parent.relative_to(ROOT)),
            acceptedLabels={e['label_id']:e['label_time_s'] for e in score['matched']},
            notificationLatencyMedianMs=statistics.median(report['notification_latency_ms']) if report.get('notification_latency_ms') else None,
            lateReplies=report.get('late_replies'),overflowDrops=report.get('overflow_drops'),
            regularFrames=[e['source_frame'] for e in report['rf_events'] if e.get('purpose','regular')=='regular'])
        rows.append(s)
pairs=[]
for clip,repeat in sorted({(r['clip'],r['repeat']) for r in rows}):
    arms={r['experimentArm']:r for r in rows if r['clip']==clip and r['repeat']==repeat}
    if len(arms)!=2:continue
    a,b=arms['baseline'],arms['lateral'];aa,bb=a['acceptedLabels'],b['acceptedLabels']
    pairs.append(dict(clip=clip,repeat=repeat,legal=[a['acceptedValid'],b['acceptedValid']],
        knownFalse=[a['knownFalse'],b['knownFalse']],unmatched=[a['unmatchedNeedingReview'],b['unmatchedNeedingReview']],
        gainedSeconds=sorted(bb[k] for k in bb.keys()-aa.keys()),lostSeconds=sorted(aa[k] for k in aa.keys()-bb.keys()),
        sameRegularFrames=a['regularFrames']==b['regularFrames']))
summary={'scope':'iPhone17 fresh paced replay; body pose revision2 in both arms, build2026102921',
    'completedRuns':len(rows),'pairs':pairs,'runs':rows}
(BASE/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for p in pairs:print(p)
