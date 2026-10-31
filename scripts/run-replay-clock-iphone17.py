#!/usr/bin/env python3
"""Separate file-replay pacing from counter switches using one instrumented build."""
import argparse,importlib.util,plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('low',ROOT/'scripts/run-low-contact-robustness-iphone17.py')
low=importlib.util.module_from_spec(spec);spec.loader.exec_module(low)
audit=low.audit
BASE=ROOT/'artifacts/vision-revisions-20261030/low-repeatability-iphone17/clock-build2026103018'

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--phase',choices=['short','low'],required=True)
    args=p.parse_args();audit.study.BUILD='2026103018';device=audit.study.Device('iphone17')
    plan=[]
    for repeat in range(1,3 if args.phase=='short' else 2):
        clips=['raw-juggling','clip-a16380ba4a5b'] if args.phase=='short' else ['low']
        if repeat==2:clips.reverse()
        arms=['legacy-both','precise-control','precise-both'] if args.phase=='short' else ['precise-control','precise-both']
        if repeat==2:arms.reverse()
        for clip in clips:
            for arm in arms:plan.append(dict(clip=clip,arm=arm,repeat=repeat))
    BASE.mkdir(parents=True,exist_ok=True);audit.study.dump(BASE/(args.phase+'-plan.json'),plan)
    for item in plan:
        arm=item['arm'];precise=arm.startswith('precise');improved=arm.endswith('both')
        audit.BASE=BASE/arm
        out=audit.BASE/'iphone17'/f"{item['clip']}-pose2-r{item['repeat']}"
        if (out/'complete.json').exists() and (out/'source-admission.json').exists():
            print('ALREADY_COMPLETE',out,flush=True);continue
        audit.study.ARMS['pose2']=low.COMMON+['--replay-source-audit']+(low.ARMS['both'] if improved else [])+(['--replay-precise-clock-v1'] if precise else [])
        audit.live(device,item['clip'],'pose2',item['repeat'],audit=True)
        assert (out/'complete.json').exists()
        device.copy('from','Documents/RFValidation-vision-study-'+item['clip']+'/source-admission.json',out/'source-admission.json',60)
        s=audit.read(out/'status.json');log=audit.read(out/'source-admission.json');profile=audit.read(out/'profile.json')
        assert s['replay_precise_clock']==log['precise_clock']==precise
        assert s['replay_source_audit'] and not log['dropped_rows']
        assert sum(not r['admitted'] for r in log['rows'])==s['late_source_skips']
        assert '--replay-source-audit' in profile['explicitLaunchFlags']
        assert ('--replay-precise-clock-v1' in profile['explicitLaunchFlags'])==precise
        t=plistlib.load((out/'counter.plist').open('rb'))
        assert [r['source_frame'] for r in log['rows'] if r['admitted']]==[o['input']['sourceFrameIndex'] for o in t['operations'] if 'input' in o]
        for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:
            assert (t['config'].get(key)==True)==improved
    print('PHASE_COMPLETE',args.phase,flush=True)

if __name__=='__main__':main()
