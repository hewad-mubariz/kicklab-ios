#!/usr/bin/env python3
"""Separate candidate-window and floor-margin arms on iPhone17 only."""
import argparse,importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=audit.study.OUT/'compact-window-iphone17'
ARMS={'baseline':[], 'candidate':['--compact-release-window-v1'],
      'margin':['--resolved-floor-margin-v1'],
      'combined':['--compact-release-window-v1','--resolved-floor-margin-v1']}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips',nargs='+',required=True)
    p.add_argument('--arms',nargs='+',choices=ARMS,default=['baseline','candidate'])
    p.add_argument('--repeat',type=int,required=True)
    args=p.parse_args();audit.study.BUILD='2026102922';device=audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.arms:
            audit.BASE=BASE/arm
            audit.study.ARMS['pose2']=['--vision-body-pose-revision2']+ARMS[arm]
            audit.live(device,clip,'pose2',args.repeat,audit=True)
            folder=audit.BASE/device.name/f'{clip}-pose2-r{args.repeat}'
            if not (folder/'complete.json').exists():raise RuntimeError('Incomplete run: '+str(folder))
            status=audit.read(folder/'status.json');v=status['visionRevisions']
            assert v['sourceCadenceVersion']==0 and not v['sharedPoseHistory'] and not v['shallowLateralContact'],v
            assert v['compactReleaseWindow']==('candidate'==arm or arm=='combined'),v
            assert v['resolvedFloorMargin']==('margin'==arm or arm=='combined'),v
            s=audit.read(folder/'summary.json');s.update(experimentArm=arm,repeat=args.repeat)
            audit.study.dump(folder/'summary.json',s)
