#!/usr/bin/env python3
"""Report bounded short-rise proposals separately from fresh tracking variation."""
import hashlib
import json
import plistlib
import subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/short-rise-candidate-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/short-rise-candidate-iphone17'

def read(p):return json.loads(p.read_text())

def main():
    runs=[]
    for p in sorted(BASE.glob('build20261030*/*/iphone17/*/complete.json')):
        s=read(p.parent/'summary.json');report=read(p.parent/'report.json')
        s.update(experimentArm=p.parts[-4],repeat=int(p.parent.name.rsplit('-r',1)[1]),
                 directory=str(p.parent.relative_to(ROOT)),overflowDrops=report['overflow_drops'])
        runs.append(s)
    pairs=[]
    for a in runs:
        if a['experimentArm']!='fall':continue
        b=next((r for r in runs if r['experimentArm'] in ['short','shortfoot'] and r['build']==a['build'] and r['clip']==a['clip'] and r['repeat']==a['repeat']),None)
        if b is None:continue
        pa,pb=[read(ROOT/r['directory']/'profile.json') for r in [a,b]]
        fa,fb=[{f for f in p['effectiveFlags'] if not f.startswith('--workload-audit-')} for p in [pa,pb]]
        expected={'--observed-short-rise-v1'} | ({'--observed-plateau-foot-v1'} if b['experimentArm']=='shortfoot' else set())
        assert fb-fa==expected and not fa-fb
        ca,cb=[p['counterConfig'].copy() for p in [pa,pb]]
        assert ca.pop('recoversObservedShortRise',None)!=True and cb.pop('recoversObservedShortRise',None)==True
        assert ca.pop('confirmsObservedPlateauFoot',None)!=True
        assert (cb.pop('confirmsObservedPlateauFoot',None)==True)==(b['experimentArm']=='shortfoot')
        assert ca==cb and not pa['visionRevisions']['contactWindowClock'] and not pb['visionRevisions']['contactWindowClock']
        pair={'clip':a['clip'],'repeat':a['repeat'],'before':a,'after':b,'onlyShortRecoveryChanged':True}
        if 'missedLegalSeconds' in a:
            pair.update(gainedLegalSeconds=sorted(set(a['missedLegalSeconds'])-set(b['missedLegalSeconds'])),
                        lostLegalSeconds=sorted(set(b['missedLegalSeconds'])-set(a['missedLegalSeconds'])))
        if a['clip']=='clip-89b81fd8bd37':
            pair['reviewedTargets']={str(t):{'before':[x for x in a['countTimes'] if abs(x-t)<=.15],
                                          'after':[x for x in b['countTimes'] if abs(x-t)<=.15]}
                for t in [8.016,42.013,107.91,125.525,145.458,153.773,154.206,157.807]}
        pairs.append(pair)
    paths=[str(ROOT/r['directory']/'counter.plist') for r in runs if r['experimentArm'] in ['short','shortfoot']]
    ablation=[]
    if paths:
        result=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'short-rise-ablation',*paths],
            capture_output=True,text=True,check=True)
        (BASE/'ablation.jsonl').write_text(result.stdout)
        ablation=[json.loads(x) for x in result.stdout.splitlines()]
        assert all(x['baseExact'] and not x['baseMissingCallbacks'] for x in ablation)
    screen=[json.loads(x) for x in (BASE/'screen.jsonl').read_text().splitlines()]
    sources=['kicklab/Counting/ObservedFallAmplitude.swift','kicklab/Counting/TouchCounter.swift',
        'kicklab/Counting/ContactCounterFactory.swift','kicklab/Counting/ShallowLateralContactRules.swift',
        'kicklab/Detection/VisionRevisionExperiment.swift',
        'kicklab/Effects/SessionAnalysisStore.swift']
    foot_ablation=[]
    foot_paths=[str(ROOT/r['directory']/'counter.plist') for r in runs if r['experimentArm']=='shortfoot']
    if foot_paths:
        f=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'short-foot-ablation',*foot_paths],capture_output=True,text=True,check=True)
        (BASE/'foot-ablation.jsonl').write_text(f.stdout)
        foot_ablation=[json.loads(x) for x in f.stdout.splitlines()]
        assert all(x['baseExact'] and not x['baseMissingCallbacks'] for x in foot_ablation)
    s={'date':'2026-10-30','builds':['2026103012','2026103013'],'defaultChanged':False,'promoted':False,'runs':runs,'pairs':pairs,
       'ablation':ablation,'footAblation':foot_ablation,'screen':screen,'footScreen':[json.loads(x) for x in (BASE/('foot-screen-final.jsonl' if (BASE/'foot-screen-final.jsonl').exists() else 'foot-screen.jsonl')).read_text().splitlines()],
       'footShapeScreen':[json.loads(x) for x in (BASE/'foot-shape-screen.jsonl').read_text().splitlines()],'restore':read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None,
       'sourceSHA256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources}}
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'summary.json').write_text(json.dumps(s,indent=2)+'\n')
    lines=['Measured short-rise candidate — iPhone 17 — 30 October 2026','',
        'Build 2026103012. Both arms retain startup gate V3, revision2, the observed-fall improvement',
        'and the ORIGINAL contact-window clock. Only --observed-short-rise-v1 differs. Defaults unchanged.',
        'Build 2026103013 also tests --observed-plateau-foot-v1: the same measured turn must match',
        'the foot evidence. A resolved lateral swing and separation, reliable four-view pose, and',
        'whole-ball clearance above the support ankle are mandatory. All floor vetoes remain.',
        'Build 2026103011 was compiled but never installed: its early version proposed 17 extra checks',
        'in low.mov. The tested build waits until confirmed upward motion slows to neutral, so ordinary',
        'rising candidates retain their established timing.','',
        'The missed 4.67-second kick has a real, fully visible rebound. Smoothing makes its rise less',
        'than 0.007 and its impulse less than the early-probe threshold 0.4. The opt-in path requires',
        'a continuous measured turn meeting the UNCHANGED ordinary fall, rise and impulse thresholds;',
        'it only requests positive foot evidence. Ground, body, hand, holding and cooldown checks remain.',
        'No timestamp, clip identity, model change or relaxed foot distance is used.','',
        f'Offline: {len(screen)} pre-experiment traces replay exactly. Only low.mov at 4633 ms gains proposal eligibility.',
        f"Combined screen: {len(s['footScreen'])} saved traces; exact baselines {sum(x['baseExact'] for x in s['footScreen'])}.",
        f"Foot-shape audit: {sum(x['footEvidenceChecked'] for x in s['footShapeScreen'])} evidence records across repeated traces; {sum(len(x['hits']) for x in s['footShapeScreen'])} matches, all at the target contact.",
        'Old traces lack the foot callback for that new proposal: offline eligibility is not a recovered count.',
        '20 short-rise contracts, 21 existing-fall contracts and 17 existing lateral contracts passed. The plateau-foot checks passed 18 contracts, including a saved positive floor veto. Builds compiled.','',
        'Fresh comparisons']
    for p in pairs:
        a,b=p['before'],p['after']
        lines.append(f"- build {a['build']} {p['clip']} r{p['repeat']}: total {a['count']} -> {b['count']}; legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        if 'gainedLegalSeconds' in p:lines.append(f"  Gained legal: {p['gainedLegalSeconds']}; lost legal: {p['lostLegalSeconds']}.")
        if 'reviewedTargets' in p:lines.append('  Selected targets only: '+json.dumps(p['reviewedTargets']))
    lines+=['','Exact-input ablation (the causal comparison; fresh runs can differ upstream)']
    for a in ablation:
        lines.append(f"- {Path(a['path']).parent.name}: enabled {len(a['baseMs'])}; disabled {len(a['changedMs'])}; eligible {a['eligible']}; missing callbacks {a['changedMissingCallbacks']}.")
    if runs:
        lines+=['',f"Completed {len(runs)} runs; thermal states {sorted({r['worstThermal'] for r in runs})} (0=nominal); source skips {sum(r['lateSourceSkips'] for r in runs)}; overflow {sum(r['overflowDrops'] for r in runs)}."]
    lines+=['','Two incomplete three-minute attempts produced no completed result and timed out; excluded from accuracy totals.',
        'Field build restored and verified.' if s['restore'] else 'Field build restoration not yet verified.',
        'No commit, push or TestFlight upload. This is not a full-corpus recall or live-camera accuracy claim.']
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines)+'\n');print(f'Saved {len(runs)} runs / {len(pairs)} pairs.')

if __name__=='__main__':main()
