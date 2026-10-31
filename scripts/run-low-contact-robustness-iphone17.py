#!/usr/bin/env python3
"""Compare isolated low-contact experiments with revision 2 and the verified floor proof."""
import argparse, importlib.util, plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=ROOT/'artifacts/vision-revisions-20261030/low-contact-robustness-iphone17'
COMMON=['--vision-body-pose-revision2','--stationary-gate-motion-v3','--contact-window-audit',
        '--observed-fall-amplitude-v1','--observed-short-rise-v1','--observed-plateau-foot-v1',
        '--recent-measured-floor-v1']
ARMS={'control':[], 'foot':['--directed-forefoot-v1'], 'turn':['--observed-unarmed-turn-v1'],
      'both':['--directed-forefoot-v1','--observed-unarmed-turn-v1']}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips',nargs='+',required=True)
    p.add_argument('--arms',nargs='+',choices=ARMS,default=['control','both'])
    p.add_argument('--repeat',type=int,default=1)
    a=p.parse_args();audit.study.BUILD='2026103016';device=audit.study.Device('iphone17')
    for clip in a.clips:
        for arm in a.arms:
            audit.BASE=BASE/('build'+audit.study.BUILD)/arm
            audit.study.ARMS['pose2']=COMMON+ARMS[arm]
            audit.live(device,clip,'pose2',a.repeat,audit=True)
            out=audit.BASE/'iphone17'/f'{clip}-pose2-r{a.repeat}'
            assert (out/'complete.json').exists()
            v=audit.read(out/'status.json')['visionRevisions']
            assert v['recentMeasuredFloor'] and v['sourceCadenceVersion']==0 and not v['contactWindowClock']
            assert v['directedForefoot']==(arm in ['foot','both'])
            assert v['observedUnarmedTurn']==(arm in ['turn','both'])
            t=plistlib.load((out/'counter.plist').open('rb'))
            assert (t['config'].get('confirmsDirectedForefoot')==True)==(arm in ['foot','both'])
            assert (t['config'].get('recoversObservedUnarmedTurn')==True)==(arm in ['turn','both'])
