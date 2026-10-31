#!/usr/bin/env python3
"""Summarize completed independent experiments, including event-level losses."""
import json, statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/vision-revisions-20261029/compact-window-iphone17'
rows = []
for arm in ['baseline', 'candidate', 'margin', 'combined']:
    for path in sorted((BASE / arm / 'iphone17').glob('*/summary.json')):
        if not (path.parent / 'complete.json').exists():
            continue
        read = lambda name: json.loads((path.parent / name).read_text())
        s, report, score, run, status = [read(n) for n in
            ['summary.json', 'report.json', 'label-score.json', 'run.json', 'status.json']]
        assert status['trace_replay_exact'] and not report['quality_failed']
        assert s['build'] == run['build'] == '2026102922'
        v = status['visionRevisions']
        assert v['bodyPoseImplementation'] == 'Swift revision2'
        assert v['sourceCadenceVersion'] == 0 and not v['sharedPoseHistory'] and not v['shallowLateralContact']
        assert v['compactReleaseWindow'] == (arm in ['candidate', 'combined'])
        assert v['resolvedFloorMargin'] == (arm in ['margin', 'combined'])
        s.update(experimentArm=arm, repeat=run['repeat'],
            resultDirectory=str(path.parent.relative_to(ROOT)),
            acceptedLabels={e['label_id']: e['label_time_s'] for e in score['matched']},
            notificationLatencyMedianMs=statistics.median(report['notification_latency_ms'])
                if report.get('notification_latency_ms') else None,
            overflowDrops=report.get('overflow_drops'),
            regularFrames=[e['source_frame'] for e in report['rf_events']
                if e.get('purpose', 'regular') == 'regular'])
        rows.append(s)
pairs = []
for clip, repeat in sorted({(r['clip'], r['repeat']) for r in rows}):
    arms = {r['experimentArm']: r for r in rows if r['clip'] == clip and r['repeat'] == repeat}
    if 'baseline' not in arms:
        continue
    a = arms['baseline']
    for arm, b in arms.items():
        if arm == 'baseline':
            continue
        aa, bb = a['acceptedLabels'], b['acceptedLabels']
        pairs.append(dict(clip=clip, repeat=repeat, experiment=arm,
            legal=[a['acceptedValid'], b['acceptedValid']],
            knownFalse=[a['knownFalse'], b['knownFalse']],
            unmatched=[a['unmatchedNeedingReview'], b['unmatchedNeedingReview']],
            gainedSeconds=sorted(bb[k] for k in bb.keys() - aa.keys()),
            lostSeconds=sorted(aa[k] for k in aa.keys() - bb.keys()),
            sameRegularFrames=a['regularFrames'] == b['regularFrames']))

ablations = []
if (BASE / 'ablation.jsonl').exists():
    for line in (BASE / 'ablation.jsonl').read_text().splitlines():
        d = json.loads(line)
        d['addedMs'] = sorted(set(d['enabledMs']) - set(d['disabledMs']))
        d['removedMs'] = sorted(set(d['disabledMs']) - set(d['enabledMs']))
        d['completeCounterfactualEvidence'] = not d['disabledMissingCallbacks']
        ablations.append(d)
summary = dict(scope='iPhone17 paced original-video replay, revision2 in all arms, build2026102922',
    completedRuns=len(rows), pairs=pairs, runs=rows, ablations=ablations)
