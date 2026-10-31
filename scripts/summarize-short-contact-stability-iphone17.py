#!/usr/bin/env python3
"""Report completed runs only; keep fresh-pipeline and saved-input results separate."""
import hashlib
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'artifacts/vision-revisions-20261030/short-contact-stability-iphone17'
OUT = ROOT/'benchmarks/touch-counting/vision-revisions-20261030/short-contact-stability-iphone17'
NAMES = {'low': 'low.mov', 'clip-618a1688fcc6': 'IMG8874',
         'clip-a16380ba4a5b': 'IMG8606', 'clip-89b81fd8bd37': 'old three-minute clip'}
TARGETS = [(8.016,'legal low kick'),(42.013,'legal high kick'),(107.910,'legal knee contact'),
           (125.525,'legal low touch'),(153.773,'ground bounce'),(154.206,'ground bounce'),
           (157.807,'ground bounce')]

def read(path):
    return json.loads(path.read_text())

def lines(path):
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []

def summarize():
    runs = []
    for path in sorted(BASE.glob('build*/*/iphone17/*/summary.json')):
        if not (path.parent/'complete.json').exists():
            continue
        value = read(path)
        value['experimentArm'] = path.parts[-4]
        value['repeat'] = int(path.parent.name.rsplit('-r', 1)[1])
        value['directory'] = str(path.parent.relative_to(ROOT))
        report = read(path.parent/'report.json')
        value['overflowDrops'] = report['overflow_drops']
        value['qualityFailed'] = report['quality_failed']
        runs.append(value)
    pairs = []
    for build, control, candidate in [('2026103009','motion','clock'), ('2026103010','clock','observed'),
                                      ('2026103010','motion','observed')]:
        for before in runs:
            if before['build'] != build or before['experimentArm'] != control:
                continue
            after = next((r for r in runs if r['build'] == build and r['experimentArm'] == candidate
                          and r['clip'] == before['clip'] and r['repeat'] == before['repeat']), None)
            if after is None:
                continue
            pairs.append({'build':build, 'clip':before['clip'], 'repeat':before['repeat'],
                'control':control, 'candidate':candidate, 'beforeCount':before['count'], 'afterCount':after['count'],
                'beforeLegal':before.get('acceptedValid'), 'afterLegal':after.get('acceptedValid'),
                'beforeKnownFalse':before.get('knownFalse'), 'afterKnownFalse':after.get('knownFalse'),
                'gainedLegalSeconds':sorted(set(before.get('missedLegalSeconds',[]))-set(after.get('missedLegalSeconds',[]))),
                'lostLegalSeconds':sorted(set(after.get('missedLegalSeconds',[]))-set(before.get('missedLegalSeconds',[]))),
                'controlDirectory':before['directory'], 'candidateDirectory':after['directory']})
    old_ground = []
    for row in lines(BASE/'old-ground-screen.jsonl'):
        old_ground.append({'path':row['path'], 'baseExact':row['baseExact'],
            'sameTouches':row['baseMs'] == row['changedMs'], 'eligible':row['eligible'],
            'missingCallbacks':row['changedMissingCallbacks'],
            'groundTargets':{str(t):[m for m in row['changedMs'] if abs(m/1000-t)<=.2]
                             for t in [153.773,154.206,157.807]}})
    proof = []
    for run in runs:
        if run['experimentArm'] != 'observed':
            continue
        trace = plistlib.load((ROOT/run['directory']/'counter.plist').open('rb'))
        for event in trace['decisions']:
            d = event['value']
            if d.get('observedFall', -1) >= d.get('requiredFall', float('inf')):
                proof.append({'directory':run['directory'], **{k:d.get(k) for k in
                    ['timestampMs','rejection','fall','observedFall','requiredFall','bodyContactAllowed',
                     'handRejected','handlingChecked','footConfirmed']}})
    fresh_targets = []
    for run in runs:
        if run['clip'] != 'clip-89b81fd8bd37':
            continue
        trace = plistlib.load((ROOT/run['directory']/'counter.plist').open('rb'))
        fresh_targets.append({'arm':run['experimentArm'], 'directory':run['directory'], 'targets':[
            {'seconds':seconds, 'label':label,
             'acceptedNearby':[t for t in run['countTimes'] if abs(t-seconds)<=.2],
             'decisions':[{k:e['value'].get(k) for k in ['timestampMs','rejection','observedFall',
                 'bodyContactAllowed','footConfirmed']} for e in trace['decisions']
                 if abs(e['value']['timestampMs']/1000-seconds)<=.2]}
            for seconds,label in TARGETS]})
    expected = [(c,a,2) for c in ['low','clip-a16380ba4a5b'] for a in ['observed','clock']]
    expected += [(c,a,1) for c in ['clip-89b81fd8bd37','dribbling_with_ball_1',
                 'dribbling_with_ball_2','dribbling_with_ball_3'] for a in ['motion','observed']]
    pending = [item for item in expected if not any(r['build']=='2026103010' and
        (r['clip'],r['experimentArm'],r['repeat'])==item for r in runs)]
    sources = ['kicklab/Counting/ObservedFallAmplitude.swift','kicklab/Counting/TouchCounter.swift',
        'kicklab/Counting/ContactCounterFactory.swift','kicklab/Detection/ContactWindowClock.swift',
        'kicklab/Detection/RFBufferedLivePipeline.swift','kicklab/Detection/LiveJugglingAnalysis.swift',
        'kicklab/Detection/VisionRevisionExperiment.swift','kicklab/Effects/SessionAnalysisStore.swift']
    summary = {'date':'2026-10-30', 'promoted':False, 'defaultChanged':False,
        'runs':runs, 'pairs':pairs, 'observedProofDecisions':proof,
        'savedInputScreen':lines(BASE/'observed-fall-screen.jsonl'),
        'ablation':lines(BASE/'observed-fall-ablation.jsonl'), 'oldGroundSavedInput':old_ground,
        'oldGroundFreshTargets':fresh_targets, 'pendingComparisons':pending,
        'freshVisualReview':read(BASE/'three-minute-fresh-differences.json')
            if (BASE/'three-minute-fresh-differences.json').exists() else None,
        'restore':read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None,
        'sourceSHA256':{s:hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources}}
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    report = [
        'Short contact stability — iPhone 17 Pro Max — 30 October 2026', '',
        'Status: experimental, NOT promoted. Both new flags remain off by default.',
        'Build 2026103009 isolates the contact-window clock. Build 2026103010 adds observed fall amplitude.',
        'Every fresh arm uses Swift body-pose revision 2 and the same experimental startup motion gate V3.',
        'These comparisons are NOT a comparison against the ordinary field app or TestFlight.', '',
        'What changed',
        '1. Contact-window clock: a repair window may borrow at most one 30 FPS frame of wall-clock time.',
        '   The debt is repaid at the next slot. The 300 ms source interval, sustained wall rate,',
        '   per-image age, identity, worker-idle and backlog guards remain.',
        '2. Observed fall: an existing candidate may use its actual continuous ball descent to meet',
        '   the unchanged fall threshold when smoothing flattens it. At least five consecutive,',
        '   confident, fully visible observations must resolve both sides of the turn.',
        '   Explicit foot-proof routes and later body, hand, ground and holding vetoes still apply.',
        '   This does not create candidates for kicks that never produced a proposal.', '',
        'Fresh original-paced comparisons (completed pairs only)',
    ]
    for p in pairs:
        detail = (f"legal {p['beforeLegal']} -> {p['afterLegal']}; known false {p['beforeKnownFalse']} -> {p['afterKnownFalse']}"
                  if p['beforeLegal'] is not None else
                  f"total {p['beforeCount']} -> {p['afterCount']}; no complete legal/false labels")
        report.append(f"- {NAMES.get(p['clip'],p['clip'])}, build {p['build']}, repeat {p['repeat']}: "
                      f"{p['control']} -> {p['candidate']}; {detail}.")
        if p['gainedLegalSeconds'] or p['lostLegalSeconds']:
            report.append(f"  Gained labelled contacts: {p['gainedLegalSeconds']}; lost: {p['lostLegalSeconds']}.")
    report += ['',
        'Label caveat: low.mov has 195 reviewed legal contacts with reference uncertainty. IMG8606',
        'has partial labels (39 legal contacts). A known-false count is not a comprehensive false-positive',
        'rate; unreviewed events cannot be assumed correct. Old three-minute targets are partial coverage.', '',
        'What the evidence establishes',
        '- At 23.1 s, the old 300 ms wall guard can reject a repair despite 334 ms between source contacts.',
        '  Fresh audit logged about 293 ms wall spacing: legacyAllowed=false, bounded clock allowed=true.',
        '  Build09 repeat2 recovered the labelled 23.11 s contact, but lost 54.08 s elsewhere (166 ->166).',
        '- At 28 s in the earlier missed trace, smoothed fall is .00746824 versus required .00749512.',
        '  A continuous measured descent is .01918850. The new helper qualifies this existing candidate,',
        '  but old rejected traces lack downstream callbacks, so that offline eligibility alone is not',
        '  proof of a recovered live count. The first build10 pair counts this target in both arms.',
        '- The first build10 candidate run records accepted observed-fall proofs at 9.500 and 18.066 s',
        '  (labelled legal contacts 9.56 and 18.13). Same-input ablation removes both; however the',
        '  disabled 9.500 s path requests one unrecorded foot callback, so its counterfactual is incomplete.',
        '  The 18.066 s ablation does not have that missing-callback limitation.',
        '- IMG8606 lost labelled contacts 16.808 and 18.25 s in the first fresh pair. Both became body',
        '  rejections with different ball samples and proposal times. No observed-fall proof qualified',
        '  anywhere in this clip. Turning that proof off on the exact captured inputs yields the same',
        '  35 touches with no missing callbacks. This excludes a direct numeric-rule regression on those',
        '  inputs, but does not establish end-to-end stability. In the reverse-order pair, legal counts',
        '  were 32 ->33. Both arms counted 16.8 s and rejected 18.25 s as missingPose. The candidate',
        '  repeated with no observed-fall eligibility; same-input ablation again changes no counts.',
        '  This is variable upstream sampling/pose evidence, not a repeatable direct amplitude-rule loss.',
        '- The 37.43 s low contact has two original missing impact exposures in earlier failed runs',
        '  and weak ankle estimates. Successful image repairs do not establish foot contact. Its',
        '  acceptance varies between fresh captures. The positive-foot requirement was not weakened.',
        '- The 4.67 s low kick remains outside this change: in a missed capture no candidate is created.', '',
        'Offline scope and checks',
        '- 47 saved traces reproduced their recorded default counts exactly. Observed-fall eligibility',
        '  appears only in five low.mov traces; newly reached missing callbacks are reported explicitly.',
        '- Two saved old-three-minute traces remain exactly 158 and 160 touches. The proof has no eligible',
        '  candidate there. All three known ground targets (153.773,154.206,157.807 s) stay uncounted.',
        '  These are numeric checks on saved inputs; they do not test fresh timing or the new clock.',
        '- Clock contracts: 3016 passed in DEBUG and 3016 in release; observed-fall contracts: 21 passed.',
        '- Both debug builds compiled successfully. Python compilation and git diff whitespace checks pass.', '',
        'Performance of completed runs',
        f"- {len(runs)} completed runs; thermal states: {sorted({r['worstThermal'] for r in runs})} (0=nominal).",
        f"- Source skips: {sum(r['lateSourceSkips'] for r in runs)}; overflow drops: {sum(r['overflowDrops'] for r in runs)}.",
        f"- Median notification latency range: {min(r['latencyMedianMs'] for r in runs):.1f}–{max(r['latencyMedianMs'] for r in runs):.1f} ms; "
        f"p95 range: {min(r['latencyP95Ms'] for r in runs):.1f}–{max(r['latencyP95Ms'] for r in runs):.1f} ms.",
        '  This small iPhone 17 sample does not establish iPhone 11 or long-session performance.', '',
    ]
    report += ['Fresh old-three-minute targets (partial coverage)']
    for run in fresh_targets:
        report.append(f"- {run['arm']}: "+'; '.join(
            f"{t['seconds']:.3f} {t['label']}: {t['acceptedNearby']}" for t in run['targets']))
    visual = summary['freshVisualReview']
    if visual:
        report += ['', 'Review of changed three-minute counts']
        for item in visual['items']:
            report.append(f"- {item['seconds']:.3f} s ({item['direction']}): {item['visualAssessment']} "
                          f"[confidence: {item['confidence']}].")
        report += [
            '- The 157 ->159 total is three added counts and one lost count, not two proven legal gains.',
            '- The clear added kick is at 133.258 s. The edge-of-frame gain at 92.776 s and loss at',
            '  144.625 s are likely legal but partly clipped; they remain qualified assessments.',
            '- At 145.458 s the control breaks tracking. The candidate accepts on different tracking samples;',
            '  the observed-fall rule does not qualify. The video shows a bouncing ball while the player',
            '  walks away, with the exact impact obscured. Treat this as a suspected false count pending',
            '  confirmation, never as a recovered legal touch.',
            '- At 154.206 s both arms accept the already reviewed ground bounce. In the control evidence,',
            '  the lower ball edge is above the estimated floor threshold, and the ball center is only about',
            '  0.05 ball heights below the lowest ankle, short of the unlifted-floor proof\'s 0.1 margin.',
            '  This fresh-pose/geometry result differs from the older saved traces that rejected it.',
            '- Turning observed-fall off on the new three-minute trace gives the identical 159 touches',
            '  with complete callbacks. This excludes a direct numeric change by that proof, but the',
            '  combined clock/repair/tracking change has not passed the broader regression check.',
        ]
    report += ['', 'Resumed session status',
               f'- Pending comparisons: {pending or "none"}.']
    restored = summary['restore']
    report.append('- Field build 2026102913 restored; 24-touch IMG8874 preview verified; experimental flags absent.'
                  if restored else '- Field build restore has NOT been verified yet.')
    if not pending and restored:
        report += ['', 'Decision and next priority',
            '- Keep the combined experiment off. Two low.mov pairs both gain three net legal contacts;',
            '  the second pair loses none. All five holding/dribbling controls remain zero.',
            '- The new fall measurement is promising. Next isolate it with the old clock, so contact',
            '  repair scheduling is held constant. Do not promote the entire combined pipeline based',
            '  on net totals while the three-minute suspicious count and clipped legal loss remain.',
            '- Preserve 145.458 and 154.206 s as regression targets for impact timing and floor evidence.',
            '  The unproposed 4.67 s low kick is still a separate candidate-generation problem.',
        ]
    report += ['', 'No commits, pushes, main-app default changes, or TestFlight upload were made by this experiment.',
               'Full run paths, gains/losses, source hashes and restore state: summary.json.']
    (OUT/'RESULTS.txt').write_text('\n'.join(report)+'\n')
    print(f'Saved {len(runs)} completed runs / {len(pairs)} pairs to {OUT}')

if __name__ == '__main__':
    summarize()
