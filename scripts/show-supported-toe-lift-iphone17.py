#!/usr/bin/env python3
"""Display the exact verified target run with its matching experimental profile."""
import importlib.util,json,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('runner',ROOT/'scripts/run-supported-toe-lift-iphone17.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
study=runner.study;BASE=runner.BASE
def main():
    source=BASE/'supported/iphone17/clip-e842657024ae-pose2-r2'
    assert (source/'complete.json').exists()
    summary=json.loads((source/'summary.json').read_text())
    assert any(abs(t-8.003)<.08 for t in summary['countTimes']), 'Target recovery not present'
    folder='RFValidation-vision-study-clip-e842657024ae';d=study.Device('iphone17')
    for name in ['counter.plist','touches.json','track.plist','config.json','status.json']:
        d.copy('to',source/name,'Documents/'+folder+'/'+name)
    out=BASE/'review';out.mkdir(exist_ok=True)
    token='--supported-toe-review-'+uuid.uuid4().hex
    study.dump(out/'marker.json',{'state':'pending','token':token})
    d.copy('to',out/'marker.json','Documents/'+folder+'/review-state.json')
    flags=study.FLAGS+runner.low.COMMON+runner.low.ARMS['both']+['--supported-toe-lift-v1']
    d.command(['process','launch','--device',d.id,'--terminate-existing','--timeout','25','--',
        study.BUNDLE,*flags,token,'--session-design','effects','--rf-full-app-review',folder,
        '--touch-debug-hold','0','-debug.touchOutlines','YES'],40)
    for _ in range(20):
        time.sleep(1)
        d.copy('from','Documents/touch-counter-profile.json',out/'profile.json')
        d.copy('from','Documents/'+folder+'/review-state.json',out/'state.json')
        p=json.loads((out/'profile.json').read_text());s=json.loads((out/'state.json').read_text())
        if s.get('state')=='ready' and token in p['explicitLaunchFlags']:break
    assert p['build']=='2026103021' and p['visionRevisions']['bodyPoseImplementation']=='Swift revision2'
    assert p['visionRevisions']['supportedToeLift']
    assert not p['visionRevisions']['failedRetryClock'] and not p['visionRevisions']['independentRegularClock']
    assert s['state']=='ready' and s['touches']==summary['count'] and s['position']==0 and s['outlines']
    study.dump(out/'verified.json',dict(build=p['build'],sourceRun=str(source),state=s,
        profile=p['visionRevisions'],freshReviewWriteVerified=True))
    print('RECOVERY_REVIEW_READY',s,flush=True)
if __name__=='__main__':main()
