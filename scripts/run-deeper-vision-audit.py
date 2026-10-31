#!/usr/bin/env python3
"""Explicit build14 compute/pose-demand experiment; no defaults or releases change."""
import argparse, hashlib, importlib.util, json, os, time, uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('study',ROOT/'scripts/run-vision-revision-study.py')
study=importlib.util.module_from_spec(spec);spec.loader.exec_module(study)
study.BUILD='2026102914'
BASE=study.OUT/'deeper-compute-20261029'
WARM_PERSON=False
def read(p):return json.loads(p.read_text())
def verify(d,out,token):
    for _ in range(15):
        time.sleep(1);d.copy('from','Documents/touch-counter-profile.json',out/'profile.json')
        p=read(out/'profile.json')
        if token in p['explicitLaunchFlags']:break
    assert p['build']==study.BUILD and token in p['explicitLaunchFlags'],p
    assert set(study.FLAGS).issubset(p['effectiveFlags']),p
    return p

def compute(d):
    name='RFValidation-pose-compute-build14';out=BASE/d.name/'compute';out.mkdir(parents=True,exist_ok=True)
    if (out/'complete.json').exists(): print('ALREADY_COMPLETE',out,flush=True);return
    d.copy('to',BASE/'staging'/name,'Documents/'+name,240)
    token='--compute-audit-'+uuid.uuid4().hex
    d.launch(name,study.FLAGS+[token]);verify(d,out,token)
    print('COMPUTE_STARTED',d.name,flush=True)
    try:d.poll(name,out/'status.json',480)
    finally:
        for f in ['compute-devices.json','compute-results.json','compute-failures.json']:
            try:d.copy('from','Documents/'+name+'/'+f,out/f,30)
            except Exception as e:print('COPY_FAILED',f,str(e)[:180],flush=True)
    study.dump(out/'complete.json',{'build':study.BUILD,'device':d.name})
    print('COMPUTE_DONE',d.name,read(out/'status.json'),flush=True)

def cool(d, out):
    # These comparative runs permit nominal or fair, never serious/critical.
    # Prefer nominal after a short idle; do not turn a stable fair device into
    # repeated five-minute waits. Preserve each actual start/end thermal state.
    name='RFValidation-pose-audit-cooldown'
    local=BASE/d.name/'cooldown';local.mkdir(parents=True,exist_ok=True)
    study.dump(local/'config.json',{'mode':'cooldown','seconds':30})
    study.dump(local/'status.json',{'state':'prepared'})
    d.copy('to',local,'Documents/'+name)
    d.launch(name)
    return d.poll(name,out/'cooldown-status.json',90)

def live(d,clip_id,arm,repeat,audit=True):
    clip=next(x for x in read(study.OUT/'corpus-inventory.json')['clips'] if x['id']==clip_id)
    base_arm='pose2' if arm.startswith('pose2') else 'control'
    out=BASE/d.name/(f'{clip_id}-{arm}-r{repeat}'+('-person-warm' if WARM_PERSON else ''))
    out.mkdir(parents=True,exist_ok=True)
    if (out/'complete.json').exists():print('ALREADY_COMPLETE',out,flush=True);return
    source=Path(clip['source']);assert hashlib.file_digest(source.open('rb'),'sha256').hexdigest()==clip['sha256']
    name='RFValidation-vision-study-'+clip_id
    # Sources already staged during earlier studies; a bounded file-list call checks presence.
    try:
        d.command(['info','files','--device',d.id,'--domain-type','appDataContainer','--domain-identifier',study.BUNDLE,
          '--subdirectory','Documents/'+name,'--no-recurse','--json-output',str(out/'device-files.json'),'--timeout','20','--quiet'],30)
        assert any(f['name']=='source.mov' and f['metadata']['size']==source.stat().st_size for f in read(out/'device-files.json')['result']['files'])
    except Exception:
        staging=BASE/'staging'/clip_id;staging.mkdir(parents=True,exist_ok=True)
        if not (staging/'source.mov').exists():os.link(source,staging/'source.mov')
        d.copy('to',staging,'Documents/'+name,240)
    cool_status=cool(d,out)
    if cool_status['thermal']>1:raise RuntimeError('Device not nominal/fair')
    flags=study.FLAGS+study.ARMS[base_arm]+(['--pose-workload-audit'] if audit else [])
    if '-' in arm:flags+=['--vision-pose-compute',arm.split('-',1)[1]]
    if WARM_PERSON:flags+=['--pose-warmup-image','RFValidation-pose-compute-build14/normal_juggling_4-11880.png']
    token='--workload-audit-'+uuid.uuid4().hex
    study.dump(out/'run.json',{'build':study.BUILD,'sourceSHA256':clip['sha256'],'clip':clip_id,'arm':arm,'device':d.name,'repeat':repeat,'flags':flags,'token':token})
    study.dump(out/'config.json',{'mode':'paced','source':'source.mov','seconds':clip['duration']})
    study.dump(out/'status.json',{'state':'prepared','token':token})
    for f in ['config.json','status.json']:d.copy('to',out/f,'Documents/'+name+'/'+f)
    d.launch(name,flags+[token]);p=verify(d,out,token);study.validate_revision(p['visionRevisions'],base_arm)
    print('LIVE_STARTED',d.name,clip_id,arm,repeat,flush=True)
    try:d.poll(name,out/'status.json',clip['duration']+120)
    except RuntimeError as e:
        if read(out/'status.json').get('state')!='failed':raise
        study.dump(out/'failed.json',{'error':str(e),'validForAccuracy':False})
        print('LIVE_FAILED',d.name,clip_id,arm,read(out/'status.json'),flush=True)
        return
    finally:
        if audit:d.copy('from','Documents/'+name+'/pose-workload.json',out/'pose-workload.json',30)
    for f in ['counter.plist','touches.json','track.plist']:d.copy('from','Documents/'+name+'/'+f,out/f,60)
    d.copy('from','Documents/RFFullApp/latest.txt',out/'report-id.txt')
    report_id=(out/'report-id.txt').read_text().strip();uuid.UUID(report_id)
    d.copy('from','Documents/RFFullApp/'+report_id+'/report.json',out/'report.json',60)
    s=study.summarize(out,clip,base_arm);s['arm']=arm;s['auditEnabled']=audit;study.dump(out/'summary.json',s)
    study.dump(out/'complete.json',{'build':study.BUILD,'reportID':report_id,'device':d.name,'arm':arm})
    print('LIVE_DONE',d.name,clip_id,arm,'count',s['count'],'legal',s.get('acceptedValid','unlabelled'),'false',s.get('knownFalse','unlabelled'),'pose',s['poseTiming'],'skips',s['lateSourceSkips'],'thermal',s['worstThermal'],flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('phase',choices=['compute','live'])
    p.add_argument('--device',required=True,choices=study.DEVICES);p.add_argument('--clips',nargs='+',default=['clip-a16380ba4a5b'])
    p.add_argument('--arms',nargs='+',default=['control','pose2']);p.add_argument('--repeat',type=int,default=1)
    p.add_argument('--no-audit',action='store_true');p.add_argument('--build',default='2026102914');p.add_argument('--warm-person',action='store_true')
    a=p.parse_args();d=study.Device(a.device);study.BUILD=a.build;WARM_PERSON=a.warm_person
    if a.build!='2026102914':BASE=BASE/('warmup-build'+a.build)
    if a.phase=='compute':compute(d)
    else:
        for clip in a.clips:
            for arm in a.arms:live(d,clip,arm,a.repeat,not a.no_audit)
