#!/usr/bin/env python3
"""Resumable fresh-Vision phone comparisons; never changes the ordinary launch default.

Pass --execute to run. Without it, print the exact planned runs. Source videos
are staged once per clip. Results are immutable per build, source hash and arm.
"""
import argparse, hashlib, importlib.util, json, os, plistlib, re, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'artifacts/vision-revisions-20261029'
BUNDLE = 'com.juggledude.touchcounting.debug'
BUILD = '2026102911'
DEVICES = {'iphone11':'00008030-000A58D41AA1802E','iphone17':'00008150-00063D221A87401C'}
ARMS = {'control':[], 'pose2':['--vision-body-pose-revision2'], 'tracking2':['--follow-vision-revision2']}
FLAGS = re.findall(r'"(--[a-z0-9-]+)"', (ROOT/'kicklab/Counting/TouchCountingBetaProfile.swift').read_text())
assert len(FLAGS) == 24 and len(set(FLAGS)) == 24

def dump(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(json.dumps(value,indent=2)+'\n');temp.replace(path)

class Device:
    def __init__(self, name): self.name=name;self.id=DEVICES[name]
    def command(self, args, timeout=40):
        r=subprocess.run(['xcrun','devicectl','device']+args,capture_output=True,text=True,timeout=timeout)
        if r.returncode: raise RuntimeError(r.stdout[-2000:]+'\n'+r.stderr[-2000:])
        return r
    def copy(self, direction, source, destination, timeout=30):
        return self.command(['copy',direction,'--device',self.id,'--domain-type','appDataContainer',
            '--domain-identifier',BUNDLE,'--source',str(source),'--destination',str(destination),
            '--timeout',str(timeout),'--quiet'],timeout+5)
    def launch(self, folder, flags=()):
        self.command(['process','launch','--device',self.id,'--terminate-existing','--timeout','20','--',
            BUNDLE,*flags,'--rf-full-app-check',folder],30)
    def poll(self, folder, target, timeout):
        start=time.monotonic();last_progress=0
        while True:
            time.sleep(5)
            self.copy('from',f'Documents/{folder}/status.json',target,15)
            try:
                status=json.loads(target.read_text())
            except json.JSONDecodeError:
                # A copy can overlap the app replacing its progress file.
                # Retry only within the original deadline; an empty file is
                # neither a completed run nor an accuracy result.
                if time.monotonic()-start>timeout:
                    raise TimeoutError(f'{folder}: status stayed unreadable')
                continue
            if status['state']=='completed': return status
            if status['state']=='failed': raise RuntimeError(str(status))
            elapsed=time.monotonic()-start
            if elapsed>timeout: raise TimeoutError(f'{folder}: no completed result after {elapsed:.0f}s; {status}')
            if elapsed-last_progress>30:
                print('PROGRESS',folder,round(elapsed),'seconds',status['state'],flush=True);last_progress=elapsed
    def cool(self):
        local=OUT/self.name/'cooldown';local.mkdir(parents=True,exist_ok=True)
        name='RFValidation-vision-study-cooldown'
        dump(local/'config.json',{'mode':'cooldown','seconds':300})
        dump(local/'status.json',{'state':'prepared'})
        self.copy('to',local,'Documents/'+name)
        self.launch(name)
        status=self.poll(name,local/'status.json',330)
        if status['thermal']>1: raise RuntimeError('Phone remains above fair thermal state; pause study.')
        return status

def validate_revision(value, arm):
    assert value['objectTrackingSelected']==(2 if arm=='tracking2' else 1),value
    assert value['bodyPoseImplementation']==('Swift revision2' if arm=='pose2' else 'VN legacy'),value
    assert value['integratedHandDetection'] is False,value

def percentile(xs, p):
    return sorted(xs)[round((len(xs)-1)*p)] if xs else None

def summarize(folder,clip,arm):
    status=json.loads((folder/'status.json').read_text())
    report=json.loads((folder/'report.json').read_text())
    trace=plistlib.load((folder/'counter.plist').open('rb'))
    # Codable omits the optional diagnostic array when no candidate was emitted.
    trace.setdefault('diagnostics',[])
    exported=json.loads((folder/'touches.json').read_text())
    assert status['trace_replay_exact'] and trace['complete']
    assert status['count']==report['count']==len(trace['touches'])==len(exported)
    assert not report['quality_failed'],report.get('errors')
    assert status['last_source_seconds'] >= clip['duration']-.1
    validate_revision(status['visionRevisions'],arm)
    samples=report.get('samples',[])
    thermal=[s['thermal'] for s in samples if 'thermal' in s]+[status['thermal']]
    memory=[s['memory_mib'] for s in samples if 'memory_mib' in s]+[status['memory_mib']]
    latency=[s['latency_ms'] for s in samples if 'latency_ms' in s]
    summary={'clip':clip['id'],'sourceSHA256':clip['sha256'],'build':BUILD,'arm':arm,
        'count':status['count'],'countTimes':[t['timestampMs']/1000 for t in trace['touches']],
        'sourceSeconds':status['last_source_seconds'],'lateSourceSkips':status['late_source_skips'],
        'worstThermal':max(thermal),'peakSampledMemoryMiB':max(memory),
        'latencyMedianMs':percentile(latency,.5),'latencyP95Ms':percentile(latency,.95),
        'errors':report.get('errors'),'pipeline':report['pipeline'],'worker':report['worker'],
        'referenceCoverage':clip['referenceCoverage'],
        'hardwareModel':report.get('hardware_model'),'modelFunction':report.get('function'),
        'resolution':report.get('resolution'),
        'runtimeVersion':next((p for p in report['pipeline'].split('|') if p.startswith('Version ')),None),
        'admittedFrames':status['admitted_frames'],'poseTiming':status.get('poseTiming'),
        'validForAccuracy':status['admitted_frames']>0}
    if not summary['validForAccuracy']:
        summary['invalidReason']='Every source frame was late; no frames reached the counter. Zero count is not an accuracy result.'
    label_file=Path(clip['labelFile']) if clip['labelFile'] else OUT/'supplemental-labels'/(clip['id']+'.json')
    if label_file.exists() and summary['validForAccuracy']:
        spec=importlib.util.spec_from_file_location('corpus_score',ROOT/'benchmarks/touch-counting/corpus-20261014/score.py')
        score=importlib.util.module_from_spec(spec);spec.loader.exec_module(score)
        label=json.loads(label_file.read_text());assert label['source_sha256']==clip['sha256']
        scored=score.score(label,trace);dump(folder/'label-score.json',scored)
        summary['labelledValid']=scored['labelled_valid'];summary['acceptedValid']=scored['accepted_valid']
        summary['missedValid']=len(scored['missed_valid']);summary['knownFalse']=len(scored['false_accepted'])
        summary['unmatchedNeedingReview']=len(scored['unmatched_needing_review'])
        summary['referenceFile']=str(label_file)
        summary['missedLegalSeconds']=[e['time_s'] for e in scored['missed_valid']]
        summary['knownFalseSeconds']=[e['counter_time_s'] for e in scored['false_accepted']]
    dump(folder/'summary.json',summary)
    return summary

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--device',choices=DEVICES,default='iphone11')
    p.add_argument('--arms',nargs='+',choices=ARMS,default=list(ARMS))
    p.add_argument('--clips',nargs='+',help='Exact inventory IDs. Omit for all inventoried sources.')
    p.add_argument('--repeat',type=int,default=1)
    p.add_argument('--execute',action='store_true')
    args=p.parse_args();device=Device(args.device)
    inventory=json.loads((OUT/'corpus-inventory.json').read_text())
    by_id={c['id']:c for c in inventory['clips']}
    clips=[by_id[c] for c in args.clips] if args.clips else inventory['clips']
    total=sum(c['duration'] for c in clips)*len(args.arms)
    print(f'{len(clips)} clips x {len(args.arms)} arms, {total/60:.1f} minutes of paced footage, plus staging/cooldown.',flush=True)
    if not args.execute:
        print(json.dumps({'device':args.device,'clips':[c['id'] for c in clips],'arms':args.arms,'fixedFlags':FLAGS},indent=2));return
    for clip in clips:
        pending=[]
        # Rotate arm order across the corpus to limit systematic warm/late order effects.
        offset=(inventory['clips'].index(clip)+args.repeat-1)%len(args.arms)
        arms=args.arms[offset:]+args.arms[:offset]
        for arm in arms:
            folder=OUT/f'{args.device}-build{BUILD}'/f"{clip['id']}-{arm}-r{args.repeat}"
            if not (folder/'complete.json').exists() and all((folder/f).exists() for f in ['run.json','profile.json','status.json','report.json','counter.plist','touches.json','track.plist','report-id.txt']):
                metadata=json.loads((folder/'run.json').read_text())
                assert metadata['build']==BUILD and metadata['sourceSHA256']==clip['sha256']
                summary=summarize(folder,clip,arm)
                dump(folder/'complete.json',metadata|{'reportID':(folder/'report-id.txt').read_text().strip()})
                print('RECOVERED_SAVED_RESULT',json.dumps(summary),flush=True)
            if (folder/'complete.json').exists():
                completed=json.loads((folder/'complete.json').read_text())
                assert completed['build']==BUILD and completed['sourceSHA256']==clip['sha256']
                print('RESUME_SKIP',folder.name,flush=True)
            else:pending.append((arm,folder))
        if not pending:continue
        source=Path(clip['source']);h=hashlib.sha256()
        with source.open('rb') as f:
            for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
        assert h.hexdigest()==clip['sha256'],f'Source changed: {source}'
        staging=OUT/'staging'/clip['id'];staging.mkdir(parents=True,exist_ok=True)
        staged=staging/'source.mov'
        if not staged.exists():os.link(source,staged)
        name='RFValidation-vision-study-'+clip['id']
        print('STAGING',clip['id'],flush=True)
        device.copy('to',staging,'Documents/'+name,240)
        for arm,folder in pending:
            folder.mkdir(parents=True,exist_ok=True)
            dump(folder/'cooldown-status.json',device.cool())
            token='--vision-study-run-'+uuid.uuid4().hex
            metadata={'clip':clip['id'],'sourceSHA256':clip['sha256'],'build':BUILD,'arm':arm,
                'device':args.device,'token':token,'flags':FLAGS+ARMS[arm]}
            dump(folder/'run.json',metadata)
            dump(folder/'config.json',{'mode':'paced','source':'source.mov','seconds':clip['duration']})
            dump(folder/'status.json',{'state':'prepared','token':token})
            for f in ['config.json','status.json']:device.copy('to',folder/f,'Documents/'+name+'/'+f)
            device.launch(name,FLAGS+ARMS[arm]+[token])
            # Foreground launch can return before SwiftUI writes the profile.
            for _ in range(10):
                time.sleep(1);device.copy('from','Documents/touch-counter-profile.json',folder/'profile.json')
                profile=json.loads((folder/'profile.json').read_text())
                if token in profile['explicitLaunchFlags']:break
            assert token in profile['explicitLaunchFlags'],'Stale launch profile'
            assert profile['build']==BUILD,profile
            assert set(FLAGS).issubset(profile['effectiveFlags']),profile
            validate_revision(profile['visionRevisions'],arm)
            print('START',folder.name,flush=True)
            device.poll(name,folder/'status.json',clip['duration']+120)
            for f in ['counter.plist','touches.json','track.plist']:device.copy('from','Documents/'+name+'/'+f,folder/f,60)
            device.copy('from','Documents/RFFullApp/latest.txt',folder/'report-id.txt')
            report_id=(folder/'report-id.txt').read_text().strip();assert str(uuid.UUID(report_id))==report_id.lower()
            device.copy('from','Documents/RFFullApp/'+report_id+'/report.json',folder/'report.json',60)
            result=summarize(folder,clip,arm)
            dump(folder/'complete.json',metadata|{'reportID':report_id})
            print('DONE',json.dumps(result),flush=True)
            if result['worstThermal']>1:raise RuntimeError('Run exceeded nominal/fair; preserve evidence and pause for cooling/review.')
    print('ALL_REQUESTED_RUNS_COMPLETE',flush=True)

if __name__=='__main__': main()