(BASE / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')

lines = ['COMPACT CANDIDATE / IMPACT FLOOR EXPERIMENT — 29–30 OCTOBER 2026', '',
    'DECISION: Both experiments remain opt-in and separate. Neither has passed the fresh no-regression requirement. Do not promote either to field defaults, main app or TestFlight.', '',
    'SCOPE: iPhone17 Pro Max only; build2026102922. Both sides use body pose revision2, the existing 24 counting flags, automatic compute and the existing scheduler. Shared-history, source-cadence and shallow-lateral experiments are off. This is not a revision1-versus-revision2 comparison.', '',
    'CANDIDATE CHANGE: --compact-release-window-v1 retains a continuous measured ball reversal for 65–167 ms while two release views develop. The fixed five-view early route can otherwise move past a shallow peak before the release is resolved; smoothing can leave only one falling view. The new route requires positive measured foot evidence and the existing body, hand, holding and floor checks. It respects cooldown, clipping, ball-size stability and recent rejections. No clip name, absolute timestamp or new Vision model is used.', '',
    'FLOOR CHANGE: --resolved-floor-margin-v1 requires a center at least 0.1 ball heights below both ankles in two views for the below-feet proof. Other floor and foot proofs are unchanged. A few thousandths of normalized ball-position movement could previously flip IMG8874 at 7.39 s between one and two below-ankle views. The experiment addresses that numerical ambiguity, not all ground-contact timing problems.', '',
    'COMPLETED PHONE PAIRS (legal contacts; false counts separate):']
for p in pairs:
    lines.append(f"{p['experiment']}, {p['clip']}, repeat {p['repeat']}: legal {p['legal'][0]} -> {p['legal'][1]}; known false {p['knownFalse'][0]} -> {p['knownFalse'][1]}; unmatched {p['unmatched'][0]} -> {p['unmatched'][1]}; gained {p['gainedSeconds']}; lost {p['lostSeconds']}.")
lines += ['', 'IMPORTANT EVENT FINDINGS:',
    'Low, 4.06 s: recovered by the candidate window in both initial fresh repeats (counter timestamp 4.033 s). The first pair is 161 -> 162; the second is 161 -> 161 because 54.08 s is lost. The other examined shallow peaks at 12.633, 20.566 and 28.600 s now reach verification but still fail positive foot proof. Candidate eligibility alone must not count them.',
    'Low, 54.08 s: both runs propose 54.033 s. Baseline positive foot proof uses 53.900/54.033/54.166 s, while the candidate run obtains a different ball box and 53.933/54.033/54.133 s window. Right-ankle distance becomes 0.805 instead of 0.747 ball diameters against the existing 0.75 limit. It is an evidence/proximity failure, not absence of a candidate. This does not isolate whether ordinary scheduling variation or extra work caused the changed detector inputs; the observed loss still blocks promotion.',
    'IMG8606, first margin pair: 34 -> 33 legal, with the same known false at 20.176 s. It gains 0.566 s but loses 18.25 and 18.875 s. The experimental run has 36 empty pose results versus 1, with no pose exceptions or late source skips. The regression cannot be dismissed because the numerical floor change is a relaxation.',
    'IMG8874: baseline and margin first pair both count 24. The later baseline and candidate pair both count 23, missing 7.39 s. The underlying input/timing instability is present without either experimental rule.', '',
    'Repeat margin: IMG8874 improves 23 -> 24 by recovering 7.39 s. IMG8606 improves 34 -> 35 by recovering 18.25 s, with the same existing false count. These promising repeats do not erase the losses in the first margin comparison.',
    'Raw-juggling regression: baseline counts 7 legal contacts, candidate run 4; the lost reviewed contacts are 4.43, 5.60 and 6.62 s. The candidate trace records trackLost near those events. On identical saved input, enabling or disabling the new candidate rule both produce exactly the same four contacts, with no missing callbacks. This isolates the losses from the numeric candidate rule on that trace, but not from possible timing effects of the full workload. Baseline reports two late source skips; candidate reports zero. Do not treat this as an all-frames identical-input live comparison.', '',
    'IDENTICAL-INPUT ABLATION LIMIT: The lab now records missing callback lookups explicitly. Disabling a candidate path can move a later evidence request to a different operation; that callback may not exist in the saved trace. Gains after such a gap are not proven recoveries. The full enabled trace must replay exactly, and a complete disabled callback set is required for a whole-trace causal claim. Inspect summary.json rather than treating every enabled/disabled count difference as real.', '',
    'CAUSAL DETAIL: In both low candidate traces, the 4.033 s recovery precedes the first absent disabled callback by roughly 26 seconds. Later apparent ablation gains around 30–58 s have incomplete callback coverage and are not claimed. The fresh IMG8606 candidate gain at 18.25 s remains counted with the new candidate rule disabled; it is not an isolated benefit of that rule. Likewise, missing fallback callbacks prevent treating the margin ablation total as a complete counterfactual.', '',
    'VALIDATION: App build22 succeeded; 73 candidate-window/ground-margin contracts passed. All 123 historical default traces replay exactly. The floor-evidence screen covered 123 saved traces across 23 unique clips: 12 unique changed timestamps, all near reviewed legal contacts; some were already accepted through foot proof, so these are not 12 recovered touches. A separate 60-trace older outdoor screen changes only three already accepted events and preserves the two reviewed three-minute bounces at 153.773 and 154.206 s. These are numeric evidence screens, not fresh whole-corpus device validation.', '',
    'PERFORMANCE (pose means are per-run; small differences do not establish a speed improvement):']
for clip in sorted({r['clip'] for r in rows}):
    for arm in ['baseline', 'candidate', 'margin', 'combined']:
        rs = [r for r in rows if r['clip'] == clip and r['experimentArm'] == arm]
        if not rs:
            continue
        means = [round(r['poseTiming']['totalMS'] / r['poseTiming']['calls'], 2)
                 if r['poseTiming']['calls'] else None for r in rs]
        lines.append(f"{clip}, {arm}: pose calls {[r['poseTiming']['calls'] for r in rs]}, means {means} ms; frame-pipeline medians {[round(r['latencyMedianMs'],1) if r['latencyMedianMs'] is not None else None for r in rs]} ms; notification medians {[round(r['notificationLatencyMedianMs'],1) if r['notificationLatencyMedianMs'] is not None else None for r in rs]} ms.")
lines += ['', f"Completed runs {len(rows)}. Highest thermal state {max((r['worstThermal'] for r in rows),default=0)} (0=nominal). Pose errors {sum(r['poseTiming']['errors'] for r in rows)}. Late source skips {sum(r['lateSourceSkips'] for r in rows)}. Overflow drops {sum(r['overflowDrops'] or 0 for r in rows)}.", '',
    'HOST INTERRUPTIONS: Storage filled during report collection. Generated build caches were removed, preserving sources, recordings, evidence and signed app products; the user also freed space. A completed low baseline was recovered and validated after transfer failure. A later IMG8874 baseline was recovered after a partially copied progress JSON. These completed results passed count/export/trace/source checks. Polling now tolerates partial JSON only within its existing deadline. Unrelated background Git repacks were left alone.', '',
    'LIMITS: Paced original-video replay is not live camera capture. No iPhone11 testing, ordinary-import fix, revision1 comparison, full new-corpus percentage or TestFlight promotion is established here. The dribbling negative has 16 empty pose results; it is a useful no-count control but does not strongly exercise downstream foot proofs.', '',
    'NEXT: Preserve this isolated candidate recovery, then address phase-dependent ball/foot alignment and positive foot evidence for the now-generated shallow candidates. Keep the floor margin separate until repeated positive and ground-negative device checks pass. Do not globally lower foot-distance or motion thresholds.', '',
    'PHONE: ' + ('Verified restoration to field build2026102913, revision2, no experimental flags, IMG8874 main preview at 24 touches, position zero, outlines off.' if (BASE/'restore/verified.json').exists() else 'Restoration not yet verified.'), '',
    'EVIDENCE: summary.json, protocol.json, source-sha256.json, contracts.txt, historical-replay.txt, ground-margin-screen.jsonl, outdoor-ground-screen.jsonl, ablation.jsonl, low-54.08-investigation.json and per-arm phone folders.']
(BASE / 'RESULTS.txt').write_text('\n'.join(lines) + '\n')
dest = ROOT / 'benchmarks/touch-counting/vision-revisions-20261029/compact-window-iphone17'
dest.mkdir(parents=True, exist_ok=True)
(dest / 'RESULTS.txt').write_text((BASE / 'RESULTS.txt').read_text())
for p in pairs:
    print(p)
print('Wrote', dest / 'RESULTS.txt')
