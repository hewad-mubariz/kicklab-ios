#!/usr/bin/env python3
"""Original-paced comparisons; both arms keep the same startup motion gate."""
import argparse
import importlib.util
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/run-deeper-vision-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
BASE = ROOT/'artifacts/vision-revisions-20261030/short-contact-stability-iphone17'
ARMS = {'motion': [], 'clock': ['--contact-window-clock-v1'],
        'fall': ['--observed-fall-amplitude-v1'],
        'short': ['--observed-fall-amplitude-v1', '--observed-short-rise-v1'],
        'shortfoot': ['--observed-fall-amplitude-v1', '--observed-short-rise-v1', '--observed-plateau-foot-v1'],
        'observed': ['--contact-window-clock-v1', '--observed-fall-amplitude-v1']}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--clips', nargs='+', required=True)
    parser.add_argument('--arms', choices=ARMS, nargs='+', default=['clock','observed'])
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--build', default='2026103010')
    parser.add_argument('--output-root', type=Path, default=BASE)
    args = parser.parse_args()
    assert 'short' not in args.arms or args.build in ['2026103012','2026103013']
    assert 'shortfoot' not in args.arms or args.build == '2026103013'
    assert args.build != '2026103009' or not set(args.arms).intersection({'observed','fall'})
    audit.study.BUILD = args.build
    device = audit.study.Device('iphone17')
    for clip in args.clips:
        for arm in args.arms:
            audit.BASE = args.output_root/('build'+args.build)/arm
            audit.study.ARMS['pose2'] = ['--vision-body-pose-revision2', '--stationary-gate-motion-v3', '--contact-window-audit']+ARMS[arm]
            audit.live(device, clip, 'pose2', args.repeat, audit=True)
            out = audit.BASE/'iphone17'/f'{clip}-pose2-r{args.repeat}'
            assert (out/'complete.json').exists()
            status = audit.read(out/'status.json'); v = status['visionRevisions']
            assert v['stationaryGateVersion'] == 3 and v['contactWindowClock'] == (arm in ['clock','observed'])
            if args.build != '2026103009':
                assert v['observedFallAmplitude'] == (arm in ['fall','observed','short','shortfoot'])
            if 'observedShortRise' in v:
                assert v['observedShortRise'] == (arm in ['short','shortfoot'])
            if 'observedPlateauFoot' in v:
                assert v['observedPlateauFoot'] == (arm == 'shortfoot')
            assert not v['poseEmptyLegacyFallback'] and not v['reservedImpactGap']
            assert not v['trackingDrainBudget'] and v['sourceCadenceVersion'] == 0
            assert not any(v[k] for k in ['compactReleaseWindow', 'resolvedFloorMargin', 'sharedPoseHistory', 'shallowLateralContact'])
            report = audit.read(out/'report.json')
            assert 'contact_window_admissions' in report
            trace = plistlib.load((out/'counter.plist').open('rb'))
            assert (trace['config'].get('usesObservedFallAmplitude') == True) == (arm in ['fall','observed','short','shortfoot'])
            assert (trace['config'].get('recoversObservedShortRise') == True) == (arm in ['short','shortfoot'])

            assert (trace['config'].get('confirmsObservedPlateauFoot') == True) == (arm == 'shortfoot')
