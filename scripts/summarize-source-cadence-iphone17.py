#!/usr/bin/env python3
import json,statistics,itertools,hashlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/source-cadence-final-iphone17'
rows=[]
for arm in ['baseline','source10','source12']:
 for path in sorted((BASE/arm/'iphone17').glob('*/summary.json')):
  s=json.loads(path.read_text());r=json.loads((path.parent/'report.json').read_text())
  score=json.loads((path.parent/'label-score.json').read_text());status=json.loads((path.parent/'status.json').read_text())
  frames=[e['source_frame'] for e in r['rf_events'] if e.get('purpose','regular')=='regular']
  s.update(experimentArm=arm,resultDirectory=str(path.parent.relative_to(ROOT)),regularFrames=frames,
   regularTimestampsMs=[round(e['source_seconds']*1000) for e in r['rf_events'] if e.get('purpose','regular')=='regular'],regularCalls=len(frames),regularRFHz=len(frames)/s['sourceSeconds'],worker=r['worker'],sourceCadenceSkips=r['source_cadence_skips'],
   sourceOpportunities=r['source_cadence_opportunities'],regularFramesSHA=hashlib.sha256(json.dumps(frames).encode()).hexdigest(),
   acceptedLabels=[e['label_time_s'] for e in score['matched']],traceReplayExact=status['trace_replay_exact'],
   notificationLatencyMedianMs=statistics.median(r.get('notification_latency_ms',[])) if r.get('notification_latency_ms') else None)
  rows.append(s)
comparisons=[]
for clip in sorted({r['clip'] for r in rows}):
 c={'clip':clip,'arms':{}}
 for arm in ['baseline','source10','source12']:
  rs=[r for r in rows if r['clip']==clip and r['experimentArm']==arm]
  if not rs:continue
  common=set.intersection(*(set(r['regularTimestampsMs']) for r in rs));union=set.union(*(set(r['regularTimestampsMs']) for r in rs))
  c['arms'][arm]={'runs':len(rs),'legalCounts':[r['acceptedValid'] for r in rs],'falseCounts':[r['knownFalse'] for r in rs],
   'unreviewed':[r['unmatchedNeedingReview'] for r in rs], 'meanRegularRFHz':statistics.mean(r['regularRFHz'] for r in rs),
   'meanPoseMsPerSecond':statistics.mean(r['poseTiming']['totalMS']/r['sourceSeconds'] for r in rs),
   'meanLatencyMedianMs':statistics.mean(r['latencyMedianMs'] for r in rs),
   'meanLatencyP95Ms':statistics.mean(r['latencyP95Ms'] for r in rs),
   'regularScheduleIntersectionOverUnion':len(common)/len(union) if union and len(rs)>1 else None,
   'missedLegalTimes':[r['missedLegalSeconds'] for r in rs], 'falseTimes':[r['knownFalseSeconds'] for r in rs],
   'thermalMax':max(r['worstThermal'] for r in rs),'maxWorkerConcurrency':max(r['worker']['maximum_active'] for r in rs)}
 comparisons.append(c)
report={'scope':'iPhone17 only, fresh original-video paced live pipeline, revision2 with full pose evidence in every arm; build2026102919',
 'completedRuns':len(rows),'failedRuns':[str(p.relative_to(ROOT)) for p in BASE.glob('*/iphone17/*/failed.json')],
 'comparisons':comparisons,'runs':rows}
(BASE/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
for c in comparisons:
 print(c['clip'],{a:dict(legal=r['legalCounts'],false=r['falseCounts'],rfHz=round(r['meanRegularRFHz'],2),scheduleIoU=r['regularScheduleIntersectionOverUnion']) for a,r in c['arms'].items()})
