#!/usr/bin/env python3
"""Capture bounded exact pose inputs; re-run those bytes independently on iPhone17."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('audit', ROOT/'scripts/run-deeper-vision-audit.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)
BASE = ROOT/'artifacts/vision-revisions-20261030/pose-input-iphone17'
audit.BASE = BASE
audit.study.BUILD = '2026103005'
CLIP = 'clip-a16380ba4a5b'


def capture(device, repeat):
    out = BASE/'iphone17'/f'{CLIP}-pose2-r{repeat}'
    if (out/'pose-input-audit/inputs.json').exists():
        print('CAPTURE_ALREADY_COMPLETE', repeat, flush=True)
        return
    audit.study.ARMS['pose2'] = ['--vision-body-pose-revision2', '--pose-input-audit']
    audit.live(device, CLIP, 'pose2', repeat, audit=True)
    assert (out/'complete.json').exists()
    profile = audit.read(out/'profile.json')
    assert '--pose-input-audit' in profile['effectiveFlags']
    revisions = profile['visionRevisions']
    assert not revisions['reservedImpactGap'] and not revisions['trackingDrainBudget']
    assert revisions['sourceCadenceVersion'] == 0 and not any(revisions[k] for k in
        ['compactReleaseWindow','resolvedFloorMargin','sharedPoseHistory','shallowLateralContact'])
    device.copy('from', 'Documents/touch-counter-profile.json', out/'capture-profile.json')
    assert audit.read(out/'run.json')['token'] in audit.read(out/'capture-profile.json')['explicitLaunchFlags']
    device.copy('from', f'Documents/RFValidation-vision-study-{CLIP}/pose-input-audit', out/'pose-input-audit', 90)
    inputs = audit.read(out/'pose-input-audit/inputs.json')
    assert not inputs['errors'] and inputs['rows']
    assert all(r['pixelsUnchanged'] for r in inputs['rows'])
    for row in inputs['rows']:
        data = (out/'pose-input-audit'/row['file']).read_bytes()
        assert len(data) == row['width']*row['height']*4
        assert hashlib.sha256(data).hexdigest() == row['sha256']
    print('CAPTURED', repeat, len(inputs['rows']), 'raw empty',
          sum(r['rawPoseCount']==0 for r in inputs['rows']), 'selection misses with raw pose',
          sum(r['rawPoseCount']>0 and r['selectedIndex'] is None for r in inputs['rows']), flush=True)


def probe(device, repeat):
    source = BASE/'iphone17'/f'{CLIP}-pose2-r{repeat}'/'pose-input-audit'
    assert (source/'inputs.json').exists()
    out = BASE/f'exact-probe-r{repeat}'
    out.mkdir(exist_ok=True)
    if (out/'complete.json').exists():
        print('PROBE_ALREADY_COMPLETE', repeat, flush=True)
        return
    name = f'RFValidation-exact-pose-r{repeat}'
    device.copy('to', source, 'Documents/'+name, 120)
    audit.study.dump(out/'config.json', {'mode':'pose-exact-input-probe'})
    audit.study.dump(out/'status.json', {'state':'prepared'})
    for f in ['config.json','status.json']:
        device.copy('to', out/f, 'Documents/'+name+'/'+f)
    device.launch(name, ['--vision-body-pose-revision2'])
    status = device.poll(name, out/'status.json', 240)
    device.copy('from', 'Documents/'+name+'/exact-probe-results.json', out/'results.json', 60)
    assert status['thermal'] <= 1
    audit.study.dump(out/'complete.json', status)
    print('PROBED', repeat, status['results'], 'results', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['capture','probe'])
    parser.add_argument('--repeats', type=int, nargs='+', required=True)
    args = parser.parse_args()
    device = audit.study.Device('iphone17')
    for repeat in args.repeats:
        (capture if args.phase=='capture' else probe)(device, repeat)
