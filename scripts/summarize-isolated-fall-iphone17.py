#!/usr/bin/env python3
"""Compare observed descent alone, with original contact-window timing in both arms."""
import json
import plistlib
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT/'artifacts/vision-revisions-20261030/fall-amplitude-isolated-iphone17'
OUT = ROOT/'benchmarks/touch-counting/vision-revisions-20261030/fall-amplitude-isolated-iphone17'
NAMES = {'low':'low.mov','clip-a16380ba4a5b':'IMG8606','clip-618a1688fcc6':'IMG8874',
         'clip-89b81fd8bd37':'old three-minute clip'}
TARGETS = [(8.016,'legal low kick'),(42.013,'legal high kick'),(107.910,'legal knee'),
           (125.525,'legal low touch'),(133.258,'legal foot kick'),
           (144.625,'likely legal, clipped'),(145.458,'suspected false, occluded'),
           (153.773,'known ground bounce'),(154.206,'known ground bounce'),(157.807,'known ground bounce')]

def read(path):
    return json.loads(path.read_text())

def unmatched(before,after):
    left,right=set(range(len(before))),set(range(len(after)))
    for _,i,j in sorted((abs(x-y),i,j) for i,x in enumerate(before) for j,y in enumerate(after) if abs(x-y)<=.15):
        if i in left and j in right:
            left.remove(i);right.remove(j)
    return {'addedSeconds':[after[i] for i in sorted(right)],'removedSeconds':[before[i] for i in sorted(left)]}

