#!/usr/bin/env python3
"""Paired iPhone17 revision2 contact-proof experiment with unchanged scheduling."""
import argparse, importlib.util
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('audit',ROOT/'scripts/run-deeper-vision-audit.py')
audit=importlib.util.module_from_spec(spec);spec.loader.exec_module(audit)
BASE=audit.study.OUT/'contact-evidence-audit-iphone17'
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--clips',nargs='+',default=['low','clip-a16380ba4a5b','clip-618a1688fcc6'])
    p.add_argument('--order',nargs='+',choices=['baseline','lateral'],default=['baseline','lateral'])
    p.add_argument('--repeat',type=int,required=True)
    args=p.parse_args();audit.study.BUILD='2026102921';device=audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.order:
            audit.BASE=BASE/arm
            audit.study.ARMS['pose2']=['--vision-body-pose-revision2']+(['--shallow-lateral-contact-v1'] if arm=='lateral' else [])
            audit.live(device,clip,'pose2',args.repeat,audit=True)
            folder=audit.BASE/device.name/(f'{clip}-pose2-r{args.repeat}')
            if not (folder/'complete.json').exists():raise RuntimeError('Incomplete run: '+str(folder))
            status=audit.read(folder/'status.json')
            v=status['visionRevisions']
            assert v['sourceCadenceVersion']==0 and not v['sourceCadence'] and not v['sharedPoseHistory'],v
            assert v['shallowLateralContact']==(arm=='lateral'),v
            summary=audit.read(folder/'summary.json');summary['experimentArm']=arm
            audit.study.dump(folder/'summary.json',summary)
