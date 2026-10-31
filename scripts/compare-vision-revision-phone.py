#!/usr/bin/env python3
"""Compare paired phone replays using existing event labels and measured runtime data."""
import argparse,json,plistlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/vision-revisions-20261029'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--device',choices=['iphone11','iphone17'],required=True)
args=p.parse_args()
base=OUT/(args.device+'-build2026102911')
clips={c['id']:c for c in json.loads((OUT/'corpus-inventory.json').read_text())['clips']}
runs=[];by_case={}
for complete in sorted(base.glob('*/complete.json')):
    f=complete.parent;meta=json.loads(complete.read_text());s=json.loads((f/'summary.json').read_text())
    repeat=int(f.name.rsplit('-r',1)[1]);status=json.loads((f/'status.json').read_text());report=json.loads((f/'report.json').read_text())
    timing=s.get('poseTiming') or {}
    row={k:s.get(k) for k in ['clip','arm','count','acceptedValid','labelledValid','missedValid','knownFalse',
        'unmatchedNeedingReview','missedLegalSeconds','knownFalseSeconds','lateSourceSkips','worstThermal',
        'peakSampledMemoryMiB','latencyMedianMs','latencyP95Ms','validForAccuracy','sourceSHA256']}
    row.update({'repeat':repeat,'folder':str(f),'hardwareModel':report.get('hardware_model'),
        'modelFunction':report.get('function'),'sourceSeconds':s['sourceSeconds'],
        'runtimeVersion':next((x for x in report['pipeline'].split('|') if x.startswith('Version ')),None),
        'poseCalls':timing.get('calls'),'emptyPoseCalls':timing.get('empty'),
        'poseMeanMS':timing['totalMS']/timing['calls'] if timing.get('calls') else None,
        'poseMaximumMS':timing.get('maximumMS'),'exactTraceReplay':status['trace_replay_exact'],
        'withinNominalOrFair':s['worstThermal']<=1,'errors':report['errors']})
    if (f/'label-score.json').exists():
        score=json.loads((f/'label-score.json').read_text())
        row['matchedLegalByID']={m['label_id']:m['label_time_s'] for m in score['matched']}
        row['missedDetails']=score['missed_valid']
        row['uncertainAccepted']=len(score['uncertain_accepted'])
        row['uncertainSeconds']=[e['counter_time_s'] for e in score['uncertain_accepted']]
    runs.append(row);by_case[(row['clip'],row['arm'],repeat)]=row

pairs=[]
for r in runs:
    if r['arm']=='control':continue
    c=by_case.get((r['clip'],'control',r['repeat']))
    if not c:continue
    old,new=c.get('matchedLegalByID',{}),r.get('matchedLegalByID',{})
    pairs.append({'clip':r['clip'],'arm':r['arm'],'repeat':r['repeat'],
        'sameSource':c['sourceSHA256']==r['sourceSHA256'],'countDelta':r['count']-c['count'],
        'legalCountDelta':r['acceptedValid']-c['acceptedValid'] if r['acceptedValid'] is not None and c['acceptedValid'] is not None else None,
        'gainedLegalSeconds':sorted(new[k] for k in new.keys()-old.keys()),
        'lostLegalSeconds':sorted(old[k] for k in old.keys()-new.keys()),
        'controlFalseSeconds':c['knownFalseSeconds'],'candidateFalseSeconds':r['knownFalseSeconds'],
        'controlSkips':c['lateSourceSkips'],'candidateSkips':r['lateSourceSkips'],
        'bothNominal':c['worstThermal']==r['worstThermal']==0,
        'bothWithinNominalOrFair':c['withinNominalOrFair'] and r['withinNominalOrFair']})

groups=[]
for clip in sorted({r['clip'] for r in runs}):
    for arm in ['control','pose2','tracking2']:
        rr=[r for r in runs if r['clip']==clip and r['arm']==arm]
        if not rr:continue
        def extent(key):
            values=[r[key] for r in rr if r[key] is not None]
            return [min(values),max(values)] if values else None
        consistent_misses=set(rr[0].get('missedLegalSeconds') or [])
        for r in rr[1:]:consistent_misses&=set(r.get('missedLegalSeconds') or [])
        groups.append({'clip':clip,'arm':arm,'repeats':[r['repeat'] for r in rr],
            'countRange':extent('count'),'acceptedLegalRange':extent('acceptedValid'),'knownFalseRange':extent('knownFalse'),
            'poseMeanMSRange':extent('poseMeanMS'),'sourceSkipRange':extent('lateSourceSkips'),
            'worstThermal':max(r['worstThermal'] for r in rr),'missedInEveryRepeat':sorted(consistent_misses)})

result={'device':args.device,'build':'2026102911',
    'scope':'Paced full-pipeline replays of saved development clips, including qualification repeats. Existing single-reviewer labels; not a held-out release accuracy benchmark. Same fixed24 counting flags in every arm. The separate reviewed-corpus summary uses a fixed cohort and one run per arm so pilot repeats do not inflate totals.',
    'completedRuns':len(runs),'uniqueClips':len({r['clip'] for r in runs}),
    'allCompletedNominal':all(r['worstThermal']==0 for r in runs),
    'allTraceReplaysExact':all(r['exactTraceReplay'] for r in runs),
    'allCompletedErrorFree':all(not r['errors'] for r in runs),
    'runs':runs,'pairedComparisons':pairs,'groups':groups}
for dest in [OUT/(args.device+'-comparison.json'),ROOT/'benchmarks/touch-counting/vision-revisions-20261029'/(args.device+'-comparison.json')]:
    dest.write_text(json.dumps(result,indent=2)+'\n')
for g in groups:
    print(g['clip'],g['arm'],'repeats',g['repeats'],'legal',g['acceptedLegalRange'],'false',g['knownFalseRange'],'thermal',g['worstThermal'])
print('Completed:',len(runs),'All nominal:',result['allCompletedNominal'])
