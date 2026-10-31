#!/usr/bin/env python3
"""Event-level accuracy and actual reserved-work outcomes, not totals alone."""
import argparse, json, statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/impact-neighbor-iphone17'
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--version',type=int,choices=[1,2,3,4],default=1)
args=p.parse_args();build=f'202610300{args.version}'
if args.version>1:BASE=BASE/('budget-only' if args.version==4 else f'v{args.version}')
rows=[]
for arm in ['baseline','reserved']:
    for path in sorted((BASE/arm/'iphone17').glob('*/summary.json')):
        if not (path.parent/'complete.json').exists():continue
        read=lambda f:json.loads((path.parent/f).read_text())
        s,run,status,report,score=[read(f) for f in ['summary.json','run.json','status.json','report.json','label-score.json']]
        assert status['trace_replay_exact'] and not report['quality_failed']
        assert s['build']==run['build']==build
        reservationSelected=arm=='reserved' and args.version!=4
        assert report['reserved_gap_enabled']==reservationSelected
        v=status['visionRevisions']
        assert v['reservedImpactGap']==reservationSelected and v['sourceCadenceVersion']==0
        if args.version==4:assert v['trackingDrainBudget']==(arm=='reserved')
        assert not any(v[k] for k in ['compactReleaseWindow','resolvedFloorMargin','shallowLateralContact','sharedPoseHistory'])
        reserved=[e for e in report['rf_events'] if 'reserved_wait_ms' in e]
        assert len(reserved)==report['reserved_gap_submissions']
        s.update(experimentArm=arm,repeat=run['repeat'],directory=str(path.parent.relative_to(ROOT)),
            acceptedLabels={e['label_id']:e['label_time_s'] for e in score['matched']},
            reservedEvents=reserved,
            reservedSubmitted=len(reserved),reservedUsed=sum(e['use']=='used_direct_at_original_frame' for e in reserved),
            reservedExpired=sum(e['reason']=='reserved_gap_expired' for e in report['impact_gap_rechecks']),
            gapBusy=sum(e['reason']=='retry_worker_busy' for e in report['impact_gap_rechecks']),
            overflowDrops=report['overflow_drops'],lateReplies=report['late_replies'],
            drainBudgetYields=report.get('drain_budget_yields'),maxDrainMs=report.get('maximum_drain_ms'),
            maxFramesPerDrain=report.get('maximum_frames_per_drain'),slowDrains=report.get('slow_drains'),
            notificationLatencyMedianMs=statistics.median(report['notification_latency_ms']) if report['notification_latency_ms'] else None,
            regularSourceTimes=[e['source_seconds'] for e in report['rf_events'] if e.get('purpose','regular')=='regular'])
        rows.append(s)
pairs=[]
for clip,repeat in sorted({(r['clip'],r['repeat']) for r in rows}):
    arms={r['experimentArm']:r for r in rows if r['clip']==clip and r['repeat']==repeat}
    if len(arms)!=2:continue
    a,b=arms['baseline'],arms['reserved'];aa,bb=a['acceptedLabels'],b['acceptedLabels']
    pairs.append(dict(clip=clip,repeat=repeat,
        legal=[a['acceptedValid'],b['acceptedValid']],false=[a['knownFalse'],b['knownFalse']],
        unmatched=[a['unmatchedNeedingReview'],b['unmatchedNeedingReview']],
        gainedSeconds=sorted(bb[k] for k in bb.keys()-aa.keys()),lostSeconds=sorted(aa[k] for k in aa.keys()-bb.keys()),
        reservedSubmitted=b['reservedSubmitted'],reservedUsed=b['reservedUsed'],reservedExpired=b['reservedExpired'],
        sameRegularSourceTimes=a['regularSourceTimes']==b['regularSourceTimes']))
(BASE/'summary.json').write_text(json.dumps(dict(scope='iPhone17, body revision2, original paced footage',
    completedRuns=len(rows),pairs=pairs,runs=rows),indent=2)+'\n')
for pair in pairs:print(pair)
print('Completed runs:',len(rows))
