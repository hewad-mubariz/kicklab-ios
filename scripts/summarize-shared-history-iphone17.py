#!/usr/bin/env python3
"""Summarize all completed paired iPhone17 shared-history runs without hiding failures."""
import collections, json, statistics, re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/shared-history-iphone17'
rows=[]
for arm in ['baseline','shared']:
    for path in sorted((BASE/arm/'iphone17').glob('*/summary.json')):
        s=json.loads(path.read_text());s['experimentArm']=arm;s['resultDirectory']=str(path.parent.relative_to(ROOT))
        p=s['poseTiming'];s['poseMeanMs']=p['totalMS']/p['calls'] if p['calls'] else None
        score=json.loads((path.parent/'label-score.json').read_text())
        s['acceptedLabelTimes']=[x['label_time_s'] for x in score['matched']]
        s['poseCallsPerSourceSecond']=p['calls']/s['sourceSeconds'];s['poseMsPerSourceSecond']=p['totalMS']/s['sourceSeconds']
        rows.append(s)
pairs=[]
for clip in sorted({r['clip'] for r in rows}):
    arms={arm:[r for r in rows if r['clip']==clip and r['experimentArm']==arm] for arm in ['baseline','shared']}
    row={'clip':clip,'arms':{}}
    for arm,rs in arms.items():
        if not rs:continue
        row['arms'][arm]={'runs':len(rs),'legalCounts':[r.get('acceptedValid') for r in rs],
          'totalCounts':[r['count'] for r in rs],'knownFalseCounts':[r.get('knownFalse') for r in rs],
          'knownFalseSeconds':[r.get('knownFalseSeconds') for r in rs],
          'meanPoseCalls':statistics.mean(r['poseTiming']['calls'] for r in rs),
          'meanPoseMsPerSourceSecond':statistics.mean(r['poseMsPerSourceSecond'] for r in rs),
          'meanPipelineLatencyMedianMs':statistics.mean(r['latencyMedianMs'] for r in rs),
          'meanPipelineLatencyP95Ms':statistics.mean(r['latencyP95Ms'] for r in rs),
          'acceptedLabelFrequency':dict(sorted(collections.Counter(str(t) for r in rs for t in r['acceptedLabelTimes']).items(),key=lambda x:float(x[0]))),
          'lateSourceSkips':sum(r['lateSourceSkips'] for r in rs),'worstThermal':max(r['worstThermal'] for r in rs)}
    if all(arms.values()):
        a,b=[row['arms'][x] for x in ['baseline','shared']]
        row['poseCallsChangePercent']=100*(b['meanPoseCalls']/a['meanPoseCalls']-1) if a['meanPoseCalls'] else None
        row['poseWorkChangePercent']=100*(b['meanPoseMsPerSourceSecond']/a['meanPoseMsPerSourceSecond']-1) if a['meanPoseMsPerSourceSecond'] else None
    pairs.append(row)
offline=[json.loads(x) for x in (BASE/'offline-screen.jsonl').read_text().splitlines()]
summary={'scope':'iPhone17 only; original video full live-pipeline paced replays. No normal import, camera-session or iPhone11 claim.',
 'offline':{'runs':len(offline),'uniqueClips':len({re.sub(r'-(control|pose2(?:-neuralEngine)?|tracking2)-r\d+(-person-warm)?$','',Path(x['path']).parent.name) for x in offline}),
 'baselineExactRuns':sum(x['baselineExact'] for x in offline),'countedEventsAcrossRepeatedRuns':sum(x['before'] for x in offline),
 'lostEvents':sum(len(x['lostMs']) for x in offline),'addedEvents':sum(len(x['addedMs']) for x in offline),
 'groundVerdictChanges':sum(len(x['groundVerdictChangedMs']) for x in offline),'holdingVerdictChanges':sum(len(x['holdingVerdictChangedMs']) for x in offline),
 'limitation':'Frozen body/hand decisions and existing alignment; not proof of fresh-Vision parity.'},
 'failedRuns':[str(p.relative_to(ROOT)) for p in BASE.glob('*/iphone17/*/failed.json')],
 'comparisons':pairs,'runs':rows}
(BASE/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'offline':summary['offline'],'failedRuns':summary['failedRuns'],'comparisons':pairs},indent=2))
