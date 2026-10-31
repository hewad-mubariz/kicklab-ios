#!/usr/bin/env python3
"""Rerun fresh contact evidence against fixed, digest-checked low.mov inputs."""
import hashlib, importlib.util, json, plistlib, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('study',ROOT/'scripts/run-vision-revision-study.py')
study=importlib.util.module_from_spec(spec);spec.loader.exec_module(study)
BASE=ROOT/'artifacts/vision-revisions-20261030/low-contact-robustness-iphone17/frozen-build2026103017'
SOURCE=ROOT/'artifacts/vision-revisions-20261030/ground-impact-iphone17/build2026103015'
NAME='RFValidation-low-robustness-frozen-2026103017'


def main():
    BASE.mkdir(parents=True,exist_ok=True)
    assert not (BASE/'complete.json').exists(), 'Preserve completed evidence'
    device=study.Device('iphone17')
    clip=next(c for c in json.loads((study.OUT/'corpus-inventory.json').read_text())['clips'] if c['id']=='low')
    assert hashlib.file_digest(Path(clip['source']).open('rb'),'sha256').hexdigest()==clip['sha256']
    clips=[]
    for label,arm in [('low-bad','floor'),('low-good','control')]:
        trace=plistlib.load((SOURCE/arm/'iphone17/low-pose2-r2/counter.plist').open('rb'))
        archive=dict(sourceDigest=clip['sha256'],pipelineSignature='Frozen build2026103015 '+arm,
                     mode='capture',timeOriginSeconds=0,trace=trace)
        filename=label+'-robustness-2026103017.plist'
        plistlib.dump(archive,(BASE/filename).open('wb'),fmt=plistlib.FMT_BINARY)
        device.copy('to',BASE/filename,'Documents/RFValidation-vision-study-low/'+filename,60)
        clips.append(dict(id=label,video='source.mov',trace=filename,sourceFolder='RFValidation-vision-study-low'))
    study.dump(BASE/'config.json',dict(comparison='lowRobustness',clips=clips))
    (BASE/'status.txt').write_text('PREPARED')
    # Stage configuration only; the originals already exist on the phone.
    staging=BASE/'staging';staging.mkdir(exist_ok=True)
    for name in ['config.json','status.txt']:(staging/name).write_bytes((BASE/name).read_bytes())
    device.copy('to',staging,'Documents/'+NAME)
    flags=study.FLAGS+['--vision-body-pose-revision2']
    device.command(['process','launch','--device',device.id,'--terminate-existing','--timeout','25','--',
        study.BUNDLE,*flags,'--touch-contact-replay',NAME],40)
    started=time.monotonic();last=''
    while time.monotonic()-started<600:
        time.sleep(5);device.copy('from','Documents/'+NAME+'/status.txt',BASE/'status.txt')
        status=(BASE/'status.txt').read_text()
        if status!=last:print(status,flush=True);last=status
        if status=='DONE':break
        if status.startswith('FAILED'):raise RuntimeError(status)
    assert (BASE/'status.txt').read_text()=='DONE'
    device.copy('from','Documents/touch-counter-profile.json',BASE/'profile.json')
    profile=json.loads((BASE/'profile.json').read_text())
    assert profile['build']=='2026103017'
    assert profile['visionRevisions']['bodyPoseImplementation']=='Swift revision2'
    assert not profile['visionRevisions']['directedForefoot'] and not profile['visionRevisions']['observedUnarmedTurn']
    pairs=[]
    for clip in clips:
        for arm in ['before','after']:
            for suffix in ['.plist','-recovery.json','-rechecks.json','-evidence.json','-ground.json']:
                name=clip['id']+'-'+arm+suffix
                device.copy('from','Documents/'+NAME+'/'+name,BASE/name,60)
        a,b=[plistlib.load((BASE/(clip['id']+'-'+arm+'.plist')).open('rb')) for arm in ['before','after']]
        original=plistlib.load((BASE/clip['trace']).open('rb'))['trace']
        assert a['operations']==b['operations']==original['operations']
        assert a['complete'] and b['complete']
        ca,cb=[t['config'].copy() for t in [a,b]]
        for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:
            assert ca.pop(key)==False and cb.pop(key)==True
        assert ca==cb
        row=dict(clip=clip['id'],before=len(a['touches']),after=len(b['touches']),
                 beforeMs=[t['timestampMs'] for t in a['touches']],afterMs=[t['timestampMs'] for t in b['touches']],
                 originalInputOperationsEqual=True)
        pairs.append(row);print(row['clip'],row['before'],'->',row['after'],flush=True)
    study.dump(BASE/'complete.json',dict(build='2026103017',pairs=pairs))


if __name__=='__main__':main()
