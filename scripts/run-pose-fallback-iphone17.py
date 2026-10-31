#!/usr/bin/env python3
"""Original paced footage; only the empty-revision2 legacy fallback differs."""
import argparse
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/run-deeper-vision-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
BASE = ROOT/'artifacts/vision-revisions-20261030/pose-input-iphone17/fallback'
ARMS = {'baseline': [], 'fallback': ['--pose-empty-legacy-fallback-v1']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clips', nargs='+', required=True)
    parser.add_argument('--arms', choices=ARMS, nargs='+', default=list(ARMS))
    parser.add_argument('--repeat', type=int, required=True)
    args = parser.parse_args()
    audit.study.BUILD = '2026103006'
    device = audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.arms:
            audit.BASE = BASE/arm
            audit.study.ARMS['pose2'] = ['--vision-body-pose-revision2']+ARMS[arm]
            audit.live(device, clip, 'pose2', args.repeat, audit=True)
            out = audit.BASE/'iphone17'/f'{clip}-pose2-r{args.repeat}'
            assert (out/'complete.json').exists()
            status = audit.read(out/'status.json');v=status['visionRevisions']
            assert v['poseEmptyLegacyFallback'] == (arm == 'fallback')
            assert not v['reservedImpactGap'] and not v['trackingDrainBudget'] and v['sourceCadenceVersion']==0
            assert not any(v[k] for k in ['compactReleaseWindow','resolvedFloorMargin','sharedPoseHistory','shallowLateralContact'])
            assert '--pose-input-audit' not in audit.read(out/'profile.json')['effectiveFlags']
            rows=status['poseEmptyFallback']['rows']
            assert not rows or arm == 'fallback'
            summary=audit.read(out/'summary.json');summary.update(experimentArm=arm,repeat=args.repeat,
                fallbackCalls=len(rows),fallbackMatched=sum(r['selectedIndex'] is not None for r in rows),
                fallbackMS=sum(r['milliseconds'] for r in rows),fallbackRows=rows)
            audit.study.dump(out/'summary.json',summary)
            print('FALLBACK',clip,arm,len(rows),'matched',summary['fallbackMatched'],flush=True)
