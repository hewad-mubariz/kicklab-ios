#!/usr/bin/env python3
"""Reserve the original missed retry only. Other experiment flags stay off."""
import argparse, importlib.util, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit', ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=ROOT/'artifacts/vision-revisions-20261030/impact-neighbor-iphone17'
ARMS={'baseline': [], 'reserved': ['--rf-reserved-gap-v1']}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips', nargs='+', required=True)
    p.add_argument('--arms', nargs='+', choices=ARMS, default=list(ARMS))
    p.add_argument('--repeat', type=int, required=True)
    p.add_argument('--version',type=int,choices=[1,2,3,4],default=1)
    args=p.parse_args();audit.study.BUILD=f'202610300{args.version}';device=audit.study.Device('iphone17')
    if args.version>1:
        BASE=BASE/('budget-only' if args.version==4 else f'v{args.version}')
        ARMS['reserved']=['--rf-drain-budget-v1'] if args.version==4 else [f'--rf-reserved-gap-v{args.version}']
    for clip in args.clips:
        for arm in args.arms:
            audit.BASE=BASE/arm
            audit.study.ARMS['pose2']=['--vision-body-pose-revision2']+ARMS[arm]
            audit.live(device,clip,'pose2',args.repeat,audit=True)
            folder=audit.BASE/device.name/f'{clip}-pose2-r{args.repeat}'
            assert (folder/'complete.json').exists(), str(folder)
            v=audit.read(folder/'status.json')['visionRevisions']
            assert v['sourceCadenceVersion']==0 and not any(v[k] for k in
                ['sharedPoseHistory','shallowLateralContact','compactReleaseWindow','resolvedFloorMargin']),v
            reservationSelected=arm=='reserved' and args.version!=4
            assert v['reservedImpactGap']==reservationSelected,v
            if args.version>1:assert v['reservedImpactGapVersion']==(args.version if reservationSelected else 0),v
            if args.version==4:assert v['trackingDrainBudget']==(arm=='reserved'),v
            report=audit.read(folder/'report.json')
            assert report['reserved_gap_enabled']==reservationSelected
            s=audit.read(folder/'summary.json');s.update(experimentArm=arm,repeat=args.repeat)
            audit.study.dump(folder/'summary.json',s)
