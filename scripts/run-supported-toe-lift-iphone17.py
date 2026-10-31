#!/usr/bin/env python3
"""Compare the supported toe proof without changing RF scheduling or pose revision."""
import argparse, hashlib, importlib.util, json, plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('low',ROOT/'scripts/run-low-contact-robustness-iphone17.py')
low=importlib.util.module_from_spec(spec);spec.loader.exec_module(low)
audit=low.audit;study=audit.study
BASE=ROOT/'artifacts/vision-revisions-20261030/supported-toe-lift-iphone17'

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--phase',choices=['target','controls'],required=True)
    p.add_argument('--clips',nargs='+',help='Restrict a repeat to named regression clips.')
    p.add_argument('--repeat',type=int,help='Run one additional repeat; even repeats reverse the order.')
    args=p.parse_args();study.BUILD='2026103021';d=study.Device('iphone17')
    clips=['clip-e842657024ae'] if args.phase=='target' else [
        'clip-89b81fd8bd37','low','clip-a16380ba4a5b','clip-618a1688fcc6','raw-juggling',
        'ball_in_hand','dribbling_with_ball_1','dribbling_with_ball_2',
        'dribbling_with_ball_3','dribbling_with_the_ball_1']
    if args.clips:
        assert all(clip in clips for clip in args.clips)
        clips=args.clips
    plan=[]
    repeats=[args.repeat] if args.repeat else range(1,3 if args.phase=='target' else 2)
    for repeat in repeats:
        for clip in clips:
            for arm in (['control','supported'] if repeat%2 else ['supported','control']):
                plan.append(dict(clip=clip,arm=arm,repeat=repeat))
    study.dump(BASE/(args.phase+(f'-r{args.repeat}' if args.repeat else '')+'-plan.json'),plan)
    for item in plan:
        arm=item['arm'];enabled=arm=='supported';audit.BASE=BASE/arm
        out=audit.BASE/'iphone17'/f"{item['clip']}-pose2-r{item['repeat']}"
        if (out/'complete.json').exists() and (out/'source-admission.json').exists():
            print('ALREADY_COMPLETE',out,flush=True);continue
        study.ARMS['pose2']=low.COMMON+low.ARMS['both']+['--replay-source-audit','--replay-precise-clock-v1']+(['--supported-toe-lift-v1'] if enabled else [])
        audit.live(d,item['clip'],'pose2',item['repeat'],audit=True)
        assert (out/'complete.json').exists(),'Replay incomplete'
        d.copy('from','Documents/RFValidation-vision-study-'+item['clip']+'/source-admission.json',out/'source-admission.json',60)
        profile=audit.read(out/'profile.json');report=audit.read(out/'report.json')
        trace=plistlib.loads((out/'counter.plist').read_bytes());source=audit.read(out/'source-admission.json')
        assert profile['visionRevisions']['supportedToeLift']==enabled
        assert (trace['config'].get('confirmsSupportedToeLift')==True)==enabled
        assert ('|supported-toe-lift-v1'in report['pipeline'])==enabled
        assert not report['failed_retry_clock'] and not report['independent_regular_clock'] and not report['source_cadence_enabled']
        assert report['worker']['model_instances']==report['worker']['maximum_active']==1
        assert source['precise_clock'] and not source['dropped_rows']
        assert [r['source_frame'] for r in source['rows'] if r['admitted']]==[o['input']['sourceFrameIndex'] for o in trace['operations'] if 'input'in o]
        print('PROOF_CHECK',item['clip'],arm,len(trace['touches']),flush=True)
    print('PHASE_COMPLETE',args.phase,flush=True)

if __name__=='__main__':main()
