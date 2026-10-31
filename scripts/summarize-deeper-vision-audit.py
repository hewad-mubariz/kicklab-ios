#!/usr/bin/env python3
"""Summarize build14 compute device and per-check pose demand measurements."""
import collections,json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/deeper-compute-20261029'
def read(p):return json.loads(p.read_text())
def distribution(xs):
 s=sorted(xs)
 return {'n':len(s),'meanMS':statistics.mean(s) if s else None,'medianMS':statistics.median(s) if s else None,
         'p95MS':s[min(len(s)-1,int(.95*len(s)))] if s else None,'maximumMS':max(s) if s else None}
result={'build':'2026102914','scope':'Selected fixed-image compute test and two-clip live-pipeline diagnostic. No counter-rule change; not release qualification. Devices use their own RF profiles and different OS versions.','compute':[],'live':[]}
for device in ['iphone11','iphone17']:
 folder=BASE/device/'compute'
 if (folder/'complete.json').exists():
  info=read(folder/'compute-devices.json');rows=read(folder/'compute-results.json')['rows'];groups=collections.defaultdict(list)
  for row in rows:groups[row['arm']].append(row)
  timing=[]
  for arm,rr in sorted(groups.items()):
   timing.append({'arm':arm,**distribution([r['milliseconds'] for r in rr]),'empty':sum(not r['poses'] for r in rr),'thermalStates':sorted({r['thermal'] for r in rr})})
  auto={(r['image'],r['repeat']):r for r in groups['revision2-automatic']}
  forced=groups['revision2-neuralEngine']
  result['compute'].append({'device':device,'hardware':info['hardware'],'os':info['os'],'devices':info['arms'],
   'timings':timing,'exactAutomaticVsForcedBodyOutputs':sum(r['poses']==auto[(r['image'],r['repeat'])]['poses'] for r in forced),'pairedBodyOutputs':len(forced),
   'failures':read(folder/'compute-failures.json')['failures']})
 for folder in sorted((BASE/device).glob('clip-*')):
  if not (folder/'complete.json').exists() and not (folder/'failed.json').exists():continue
  meta=read(folder/'run.json');status=read(folder/'status.json');p=read(folder/'profile.json')
  entry={'device':device,'run':folder.name,'arm':meta['arm'],'sourceSHA256':meta['sourceSHA256'],'state':status['state'],
    'thermal':status.get('thermal'),'error':status.get('error'),'poseTiming':status['poseTiming'],
    'modelBody':p['visionRevisions']['bodyPoseImplementation'],'requestedDevice':p['visionRevisions'].get('bodyPoseRequestedCompute')}
  if (folder/'summary.json').exists():
   summary=read(folder/'summary.json');report=read(folder/'report.json')
   entry.update({k:summary.get(k) for k in ['count','acceptedValid','labelledValid','knownFalse','missedLegalSeconds','knownFalseSeconds','lateSourceSkips','latencyMedianMs','latencyP95Ms','worstThermal']})
   entry.update({'queue':report['counter'],'modelFunction':report['function'],'ballBackend':report['backend'],'sourceSeconds':summary['sourceSeconds'],
     'poseCallsPerSourceSecond':status['poseTiming']['calls']/summary['sourceSeconds'],'exactTraceReplay':status['trace_replay_exact']})
  if (folder/'pose-workload.json').exists():
   audit=read(folder/'pose-workload.json');rr=audit['rows'];body=[r for r in rr if r['kind']=='body'];miss=[r for r in body if not r['cached']]
   assert len(miss)==status['poseTiming']['calls'],(folder,len(miss),status['poseTiming']['calls'])
   by=collections.defaultdict(list)
   for r in rr:by['/'.join(r['scope']) or 'unattributed'].append(r)
   scopes=[]
   for scope,rows in sorted(by.items()):
    calls=[r for r in rows if r['kind']=='body' and not r['cached']]
    scopes.append({'scope':scope,'bodyNewCalls':len(calls),'bodyCacheHits':sum(r['kind']=='body' and r['cached'] for r in rows),
      'bodyMilliseconds':sum(r['elapsedMS'] for r in calls),'handCalls':sum(r['kind']=='hand' for r in rows),
      'handMilliseconds':sum(r['elapsedMS'] for r in rows if r['kind']=='hand')})
   demands=collections.defaultdict(set)
   for row in body:demands[row['frame']].add(row['scope'][-1] if row['scope'] else 'unattributed')
   exclusive=collections.Counter(next(iter(roles)) for roles in demands.values() if len(roles)==1)
   entry['exclusiveFrameDemandByCheck']=dict(exclusive)
   entry['workload']={'bodyLookups':len(body),'bodyCalls':len(miss),'bodyCacheHits':len(body)-len(miss),
     'bodyCacheHitFraction':(len(body)-len(miss))/len(body) if body else None,
     'uniqueInferredFrames':len({r['frame'] for r in miss}),'bodyLatency':distribution([r['elapsedMS'] for r in miss]),
     'handLatency':distribution([r['elapsedMS'] for r in rr if r['kind']=='hand']),
     'droppedAuditRows':audit['droppedRows'],'byScope':scopes}
  result['live'].append(entry)
