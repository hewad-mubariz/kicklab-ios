#!/usr/bin/env python3
"""Measure initial stationary-anchor suppression on original paced footage."""
import argparse
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/run-deeper-vision-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
BASE = ROOT/'artifacts/vision-revisions-20261030/stationary-motion-iphone17'
ARMS = {'baseline': [], 'motion': ['--stationary-gate-motion-v3']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clips', nargs='+', required=True)
    parser.add_argument('--arms', choices=ARMS, nargs='+', default=['baseline'])
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--build', default='2026103008')
    args = parser.parse_args()
    assert args.build != '2026103007' or args.arms == ['baseline'], 'Build 07 has diagnostics only'
    audit.study.BUILD = args.build
    device = audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.arms:
            audit.BASE = BASE/('build'+args.build)/arm
            audit.study.ARMS['pose2'] = ['--vision-body-pose-revision2', '--stationary-gate-audit']+ARMS[arm]
            audit.live(device, clip, 'pose2', args.repeat, audit=True)
            out = audit.BASE/'iphone17'/f'{clip}-pose2-r{args.repeat}'
            assert (out/'complete.json').exists()
            status = audit.read(out/'status.json'); v = status['visionRevisions']
            if args.build != '2026103007':
                assert v['stationaryGateVersion'] == (3 if arm == 'motion' else 2)
            assert not v['poseEmptyLegacyFallback'] and not v['reservedImpactGap']
            assert not v['trackingDrainBudget'] and v['sourceCadenceVersion'] == 0
            assert not any(v[k] for k in ['compactReleaseWindow', 'resolvedFloorMargin', 'sharedPoseHistory', 'shallowLateralContact'])
            report = audit.read(out/'report.json')
            rows = [s for s in report['samples'] if 'stationary_gate_candidates' in s]
            assert rows, 'Missing stationary candidate evidence'
            audit.study.dump(out/'stationary-gate.json', rows)
