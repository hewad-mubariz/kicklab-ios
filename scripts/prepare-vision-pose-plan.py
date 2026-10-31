#!/usr/bin/env python3
"""Freeze sources, sampled times and adapter hashes before the Mac pose sweep."""
import hashlib,json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/vision-revisions-20261029'
inventory=json.loads((OUT/'corpus-inventory.json').read_text())
clips=[]
for clip in inventory['clips']:
    samples={}
    def add(t,reason):
        t=round(t,4)
        if 0<=t<=clip['duration']-.05:samples.setdefault(t,[]).append(reason)
    t=0.
    while t<clip['duration']-.05:add(t,'uniform-2s');t+=2
    if clip['labelFile']:
        label=json.loads(Path(clip['labelFile']).read_text())
        assert label['source_sha256']==clip['sha256']
        for event in label['events']:
            for delta in [-.067,0,.067]:add(event['time_s']+delta,f"label:{event['id']}:{event['label']}:{event['contact']}")
    if clip['id']=='clip-a16380ba4a5b':
        for t in [.217,1.533,15.867,18.25,19.65,20.21]:
            for delta in [-.133,-.067,0,.067,.133]:add(t+delta,f'reviewed-contact:{t}')
    clips.append({k:clip[k] for k in ['id','sha256','source','duration']}|
        {'samples':[{'time':t,'reasons':r} for t,r in sorted(samples.items())]})
paths=['scripts/vision-pose-offline-audit.swift','kicklab/Counting/ContactPose.swift','kicklab/Detection/VisionRevisionExperiment.swift']
hashes={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
protocol=hashlib.sha256(json.dumps({'clips':clips,'sources':hashes},sort_keys=True).encode()).hexdigest()
plan={'protocolID':protocol,'sources':hashes,
    'sampling':'Every 2 seconds plus three samples around every original corpus event and six recent IMG8606 windows. Same oriented 512-long-edge pixels; alternating arm order; persistent requests. No touch counter or active-player selection.',
    'clips':clips}
(OUT/'mac-pose-retained-plan.json').write_text(json.dumps(plan,indent=2)+'\n')
print(len(clips),'clips;',sum(len(c['samples']) for c in clips),'requested frame pairs;',protocol)
