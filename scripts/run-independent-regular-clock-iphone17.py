#!/usr/bin/env python3
"""Isolate regular/retry wall clocks with unchanged counter rules and precise playback."""
import argparse,importlib.util,plistlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('low',ROOT/'scripts/run-low-contact-robustness-iphone17.py')
low=importlib.util.module_from_spec(spec);spec.loader.exec_module(low)
audit=low.audit
BASE=ROOT/'artifacts/vision-revisions-20261030/independent-regular-clock-iphone17'

def main():
    global BASE
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--phase',choices=['focused','controls'],required=True)
    p.add_argument('--variant',choices=['independent','failed'],default='independent')
    args=p.parse_args();failed=args.variant=='failed'
    audit.study.BUILD='2026103020' if failed else '2026103019';device=audit.study.Device('iphone17')
    if failed:BASE=BASE.with_name('failed-retry-clock-iphone17')
    flag='--rf-failed-retry-clock-v1' if failed else '--rf-independent-regular-clock-v1'
    plan=[]
    for repeat in range(1,3 if args.phase=='focused' else 2):
        clips=['raw-juggling','clip-a16380ba4a5b','low'] if args.phase=='focused' else ['clip-89b81fd8bd37','clip-618a1688fcc6','ball_in_hand','dribbling_with_ball_1','dribbling_with_ball_2','dribbling_with_ball_3','dribbling_with_the_ball_1']
        if repeat%2==0:clips.reverse()
        arms=['control',args.variant] if repeat%2 else [args.variant,'control']
        for clip in clips:
            for arm in arms:plan.append(dict(clip=clip,arm=arm,repeat=repeat))
    audit.study.dump(BASE/(args.phase+'-plan.json'),plan)
    for item in plan:
        arm=item['arm'];enabled=arm==args.variant;audit.BASE=BASE/arm
        out=audit.BASE/'iphone17'/f"{item['clip']}-pose2-r{item['repeat']}"
        if (out/'complete.json').exists() and (out/'source-admission.json').exists():
            print('ALREADY_COMPLETE',out,flush=True);continue
        audit.study.ARMS['pose2']=low.COMMON+low.ARMS['both']+['--replay-source-audit','--replay-precise-clock-v1']+([flag] if enabled else [])
        audit.live(device,item['clip'],'pose2',item['repeat'],audit=True)
        assert (out/'complete.json').exists()
        device.copy('from','Documents/RFValidation-vision-study-'+item['clip']+'/source-admission.json',out/'source-admission.json',60)
        status=audit.read(out/'status.json');profile=audit.read(out/'profile.json');report=audit.read(out/'report.json')
        source=audit.read(out/'source-admission.json');trace=plistlib.load((out/'counter.plist').open('rb'))
        assert status['replay_precise_clock'] and source['precise_clock'] and not source['dropped_rows']
        assert profile['visionRevisions']['failedRetryClock' if failed else 'independentRegularClock']==report['failed_retry_clock' if failed else 'independent_regular_clock']==enabled
        if failed:assert not profile['visionRevisions']['independentRegularClock']
        assert profile['visionRevisions']['sourceCadenceVersion']==0
        assert not profile['visionRevisions']['reservedImpactGap'] and not profile['visionRevisions']['trackingDrainBudget']
        assert ('|'+flag[2:] in report['pipeline'])==enabled
        assert trace['config']['confirmsDirectedForefoot'] and trace['config']['recoversObservedUnarmedTurn']
        assert [r['source_frame'] for r in source['rows'] if r['admitted']]==[o['input']['sourceFrameIndex'] for o in trace['operations'] if 'input'in o]
        assert sum(not r['admitted'] for r in source['rows'])==status['late_source_skips']
        assert report['worker']['maximum_active']==1 and report['worker']['model_instances']==1
        for event in report['rf_events']:
            if event.get('purpose','regular')=='regular' and 'previous_regular_submission_uptime'in event:
                assert event['submission_uptime']-event['previous_regular_submission_uptime']+1e-6>=1/event['target_hz']
        print('CLOCK_CHECK',item['clip'],arm,'changes',report['failed_retry_clock_refunds' if failed else 'retry_clock_bypasses'],'regular',report['worker']['regular'],'gap',report['worker']['impact_gap'],'contact',report['worker']['contact'],flush=True)
    print('PHASE_COMPLETE',args.phase,flush=True)

if __name__=='__main__':main()
