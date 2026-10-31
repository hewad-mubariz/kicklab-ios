#!/usr/bin/env python3
"""Keep paired label changes separate from total-count and input-timing changes."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'artifacts/vision-revisions-20261030/stationary-motion-iphone17'
rows = []
for arm in ['baseline', 'motion']:
    for path in (BASE/'build2026103008'/arm/'iphone17').glob('*/summary.json'):
        if not (path.parent/'complete.json').exists():
            continue
        s = json.loads(path.read_text())
        score = json.loads((path.parent/'label-score.json').read_text())
        status = json.loads((path.parent/'status.json').read_text())
        report = json.loads((path.parent/'report.json').read_text())
        assert status['trace_replay_exact'] and not report['quality_failed']
        assert s['build'] == '2026103008' and s['worstThermal'] <= 1
        inputs = json.loads((path.parent/'stationary-gate.json').read_text())
        first_track = next((r['source_seconds'] for r in report['samples'] if r.get('available')), None)
        s.update(experimentArm=arm, repeat=int(path.parent.name.rsplit('-r',1)[1]),
            directory=str(path.parent.relative_to(ROOT)),
            acceptedLabels={r['label_id']:r['label_time_s'] for r in score['matched']},
            overflow=report['overflow_drops'], lateRF=report['late_replies'],
            firstTrack=first_track, suppressedReplies=sum(bool(r['stationary_gate_candidates']) and
                not any(c['eligible'] for c in r['stationary_gate_candidates']) for r in inputs))
        rows.append(s)
pairs = []
for clip, repeat in sorted({(r['clip'],r['repeat']) for r in rows}):
    arms = {r['experimentArm']:r for r in rows if r['clip']==clip and r['repeat']==repeat}
    if len(arms) != 2:
        continue
    a,b = arms['baseline'],arms['motion']; aa,bb = a['acceptedLabels'],b['acceptedLabels']
    assert a['sourceSHA256'] == b['sourceSHA256']
    pair = dict(clip=clip, repeat=repeat, legal=[a['acceptedValid'],b['acceptedValid']],
        total=[a['count'],b['count']], false=[a['knownFalse'],b['knownFalse']],
        unmatched=[a['unmatchedNeedingReview'],b['unmatchedNeedingReview']],
        gainedSeconds=sorted(bb[k] for k in bb.keys()-aa.keys()),
        lostSeconds=sorted(aa[k] for k in aa.keys()-bb.keys()),
        firstTrack=[a['firstTrack'],b['firstTrack']],
        suppressedReplies=[a['suppressedReplies'],b['suppressedReplies']],
        sourceSkips=[a['lateSourceSkips'],b['lateSourceSkips']],
        poseCalls=[a['poseTiming']['calls'],b['poseTiming']['calls']],
        latencyP95=[a['latencyP95Ms'],b['latencyP95Ms']])
    pairs.append(pair)
    print(pair)
(BASE/'summary.json').write_text(json.dumps(dict(runs=rows,pairs=pairs,completedRuns=len(rows)),indent=2)+'\n')
print('Completed',len(rows))
