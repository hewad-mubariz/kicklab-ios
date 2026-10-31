#!/usr/bin/env python3
"""Score the fixed reviewed corpus once per arm, keeping uncertainty explicit."""
import argparse
from collections import Counter
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/vision-revisions-20261029'
COMPACT = ROOT / 'benchmarks/touch-counting/vision-revisions-20261029'
ARMS = ['control', 'pose2', 'tracking2']
BUILD = '2026102911'


def write_json(path, value):
    temp = path.with_suffix('.json.tmp')
    temp.write_text(json.dumps(value, indent=2) + '\n')
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', choices=['iphone11', 'iphone17'], required=True)
    args = parser.parse_args()
    inventory = json.loads((OUT / 'corpus-inventory.json').read_text())
    clips = [c for c in inventory['clips'] if c['labelFile']]
    assert len(clips) == 20, 'The reviewed cohort must remain fixed.'
    labels = {c['id']: json.loads(Path(c['labelFile']).read_text()) for c in clips}
    rows = []
    for clip in clips:
        label = labels[clip['id']]
        assert label['source_sha256'] == clip['sha256']
        runs = {}
        for arm in ARMS:
            folder = OUT / f'{args.device}-build{BUILD}' / f"{clip['id']}-{arm}-r1"
            if not (folder / 'complete.json').exists():
                runs[arm] = {'state': 'pending'}
                status_path = folder / 'status.json'
                if status_path.exists():
                    status = json.loads(status_path.read_text())
                    if status.get('state') == 'failed':
                        runs[arm] = {'state': 'failed', 'error': status.get('error')}
                continue
            summary = json.loads((folder / 'summary.json').read_text())
            status = json.loads((folder / 'status.json').read_text())
            meta = json.loads((folder / 'run.json').read_text())
            assert meta['sourceSHA256'] == clip['sha256'] and meta['build'] == BUILD
            assert status['trace_replay_exact']
            if not summary['validForAccuracy']:
                runs[arm] = {'state': 'invalid', 'reason': summary.get('invalidReason')}
                continue
            score = json.loads((folder / 'label-score.json').read_text())
            assert score['source_sha256'] == clip['sha256']
            assert score['total_count'] == sum(len(score[k]) for k in [
                'matched', 'false_accepted', 'uncertain_accepted', 'unmatched_needing_review'])
            runs[arm] = {
                'state': 'completed', 'count': score['total_count'],
                'legal': score['accepted_valid'], 'knownFalse': len(score['false_accepted']),
                'uncertain': len(score['uncertain_accepted']),
                'unreviewed': len(score['unmatched_needing_review']),
                'missed': len(score['missed_valid']),
                'matchedLegalByID': {m['label_id']: m['label_time_s'] for m in score['matched']},
                'missedEvents': score['missed_valid'], 'falseEvents': score['false_accepted'],
                'uncertainEvents': score['uncertain_accepted'],
                'unreviewedEvents': score['unmatched_needing_review'],
                'sourceSkips': summary['lateSourceSkips'],
                'worstThermal': summary['worstThermal'],
                'poseTiming': summary.get('poseTiming'),
                'medianPipelineLatencyMS': summary['latencyMedianMs'],
                'peakSampledMemoryMiB': summary['peakSampledMemoryMiB'],
                'pipeline': summary['pipeline'], 'countingFlags': [f for f in meta['flags']
                    if f not in ['--vision-body-pose-revision2', '--follow-vision-revision2']],
            }
        complete = all(runs[a]['state'] == 'completed' for a in ARMS)
        if complete:
            assert all(set(runs[a]['countingFlags']) == set(runs['control']['countingFlags']) for a in ARMS)
            # Only the named revision switch may differ within a clip's pipeline.
            def baseline_pipeline(s):
                return s.replace('|vision-body-pose-swift-r2', '').replace('|vision-track-r2', '')
            assert len({baseline_pipeline(runs[a]['pipeline']) for a in ARMS}) == 1
        rows.append({'clip': clip['id'], 'duration': clip['duration'],
            'sourceSHA256': clip['sha256'], 'reviewStatus': label['review_status'],
            'labelledValid': sum(e['label'] == 'valid' for e in label['events']),
            'labelledUncertain': sum(e['label'] == 'uncertain' for e in label['events']),
            'completeTriplet': complete, 'runs': runs})

    matched_rows = [r for r in rows if r['completeTriplet']]
    denominator = sum(r['labelledValid'] for r in matched_rows)
    totals = {}
    for arm in ARMS:
        rr = [r['runs'][arm] for r in matched_rows]
        total = {key: sum(r[key] for r in rr) for key in [
            'count', 'legal', 'missed', 'knownFalse', 'uncertain', 'unreviewed', 'sourceSkips']}
        total['labelledValid'] = denominator
        total['legalRecallPercent'] = 100 * total['legal'] / denominator if denominator else None
        positive_rows = [r for r in matched_rows if r['labelledValid']]
        total['meanClipRecallPercent'] = (sum(100 * r['runs'][arm]['legal'] / r['labelledValid']
            for r in positive_rows) / len(positive_rows)) if positive_rows else None
        other_rows = [r for r in matched_rows if r['clip'] != 'low']
        other_labels = sum(r['labelledValid'] for r in other_rows)
        total['excludingFastLowClip'] = {
            'legal': sum(r['runs'][arm]['legal'] for r in other_rows),
            'labelledValid': other_labels,
            'knownFalse': sum(r['runs'][arm]['knownFalse'] for r in other_rows),
        }
        total['thermalRunCounts'] = dict(Counter(['nominal', 'fair', 'serious', 'critical'][r['worstThermal']] for r in rr))
        timings = [r['poseTiming'] for r in rr if r['poseTiming']]
        calls = sum(t['calls'] for t in timings)
        total['poseMeanMS'] = sum(t['totalMS'] for t in timings) / calls if calls else None
        total['poseCalls'] = calls
        total['missStages'] = dict(Counter(e['stage'] for r in rr for e in r['missedEvents']))
        total['missReasons'] = dict(Counter(
            (e.get('decision') or {}).get('rejection', 'no_nearby_candidate')
            for r in rr for e in r['missedEvents']))
        totals[arm] = total

    paired = {}
    for arm in ARMS[1:]:
        changes = []
        for row in matched_rows:
            current, candidate = row['runs']['control'], row['runs'][arm]
            old, new = current['matchedLegalByID'], candidate['matchedLegalByID']
            changes.append({'clip': row['clip'],
                'legalDelta': candidate['legal'] - current['legal'],
                'falseDelta': candidate['knownFalse'] - current['knownFalse'],
                'gainedLegalSeconds': sorted(new[k] for k in new.keys() - old.keys()),
                'lostLegalSeconds': sorted(old[k] for k in old.keys() - new.keys()),
                'bothNominalOrFair': max(current['worstThermal'], candidate['worstThermal']) <= 1})
        paired[arm] = {'legalGains': sum(len(c['gainedLegalSeconds']) for c in changes),
            'legalLosses': sum(len(c['lostLegalSeconds']) for c in changes),
            'clipsWithMoreLegal': sum(c['legalDelta'] > 0 for c in changes),
            'clipsWithFewerLegal': sum(c['legalDelta'] < 0 for c in changes),
            'clipsWithSameLegalCount': sum(c['legalDelta'] == 0 for c in changes),
            'clips': changes}

    common_misses = []
    for row in matched_rows:
        valid = {e['id']: e['time_s'] for e in labels[row['clip']]['events'] if e['label'] == 'valid'}
        accepted_any = set().union(*(set(row['runs'][a]['matchedLegalByID']) for a in ARMS))
        missing = sorted(valid[k] for k in valid.keys() - accepted_any)
        if missing:
            common_misses.append({'clip': row['clip'], 'legalSeconds': missing})

    result = {'device': args.device, 'build': BUILD,
        'scope': 'The fixed 20 original reviewed clips, first completed run per arm (r1). '
            'Existing pilot repeats and supplemental clips are excluded from cohort totals. '
            'Totals use only clips with all three valid arms; uncertainty and unreviewed '
            'counts remain separate. Labels were visually reviewed by one assistant, '
            'with human confirmation pending; this is development recall, not held-out release accuracy. '
            'Miss-reason summaries describe diagnostics near the reference time; they are hints, '
            'not independently verified causes for every missed contact.',
        'plannedClips': len(rows), 'completedTriplets': len(matched_rows),
        'completedRuns': sum(r['runs'][a]['state'] == 'completed' for r in rows for a in ARMS),
        'complete': len(matched_rows) == len(rows),
        'cohortLabelledValid': sum(r['labelledValid'] for r in rows),
        'cohortLabelledUncertain': sum(r['labelledUncertain'] for r in rows),
        'denominatorCompletedTriplets': denominator,
        'totals': totals, 'pairedComparisons': paired,
        'missedByAllThreeCount': sum(len(r['legalSeconds']) for r in common_misses),
        'missedByAllThree': common_misses, 'clips': rows}
    failed_attempts = []
    for path in sorted((OUT / 'failed-attempts' / args.device).glob('*/*/status.json')):
        meta = json.loads((path.parent / 'run.json').read_text())
        if meta['clip'] not in labels:
            continue
        status = json.loads(path.read_text())
        failure_path = path.parent / 'failure.json'
        failure = json.loads(failure_path.read_text()) if failure_path.exists() else {}
        failed_attempts.append({'clip': meta['clip'], 'arm': meta['arm'],
            'path': str(path.parent), 'error': status.get('error') or failure.get('error'),
            'thermal': status.get('thermal')})
    result['preservedFailedAttempts'] = failed_attempts
    plan_path = OUT / 'broad-study-plan.json'
    plan = json.loads(plan_path.read_text()) if plan_path.exists() else {}
    confirmations = []
    for clip_id in plan.get('confirmationClips', []):
        first = next(row for row in rows if row['clip'] == clip_id)
        second = {}
        for arm in ARMS:
            folder = OUT / f'{args.device}-build{BUILD}' / f'{clip_id}-{arm}-r2'
            if not (folder / 'complete.json').exists():
                continue
            s = json.loads((folder / 'summary.json').read_text())
            if not s['validForAccuracy']:
                continue
            second[arm] = {k: s[k] for k in ['count', 'acceptedValid', 'knownFalse',
                'missedLegalSeconds', 'knownFalseSeconds', 'worstThermal']}
        confirmations.append({'clip': clip_id,
            'firstRun': {a: {k: first['runs'][a].get(k) for k in ['legal', 'knownFalse']} for a in ARMS},
            'secondRun': second})
    result['selectedConfirmations'] = confirmations
    result['completedConfirmationRuns'] = sum(len(c['secondRun']) for c in confirmations)
    for dest in [OUT, COMPACT]:
        write_json(dest / f'{args.device}-reviewed-corpus-summary.json', result)
    print(json.dumps({k: result[k] for k in [
        'completedTriplets', 'completedRuns', 'complete', 'denominatorCompletedTriplets', 'totals']}, indent=2))


if __name__ == '__main__':
    main()
