#!/usr/bin/env python3
"""Restore the previously verified revision2 field app and 24-touch IMG8874 preview."""
import argparse,importlib.util,json,plistlib,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('study',ROOT/'scripts/run-vision-revision-study.py')
study=importlib.util.module_from_spec(spec);spec.loader.exec_module(study)
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--experiment',default='contact-evidence-audit-iphone17')
    parser.add_argument('--output-directory',type=Path)
    args=parser.parse_args()
    base=args.output_directory or study.OUT/args.experiment/'restore';base.mkdir(parents=True,exist_ok=True)
    backup=study.OUT/'shared-history-iphone17'/'restore'
    app=ROOT/'build/vision-integration-probe/Build/Products/TouchCountingDebug-iphoneos/Touch Counting Debug.app'
    assert plistlib.load((app/'Info.plist').open('rb'))['CFBundleVersion']=='2026102913'
    d=study.Device('iphone17')
    d.command(['install','app','--device',d.id,'--timeout','60',str(app)],90)
    folder='Documents/RFValidation-vision-study-clip-618a1688fcc6'
    for f in ['counter.plist','touches.json','track.plist','config.json','status.json']:
        d.copy('to',backup/f,folder+'/'+f)
    marker=base/'marker.json';study.dump(marker,{'state':'restore-verification-pending'})
    d.copy('to',marker,folder+'/review-state.json')
    d.command(['process','launch','--device',d.id,'--terminate-existing','--timeout','25','--',study.BUNDLE,
        '--session-design','effects','--rf-full-app-review','RFValidation-vision-study-clip-618a1688fcc6',
        '--touch-debug-hold','0','-debug.touchOutlines','NO'],40)
    for _ in range(15):
        time.sleep(1)
        d.copy('from','Documents/touch-counter-profile.json',base/'profile.json')
        d.copy('from',folder+'/review-state.json',base/'review.json')
        profile=json.loads((base/'profile.json').read_text());review=json.loads((base/'review.json').read_text())
        if review.get('state')=='ready':break
    assert profile['build']=='2026102913'
    assert profile['visionRevisions']['bodyPoseImplementation']=='Swift revision2'
    assert set(study.FLAGS).issubset(profile['effectiveFlags'])
    assert '--vision-body-pose-revision2' in profile['effectiveFlags']
    assert not any(f.startswith(('--rf-source-cadence','--rf-independent-regular-clock','--rf-failed-retry-clock','--replay-precise-clock','--replay-source-audit','--pose-shared-history','--shallow-lateral-contact','--compact-release-window','--resolved-floor-margin','--rf-reserved-gap','--rf-drain-budget','--pose-input-audit','--pose-empty-legacy-fallback','--stationary-gate-motion','--stationary-gate-audit','--contact-window-clock','--contact-window-audit','--observed-fall-amplitude','--observed-short-rise','--observed-plateau-foot','--recent-measured-floor','--directed-forefoot','--observed-unarmed-turn')) for f in profile['effectiveFlags'])
    assert review['state']=='ready' and review['touches']==24 and review['position']==0 and not review['outlines']
    study.dump(base/'verified.json',{'build':profile['build'],'revision':profile['visionRevisions'],
        'review':review,'experimentalFlagsAbsent':True,'freshReviewWriteVerified':True})
    print('RESTORED',profile['build'],review)
