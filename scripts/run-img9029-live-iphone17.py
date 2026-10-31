#!/usr/bin/env python3
"""Run the user-supplied IMG_9029 at real time, then open its exact saved decisions."""
import argparse, hashlib, importlib.util, json, plistlib, subprocess, time, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/vision-revisions-20261030/img9029-iphone17'
SOURCE = Path('/Users/hewadmubariz/Downloads/IMG_9029.MOV')
spec = importlib.util.spec_from_file_location('low', ROOT / 'scripts/run-low-contact-robustness-iphone17.py')
low = importlib.util.module_from_spec(spec); spec.loader.exec_module(low)
audit = low.audit; study = audit.study
FLAGS = low.COMMON + low.ARMS['both']

def register():
    digest = hashlib.file_digest(SOURCE.open('rb'), 'sha256').hexdigest()
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
        '-show_entries', 'format=duration:stream=width,height,avg_frame_rate', '-of', 'json', str(SOURCE)]))
    study.dump(BASE / 'source-probe.json', probe)
    inventory_path = study.OUT / 'corpus-inventory.json'
    inventory = audit.read(inventory_path)
    existing = next((c for c in inventory['clips'] if c['sha256'] == digest), None)
    if existing is None:
        study.dump(BASE / 'inventory-before.json', inventory)
        existing = dict(id='clip-' + digest[:12], sha256=digest, source=str(SOURCE),
            aliases=[str(SOURCE)], bytes=SOURCE.stat().st_size, duration=float(probe['format']['duration']),
            video=probe['streams'][0], labelFile=None, referenceCoverage='unreviewed', state='ready')
        inventory['clips'].append(existing)
        inventory['totals'].update(uniqueSources=len(inventory['clips']),
            aliases=sum(len(c['aliases']) for c in inventory['clips']),
            sourceMinutes=round(sum(c.get('duration', 0) for c in inventory['clips']) / 60, 2))
        inventory['scope'] += ' IMG_9029.MOV added at the user’s request on 30 October 2026.'
        study.dump(inventory_path, inventory)
        study.dump(ROOT / 'benchmarks/touch-counting/vision-revisions-20261029/corpus-inventory.json', inventory)
    study.dump(BASE / 'source.json', existing)
    return existing

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['run', 'show'])
    parser.add_argument('--repeat', type=int, default=1)
    parser.add_argument('--pose', choices=['legacy', 'revision2'], default='revision2')
    args = parser.parse_args()
    flags = FLAGS if args.pose == 'revision2' else [f for f in FLAGS if f != '--vision-body-pose-revision2']
    arm = 'pose2' if args.pose == 'revision2' else 'control'
    clip = register(); study.BUILD = '2026103020'; audit.BASE = BASE
    d = study.Device('iphone17')
    folder = 'RFValidation-vision-study-' + clip['id']
    out = BASE / 'iphone17' / f"{clip['id']}-{arm}-r{args.repeat}"
    if args.action == 'run':
        study.ARMS[arm] = flags + ['--replay-source-audit', '--replay-precise-clock-v1']
        audit.live(d, clip['id'], arm, args.repeat, audit=True)
        assert (out / 'complete.json').exists(), 'Replay did not complete'
        d.copy('from', 'Documents/' + folder + '/source-admission.json', out / 'source-admission.json', 60)
        r = audit.read(out / 'report.json'); p = audit.read(out / 'profile.json')
        assert not r['independent_regular_clock'] and not r['failed_retry_clock']
        study.validate_revision(p['visionRevisions'], arm)
        assert p['visionRevisions']['directedForefoot'] and p['visionRevisions']['observedUnarmedTurn']
        assert r['worker']['model_instances'] == r['worker']['maximum_active'] == 1
        trace = plistlib.loads((out / 'counter.plist').read_bytes())
        source = audit.read(out / 'source-admission.json')
        assert [x['source_frame'] for x in source['rows'] if x['admitted']] == [x['input']['sourceFrameIndex'] for x in trace['operations'] if 'input' in x]
        print('VERIFIED', json.dumps(audit.read(out / 'summary.json')), flush=True)
        return
    assert (out / 'complete.json').exists()
    # Restore the selected completed run, so the display cannot silently use a different repeat/cache.
    for name in ['counter.plist', 'touches.json', 'track.plist', 'config.json', 'status.json']:
        d.copy('to', out / name, 'Documents/' + folder + '/' + name)
    review = BASE / 'review'; review.mkdir(exist_ok=True)
    token = '--img9029-review-' + uuid.uuid4().hex
    study.dump(review / 'marker.json', {'state': 'pending', 'token': token})
    d.copy('to', review / 'marker.json', 'Documents/' + folder + '/review-state.json')
    d.command(['process', 'launch', '--device', d.id, '--terminate-existing', '--timeout', '25', '--',
        study.BUNDLE, *study.FLAGS, *flags, token, '--session-design', 'effects',
        '--rf-full-app-review', folder, '--touch-debug-hold', '0', '-debug.touchOutlines', 'YES'], 40)
    for _ in range(20):
        time.sleep(1)
        d.copy('from', 'Documents/touch-counter-profile.json', review / 'profile.json')
        d.copy('from', 'Documents/' + folder + '/review-state.json', review / 'state.json')
        state = audit.read(review / 'state.json'); profile = audit.read(review / 'profile.json')
        if state.get('state') == 'ready' and token in profile['explicitLaunchFlags']: break
    assert state['state'] == 'ready' and state['touches'] == audit.read(out / 'summary.json')['count']
    assert profile['build'] == study.BUILD and state['outlines'] and state['position'] == 0
    study.validate_revision(profile['visionRevisions'], arm)
    assert not profile['visionRevisions']['failedRetryClock'] and not profile['visionRevisions']['independentRegularClock']
    study.dump(review / 'verified.json', {'build': study.BUILD, 'selectedRun': str(out), 'state': state,
        'profile': profile['visionRevisions'], 'freshReviewWriteVerified': True})
    print('REVIEW_READY', json.dumps(state), flush=True)

if __name__ == '__main__': main()