result['warmup']=[]
for folder in sorted(BASE.glob('warmup-build*/iphone*/clip-*')):
 if not (folder/'complete.json').exists() and not (folder/'failed.json').exists():continue
 meta=read(folder/'run.json');status=read(folder/'status.json');audit=read(folder/'pose-workload.json')
 rows=[r for r in audit['rows'] if r['kind']=='body' and not r['cached']]
 assert len(rows)==status['poseTiming']['calls']
 entry={'device':meta['device'],'run':folder.name,'build':meta['build'],'clip':meta['clip'],
  'personWarmup':'--pose-warmup-image' in meta['flags'],'state':status['state'],'error':status.get('error'),
  'warmup':status.get('poseWarmup'),'poseTiming':status['poseTiming'],'thermal':status['thermal'],
  'bodyLatency':distribution([r['elapsedMS'] for r in rows]),'firstRequestMS':rows[0]['elapsedMS'] if rows else None,
  'afterFirstLatency':distribution([r['elapsedMS'] for r in rows[1:]])}
 if (folder/'summary.json').exists():
  summary=read(folder/'summary.json');report=read(folder/'report.json')
  entry.update({k:summary.get(k) for k in ['count','acceptedValid','knownFalse','missedLegalSeconds','knownFalseSeconds','lateSourceSkips','worstThermal']})
  entry['queue']=report['counter'];entry['exactTraceReplay']=status['trace_replay_exact']
 result['warmup'].append(entry)
result['interpretationLimits']=[
 'Ground first-request attribution is not removable cost: other checks request most of those same frames. Exclusive-frame demand is descriptive, not permission to discard ground evidence.',
 'Matched-image automatic/explicit outputs were identical, but full-pipeline repeated counts vary with scheduling and evidence. This is not a nonregression certification.',
 'The person warmup is an explicitly staged image experiment, not a shipped preview warmup implementation. No warmup pixels enter the contact cache or counter.',
 'iPhone11 and17 use different RF resolutions and OS versions. Fixed-image tests isolate RF workload, not OS differences. Revision2 compute main stage lists only neuralEngine; this does not trace all preprocessing hardware.'
]
BASE.joinpath('summary.json').write_text(json.dumps(result,indent=2)+'\n')
for r in result['compute']:
 print(r['device'],'FIXED',[(t['arm'],round(t['meanMS'],2)) for t in r['timings']])
for r in result['live']:
 w=r.get('workload',{});print(r['device'],r['run'],r['state'],'count',r.get('count'),'legal',r.get('acceptedValid'),'false',r.get('knownFalse'),
  'poseMean',round(r['poseTiming']['totalMS']/max(1,r['poseTiming']['calls']),2),'calls',w.get('bodyCalls'),'hits',w.get('bodyCacheHits'),'thermal',r.get('thermal'))