def main():
    runs=[]
    for path in sorted(BASE.glob('build2026103010/*/iphone17/*/complete.json')):
        folder=path.parent
        run=read(folder/'summary.json')
        run.update(experimentArm=path.parts[-4],repeat=int(folder.name.rsplit('-r',1)[1]),directory=str(folder.relative_to(ROOT)))
        profile=read(folder/'profile.json')
        assert profile['build']=='2026103010'
        assert not profile['visionRevisions']['contactWindowClock']
        assert profile['visionRevisions']['observedFallAmplitude']==(run['experimentArm']=='fall')
        report=read(folder/'report.json')
        run['overflowDrops']=report['overflow_drops']
        run['qualityFailed']=report['quality_failed']
        runs.append(run)
    pairs=[]
    for before in runs:
        if before['experimentArm']!='motion':continue
        after=next((r for r in runs if r['experimentArm']=='fall' and r['clip']==before['clip'] and r['repeat']==before['repeat']),None)
        if after is None:continue
        pa,pb=[read(ROOT/r['directory']/'profile.json') for r in [before,after]]
        # Each launch has a unique verification token, not an analysis option.
        fa,fb=[{f for f in p['effectiveFlags'] if not f.startswith('--workload-audit-')} for p in [pa,pb]]
        assert fb-fa=={'--observed-fall-amplitude-v1'}
        assert not fa-fb
        ca,cb=pa['counterConfig'].copy(),pb['counterConfig'].copy()
        assert ca.pop('usesObservedFallAmplitude',None)!=True and cb.pop('usesObservedFallAmplitude',None)==True
        assert ca==cb
        pair={'clip':before['clip'],'repeat':before['repeat'],'onlyCountingOptionChanged':True,
              'before':before,'after':after,**unmatched(before['countTimes'],after['countTimes'])}
        if 'missedLegalSeconds' in before and 'missedLegalSeconds' in after:
            pair['gainedLegalSeconds']=sorted(set(before['missedLegalSeconds'])-set(after['missedLegalSeconds']))
            pair['lostLegalSeconds']=sorted(set(after['missedLegalSeconds'])-set(before['missedLegalSeconds']))
        if before['clip']=='clip-89b81fd8bd37':
            pair['reviewedTargets']=[{'seconds':t,'label':label,
                'before':[s for s in before['countTimes'] if abs(s-t)<=.15],
                'after':[s for s in after['countTimes'] if abs(s-t)<=.15]} for t,label in TARGETS]
        pairs.append(pair)
    paths=[str(ROOT/r['directory']/'counter.plist') for r in runs if r['experimentArm']=='fall']
    ablation=[]
    if paths:
        result=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'observed-fall-ablation',*paths],
            capture_output=True,text=True,check=True)
        (BASE/'ablation.jsonl').write_text(result.stdout)
        ablation=[json.loads(line) for line in result.stdout.splitlines()]
        assert all(r['baseExact'] and not r['baseMissingCallbacks'] for r in ablation)
    expected=[('low',1),('low',2)]+[(c,1) for c in ['clip-89b81fd8bd37','clip-a16380ba4a5b',
        'clip-618a1688fcc6','ball_in_hand','dribbling_with_the_ball_1']]
    pending=[(c,n) for c,n in expected if not any(p['clip']==c and p['repeat']==n for p in pairs)]
    restore=read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None
    summary={'date':'2026-10-30','defaultChanged':False,'promoted':False,'runs':runs,'pairs':pairs,
             'ablation':ablation,'pendingPairs':pending,'restore':restore,
             'recoveredTargets':read(BASE/'recovered-low-targets.json') if (BASE/'recovered-low-targets.json').exists() else None,
             'threeMinuteVisualReview':read(BASE/'three-minute-changed-contacts.json') if (BASE/'three-minute-changed-contacts.json').exists() else None}
    OUT.mkdir(parents=True,exist_ok=True)
    (OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    report=['Observed fall amplitude alone — iPhone 17 Pro Max — 30 October 2026','',
        'Both arms: build 2026103010, Swift body-pose revision 2, startup motion gate V3, original repair clock.',
        'The only changed counting option is --observed-fall-amplitude-v1. Profile flags and config equality',
        'are checked for every completed pair. No counting source or app defaults were changed this session.',
        'This is an isolated experiment, not a main-app/TestFlight release comparison.','',
        'Fresh original-paced comparisons']
    for p in pairs:
        a,b=p['before'],p['after']
        report.append(f"- {NAMES.get(p['clip'],p['clip'])}, repeat {p['repeat']}: total {a['count']} -> {b['count']}; "
            f"legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; "
            f"known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        if 'gainedLegalSeconds' in p:
            report.append(f"  Gained legal: {p['gainedLegalSeconds']}; lost legal: {p['lostLegalSeconds']}.")
        else:report.append(f"  Unmatched added: {p['addedSeconds']}; removed: {p['removedSeconds']} (150 ms matching).")
        for t in p.get('reviewedTargets',[]):
            report.append(f"  {t['seconds']:.3f} {t['label']}: {t['before']} -> {t['after']}.")
    report += ['', 'Exact saved-input ablations']
    for a in ablation:
        added=sorted(set(a['baseMs'])-set(a['changedMs']))
        removed=sorted(set(a['changedMs'])-set(a['baseMs']))
        report.append(f"- {Path(a['path']).parent.name}: recorded replay exact; proof adds {added} ms, removes {removed} ms.")
        if a['changedMissingCallbacks']:
            report.append(f"  INCOMPLETE counterfactual callbacks: {a['changedMissingCallbacks']}. These differences alone are not proven recovery.")
    if runs:
        report += ['', 'Performance',f"- {len(runs)} completed runs. Thermal states: {sorted({r['worstThermal'] for r in runs})}; 0=nominal.",
            f"- Source skips: {sum(r['lateSourceSkips'] for r in runs)}; overflow drops: {sum(r['overflowDrops'] for r in runs)}.",
            f"- Median notification latency: {min(r['latencyMedianMs'] for r in runs):.1f}–{max(r['latencyMedianMs'] for r in runs):.1f} ms; "
            f"p95: {min(r['latencyP95Ms'] for r in runs):.1f}–{max(r['latencyP95Ms'] for r in runs):.1f} ms."]
    report += ['', 'Limits',
        '- low.mov uses 195 reviewed legal labels with uncertainty; IMG8606 has 39 partial legal labels.',
        '- The three-minute clip has only selected reviewed targets. Extra counts are not automatically legal.',
        '- Exact numeric replay does not rerun tracking or pose. Missing callbacks stay explicitly unproven.',
        '- These iPhone 17 clips do not establish iPhone 11 or long-session performance.','',
        f'Pending pairs: {pending or "none"}.',
        'Field build 2026102913 and 24-touch IMG8874 preview restored and verified.' if restore else 'Field build restoration is not yet verified.',
        'No promotion, commit, push, main-app default change or TestFlight upload.']
    conclusion=BASE/'conclusion.txt'
    if conclusion.exists():report+=['',conclusion.read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(report)+'\n')
    print(f'Saved {len(runs)} runs, {len(pairs)} complete pairs; pending {pending}.')

if __name__=='__main__':main()
