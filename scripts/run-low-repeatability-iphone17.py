#!/usr/bin/env python3
"""Order-balanced paced repeats; the only arm difference is the two low-kick opt-ins."""
import argparse, importlib.util, json, plistlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('low',ROOT/'scripts/run-low-contact-robustness-iphone17.py')
low=importlib.util.module_from_spec(spec);spec.loader.exec_module(low)
audit=low.audit
BASE=ROOT/'artifacts/vision-revisions-20261030/low-repeatability-iphone17'

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase',choices=['short','low'],required=True)
    args=parser.parse_args()
    audit.study.BUILD='2026103017'
    device=audit.study.Device('iphone17')
    plan=[]
    for repeat in range(1,4 if args.phase=='short' else 3):
        clips=['clip-a16380ba4a5b','raw-juggling'] if args.phase=='short' else ['low']
        if repeat%2==0: clips.reverse()
        arms=['control','both'] if repeat%2 else ['both','control']
        for clip in clips:
            for arm in arms: plan.append(dict(clip=clip,arm=arm,repeat=repeat))
    BASE.mkdir(parents=True,exist_ok=True)
    audit.study.dump(BASE/(args.phase+'-plan.json'),plan)
    for item in plan:
        arm=item['arm'];audit.BASE=BASE/arm
        audit.study.ARMS['pose2']=low.COMMON+low.ARMS[arm]
        audit.live(device,item['clip'],'pose2',item['repeat'],audit=True)
        out=audit.BASE/'iphone17'/f"{item['clip']}-pose2-r{item['repeat']}"
        assert (out/'complete.json').exists(), 'Incomplete run is not an accuracy result'
        profile=audit.read(out/'profile.json');v=profile['visionRevisions']
        assert v['bodyPoseImplementation']=='Swift revision2'
        assert v['recentMeasuredFloor'] and v['sourceCadenceVersion']==0 and not v['contactWindowClock']
        assert v['directedForefoot']==(arm=='both') and v['observedUnarmedTurn']==(arm=='both')
        trace=plistlib.load((out/'counter.plist').open('rb'))
        for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:
            assert (trace['config'].get(key)==True)==(arm=='both')
    print('PHASE_COMPLETE',args.phase,flush=True)

if __name__=='__main__':main()
