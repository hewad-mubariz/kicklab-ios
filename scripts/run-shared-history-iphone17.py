#!/usr/bin/env python3
"""iPhone 17 only: paired revision2 runs with/without shared early-history sampling."""
import argparse, importlib.util, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=audit.study.OUT/'shared-history-iphone17'
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips',nargs='+',default=['clip-a16380ba4a5b','clip-618a1688fcc6'])
    p.add_argument('--order',nargs='+',choices=['baseline','shared'],default=['baseline','shared'])
    p.add_argument('--repeat',type=int,required=True)
    args=p.parse_args();audit.study.BUILD='2026102916';device=audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.order:
            audit.BASE=BASE/arm
            audit.study.ARMS['pose2']=['--vision-body-pose-revision2']+(['--pose-shared-history-v1'] if arm=='shared' else [])
            audit.live(device,clip,'pose2',args.repeat,audit=True)
            folder=audit.BASE/device.name/(f'{clip}-pose2-r{args.repeat}')
            status=audit.read(folder/'status.json')
            assert status['visionRevisions']['sharedPoseHistory']==(arm=='shared'),status
            if (folder/'summary.json').exists():
                summary=audit.read(folder/'summary.json');summary['experimentArm']=arm
                audit.study.dump(folder/'summary.json',summary)
