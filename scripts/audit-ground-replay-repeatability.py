#!/usr/bin/env python3
"""Locate upstream differences in completed recent-floor A/B replays.

This compares saved inputs and selected ankle/hip evidence. It does not assume
identical pixels and does not treat a counter total as a manual accuracy score.
"""
import json
import plistlib
import subprocess
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/vision-revisions-20261030/ground-impact-iphone17'
OUT = BASE / 'repeatability-audit'
REPORT = ROOT / 'benchmarks/touch-counting/vision-revisions-20261030/ground-impact-iphone17'


def read(path):
    return json.loads(path.read_text())


def selected_leg_records(trace):
    records = defaultdict(set)

    def visit(value):
        if isinstance(value, dict):
            if all(k in value for k in ['timestampMs', 'ballX', 'ankles', 'hips']):
                records[value['timestampMs']].add(json.dumps(
                    {k: value[k] for k in ['ankles', 'hips']}, sort_keys=True))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(trace['decisions'])
    return records


def scalar_decision(row):
    return dict(operation=row['operation'], **{
        k: v for k, v in row['value'].items() if not isinstance(v, (dict, list))})


def main():
    OUT.mkdir(exist_ok=True)
    pairs = []
    for pair in read(REPORT / 'summary.json')['pairs']:
        paths = [ROOT / pair[k]['directory'] for k in ['before', 'after']]
        assert all((p / 'complete.json').exists() for p in paths)
        assert pair['before']['sourceSHA256'] == pair['after']['sourceSHA256']
        traces = [plistlib.load((p / 'counter.plist').open('rb')) for p in paths]
        reports = [read(p / 'report.json') for p in paths]
        inputs = [{o['input']['timestampMs']: o['input'] for o in t['operations']
                   if 'input' in o} for t in traces]
        common = sorted(inputs[0].keys() & inputs[1].keys())
        # Ignore admitted-frame numbering: a source skip renumbers later inputs.
        fields = ['ball', 'person', 'cameraOffsetY', 'reliable', 'player']

        def comparable(value):
            if not isinstance(value, dict):
                return value
            return {k: comparable(v) for k, v in value.items()
                    if k not in ['frameIndex', 'sourceFrameIndex']}

        changed = [ms for ms in common if any(comparable(inputs[0][ms].get(k)) !=
                   comparable(inputs[1][ms].get(k)) for k in fields)]
        poses = [selected_leg_records(t) for t in traces]
        common_pose = sorted(poses[0].keys() & poses[1].keys())
        pose_changes = [ms for ms in common_pose if poses[0][ms] != poses[1][ms]]
        row = dict(clip=pair['clip'], build=pair['before']['build'], repeat=pair['repeat'],
                   directories=[str(p.relative_to(ROOT)) for p in paths],
                   commonInputTimestamps=len(common), changedInputs=len(changed),
                   firstInputDifferenceMs=changed[0] if changed else None,
                   inputTimestampOnlyBefore=sorted(inputs[0].keys()-inputs[1].keys()),
                   inputTimestampOnlyAfter=sorted(inputs[1].keys()-inputs[0].keys()),
                   commonLegEvidenceTimestamps=len(common_pose), changedLegEvidenceMs=pose_changes,
                   conflictingLegEvidenceWithinRun=[sorted(ms for ms, v in p.items() if len(v)>1)
                                                    for p in poses],
                   rawEmptyPoseCalls=[pair[k]['poseTiming']['empty'] for k in ['before', 'after']])
        if pair['clip'] == 'low' and pair['repeat'] == 2:
            row['targetWindows'] = []
            for label, lo, hi in [(54.08, 53850, 54300), (58.08, 57850, 58300)]:
                arms = []
                for trace, report in zip(traces, reports):
                    arms.append(dict(
                        decisions=[scalar_decision(d) for d in trace['decisions']
                                   if lo <= d['value']['timestampMs'] <= hi],
                        originalTracking=[s for s in report['samples']
                                          if lo <= s['source_seconds']*1000 <= hi],
                        contactRechecks=[s for s in report['rechecks']
                                         if lo <= s['source_seconds']*1000 <= hi]))
                row['targetWindows'].append(dict(labelSeconds=label, arms=arms))
            row['firstDivergenceDetectorEvents'] = [
                [s for s in r['rf_events'] if 52.1 <= s['source_seconds'] <= 52.47]
                for r in reports]
            row['firstDivergenceContactRechecks'] = [
                [s for s in r['rechecks'] if 51.5 <= s['source_seconds'] <= 52.4]
                for r in reports]
            row['motion'] = []
            for p in paths:
                result = subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),
                    'motion', str(p/'counter.plist')], capture_output=True, text=True, check=True)
                motion = [json.loads(line) for line in result.stdout.splitlines()]
                row['motion'].append([m for m in motion if 57800 <= m['ms'] <= 58300])
        pairs.append(row)
        print(row['clip'], row['repeat'], 'first input change', row['firstInputDifferenceMs'],
              'common leg records', len(common_pose), 'changed', len(pose_changes))
    result = dict(scope='12 completed pairs; saved selected ankle/hip evidence, not raw pixels or all joints',
                  pairs=pairs)
    (OUT/'pairs.json').write_text(json.dumps(result, indent=2)+'\n')
    swaps = [json.loads(line) for line in (OUT/'foot-box-swap-result.jsonl').read_text().splitlines()]
    assert [r['footConfirms'] for r in swaps] == [True, False, False, True]
    low = next(p for p in pairs if p['clip']=='low' and p['repeat']==2)
    assert low['firstInputDifferenceMs'] == 52333
    assert not low['changedLegEvidenceMs'] and low['rawEmptyPoseCalls'] == [0, 0]
    leg_comparisons = sum(p['commonLegEvidenceTimestamps'] for p in pairs)
    leg_changes = sum(len(p['changedLegEvidenceMs']) for p in pairs)
    lines = [
        'REVISION 2: FOLLOW-UP REPEATABILITY AUDIT — 30 OCTOBER 2026', '',
        'Scope: saved results from the 24 completed iPhone17 recent-floor tests (12 pairs).',
        'No additional phone install, model experiment or production rule change in this audit.', '',
        f'Common selected ankle/hip evidence: {leg_comparisons} timestamp comparisons; {leg_changes} differences.',
        'These totals count comparisons within each pair, not distinct frames across the whole corpus.',
        'Only shared saved leg samples are compared. This does not compare all body/hand outputs,',
        'raw image bytes or all requests. Other clips have empty raw-pose calls on different requested frames.',
        'It does not contradict the earlier exact-pixel empty-pose reproduction in IMG8606.', '',
        'LOW.MOV, FINAL PAIR: 171 -> 169 labelled legal contacts; no new ground-proof activations.',
        'The original counter inputs match through52.300s. First difference is52.333s.',
        'Both runs perform a contact recheck of the51.7667s frame. That holds the shared RF worker',
        'and delays regular inference for52.200s. The next regular detector exposure is52.3667s',
        'in control and52.3333s in the other run. The resulting sampling phases differ afterward.',
        'This is directly visible in submission/start/completion timestamps. It does not establish',
        'which individual OS scheduling event caused the timing difference. No source skips occur',
        'in this low pair, and both runs have zero raw empty body-pose calls.', '',
        '54.08s LABEL: measured candidate54.033s counts in control and fails foot proof in the other run.',
        'In the missed run, pixel tracking rejects54.0667s for texture correlation;54.100s then has',
        'no tracker seed. Both are successfully re-detected for contact evidence later. Therefore',
        'the remaining failure is not simply two unavailable frames or missing pose.',
        'The final candidate box and all saved contact ankle/hip coordinates allow a direct ablation:',
        'control right-ankle distance0.74739, missed-run distance0.80487, ordinary limit0.75.',
        'Distances use x/ball-width and y/ball-height normalization, not metres or physical distance.',
        'Swapping only contact ball X/Y/width/height/confidence flips the production Swift foot proof',
        'in BOTH directions, holding each receiving case\'s poses, before/after samples and flags fixed.',
        'This is a proof-level diagnostic, not a full counter recovery claim. Later vetoes still matter.',
        'Do not widen the foot radius from this single case: a nearby moving foot can accompany a bounce.', '',
        '58.08s LABEL: control counts a58.000s proposal; the other run creates no nearby candidate.',
        'All original ball frames are present in this window. The smoothed descent has two falling',
        'samples in control (57.933,57.966s), but only one in the missed run (57.966s). At57.933s',
        'velocity is0.08473 versus0.04343 image-heights/second. The direction threshold is0.05.',
        'The ordinary counter requires two direction samples, so its descent does not arm in the',
        'missed case. This is candidate sensitivity to changed ball observations, not a ground veto.', '',
        'DECISION: keep the tested recent-floor fix isolated and opt-in. The old global source-clock',
        'prototypes already lost valid contacts and should not be enabled based on this audit.',
        'Next bounded recovery work should test positive foot evidence under these alternate',
        'measured box/trajectory inputs, with the ground-negative corpus and unchanged vetoes.',
        'Include both sides of these pairs as fixtures, rather than optimizing one detector phase.',
        'For58s, the ordinary arming condition needs an independently supported observed-turn route;',
        'reducing minStateFrames globally would also admit noise. No recovery is claimed yet.', '',
        'Evidence: repeatability-audit/pairs.json, foot-box-swap.json and foot-box-swap-result.jsonl.',
        'Reproduce with scripts/audit-ground-replay-repeatability.py and scripts/audit-foot-box-swap.swift.',
    ]
    (REPORT/'REPEATABILITY.txt').write_text('\n'.join(lines)+'\n')


if __name__ == '__main__':
    main()
