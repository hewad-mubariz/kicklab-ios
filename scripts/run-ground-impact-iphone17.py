#!/usr/bin/env python3
"""Compare the bounded recent-floor proof with all short-kick improvements held fixed."""
import argparse,importlib.util,plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=ROOT/'artifacts/vision-revisions-20261030/ground-impact-iphone17'
COMMON=['--vision-body-pose-revision2','--stationary-gate-motion-v3','--contact-window-audit',
        '--observed-fall-amplitude-v1','--observed-short-rise-v1','--observed-plateau-foot-v1']
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips',nargs='+',required=True)
    p.add_argument('--arms',nargs='+',choices=['control','floor'],default=['control','floor'])
    p.add_argument('--repeat',type=int,default=1)
    p.add_argument('--build',default='2026103015')
    a=p.parse_args();assert a.build in ['2026103014','2026103015']
    audit.study.BUILD=a.build;device=audit.study.Device('iphone17')
    for clip in a.clips:
        for arm in a.arms:
            audit.BASE=BASE/('build'+a.build)/arm
            audit.study.ARMS['pose2']=COMMON+(['--recent-measured-floor-v1'] if arm=='floor' else [])
            audit.live(device,clip,'pose2',a.repeat,audit=True)
            out=audit.BASE/'iphone17'/f'{clip}-pose2-r{a.repeat}'
            assert (out/'complete.json').exists()
            v=audit.read(out/'status.json')['visionRevisions']
            assert v['stationaryGateVersion']==3 and not v['contactWindowClock']
            assert v['observedFallAmplitude'] and v['observedShortRise'] and v['observedPlateauFoot']
            assert v['recentMeasuredFloor']==(arm=='floor')
            assert v['sourceCadenceVersion']==0
            assert not any(v[k] for k in ['poseEmptyLegacyFallback','reservedImpactGap','trackingDrainBudget',
                'compactReleaseWindow','resolvedFloorMargin','sharedPoseHistory','shallowLateralContact'])
            t=plistlib.load((out/'counter.plist').open('rb'))
            assert t['config']['usesObservedFallAmplitude'] and t['config']['recoversObservedShortRise']
            assert t['config']['confirmsObservedPlateauFoot']
            assert (t['config'].get('rejectsReboundNearRecentFloor')==True)==(arm=='floor')
