#!/usr/bin/env python3
"""Separate the recent-floor rule's exact-input effects from fresh inference variation."""
import hashlib,json,plistlib,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/ground-impact-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/ground-impact-iphone17'
def read(p):return json.loads(p.read_text())
def main():
    runs=[]
    for p in sorted(BASE.glob('build20261030*/*/iphone17/*/complete.json')):
        s=read(p.parent/'summary.json');r=read(p.parent/'report.json')
        t=plistlib.load((p.parent/'counter.plist').open('rb'))
        s.update(experimentArm=p.parts[-4],repeat=int(p.parent.name.rsplit('-r',1)[1]),
            directory=str(p.parent.relative_to(ROOT)),overflowDrops=r['overflow_drops'],
            newFloorDecisions=[{'ms':d['value']['timestampMs'],'previousMs':d['value']['recentFloorReferenceMs'],
                'rejection':d['value'].get('rejection')} for d in t['decisions'] if 'recentFloorReferenceMs'in d['value']])
        runs.append(s)
    pairs=[]
    for a in runs:
        if a['experimentArm']!='control':continue
        b=next((r for r in runs if r['experimentArm']=='floor' and r['build']==a['build'] and r['clip']==a['clip'] and r['repeat']==a['repeat']),None)
        if b is None:continue
        pa,pb=[read(ROOT/r['directory']/'profile.json') for r in [a,b]]
        fa,fb=[{f for f in p['effectiveFlags'] if not f.startswith('--workload-audit-')} for p in [pa,pb]]
        assert fb-fa=={'--recent-measured-floor-v1'} and not fa-fb
        ca,cb=[p['counterConfig'].copy() for p in [pa,pb]]
        assert ca.pop('rejectsReboundNearRecentFloor',None)!=True and cb.pop('rejectsReboundNearRecentFloor',None)==True
        assert ca==cb
        pair={'clip':a['clip'],'repeat':a['repeat'],'before':a,'after':b,'onlyGroundProofChanged':True}
        if 'missedLegalSeconds'in a:
            pair.update(gainedLegalSeconds=sorted(set(a['missedLegalSeconds'])-set(b['missedLegalSeconds'])),
                lostLegalSeconds=sorted(set(b['missedLegalSeconds'])-set(a['missedLegalSeconds'])))
        if a['clip']=='clip-89b81fd8bd37':
            pair['reviewedTargets']={str(t):{arm:[x for x in r['countTimes'] if abs(x-t)<=.15]
                for arm,r in [('before',a),('after',b)]} for t in [8.016,42.013,107.91,125.525,145.458,153.773,154.206,157.807]}
            pair['unmatchedNewTimes']=[x for x in b['countTimes'] if all(abs(x-y)>.15 for y in a['countTimes'])]
            pair['unmatchedOldTimes']=[x for x in a['countTimes'] if all(abs(x-y)>.15 for y in b['countTimes'])]
        pairs.append(pair)
    paths=[str(ROOT/r['directory']/'counter.plist') for r in runs if r['experimentArm']=='control']
    forward=[]
    if paths:
        r=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'recent-floor-screen',*paths],capture_output=True,text=True,check=True)
        (BASE/'phone-control-forward.jsonl').write_text(r.stdout)
        forward=[json.loads(x) for x in r.stdout.splitlines()]
        assert all(x['baseExact'] and not x['baseMissingCallbacks'] and not x['changedMissingCallbacks'] for x in forward)
    screen=[json.loads(x)for x in (BASE/'screen.jsonl').read_text().splitlines()]
    sources=['kicklab/Counting/MeasuredFootImpactRules.swift','kicklab/Counting/TouchCounter.swift',
        'kicklab/Counting/ContactCounterFactory.swift','kicklab/Detection/VisionRevisionExperiment.swift',
        'kicklab/Effects/SessionAnalysisStore.swift']
    s={'date':'2026-10-30','builds':['2026103014','2026103015'],'defaultChanged':False,'promoted':False,'runs':runs,'pairs':pairs,
       'screen':screen,'finalRuleScreen':[json.loads(x) for x in (BASE/'final-rule-screen.jsonl').read_text().splitlines()],'forward':forward,'sourceSHA256Build14':read(BASE/'build14-source-sha256.json'),
       'sourceSHA256Build15':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
       'interruptedAttempts':[str(p.relative_to(ROOT)) for p in BASE.glob('interrupted-*/**/failed.json')],
       'restore':read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None}
    OUT.mkdir(parents=True,exist_ok=True);(OUT/'summary.json').write_text(json.dumps(s,indent=2)+'\n')
    lines=['Recent measured floor — iPhone 17 — 30 October 2026','',
        'Target: the reviewed false ground bounce at 154.206 s in the old three-minute outdoor clip.',
        'The ordinary body-box floor is too low and the ball barely crosses the support-ankle line.',
        'The existing descending-foot floor proof therefore remains inconclusive, and no foot proof is requested.',
        'The first bounce at 153.773 s is independently confirmed by the existing unlifted-foot proof.','',
        'Opt-in --recent-measured-floor-v1 uses that proven floor for at most 600 ms. It requires two adjacent',
        'low-ball views to bound the reference, nearby stable support, consistent ball size/location,',
        'a complete observed rebound and a descending nearest ankle. A successful intervening kick,',
        'tracking discontinuity or expired reference prevents reuse. A new rejection cannot extend its own reference.',
        'No clip name or absolute timestamp is used. No new Vision request, input crop, frame rate or model is added.',
        'Both phone arms retain revision 2, startup gate V3, observed-fall and short-kick recovery, and the old contact clock.',
        'Build 2026103015 tightens expiry: the new route always requires a matched recent reference, even for',
        'a shape that an independent deep-floor rule could classify. Existing floor classification is unchanged.','',
        f'Saved input screen: {len(screen)} exact baselines; {sum(bool(x["hits"]) for x in screen)} target-only changes.',
        f"Final-rule compatibility screen: {len(s['finalRuleScreen'])} saved traces replay exactly; no changed counts outside the target.",
        'The original single-edge prototype missed older captures because the detected lower edge jumped.',
        'The final two-view range catches the target in all six historical captures without changing other counts.',
        (BASE/'contracts-final.txt').read_text().strip(),'','Fresh phone comparisons']
    for p in pairs:
        a,b=p['before'],p['after']
        lines.append(f"- build {a['build']} {p['clip']} r{p['repeat']}: total {a['count']} -> {b['count']}; labelled legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        if 'gainedLegalSeconds'in p:lines.append(f"  Gained legal {p['gainedLegalSeconds']}; lost legal {p['lostLegalSeconds']}.")
        if 'reviewedTargets'in p:
            lines.append('  Reviewed targets: '+json.dumps(p['reviewedTargets']))
            lines.append(f"  Unmatched fresh times: new {p['unmatchedNewTimes']}; old {p['unmatchedOldTimes']}.")
    for r in runs:
        if r['experimentArm']=='floor':lines.append(f"  New proof build {r['build']} {r['clip']} r{r['repeat']}: {r['newFloorDecisions']}")
    lines+=['','Exact-input forward checks on fresh controls']
    for x in forward:lines.append(f"- {Path(x['path']).parent.name}: removed {sorted(set(x['baseMs'])-set(x['changedMs']))}; added {sorted(set(x['changedMs'])-set(x['baseMs']))}; missing callbacks {x['changedMissingCallbacks']}.")
    if runs:lines+=['',f"{len(runs)} complete runs, thermal states {sorted({r['worstThermal'] for r in runs})} (0=nominal), source skips {sum(r['lateSourceSkips'] for r in runs)}, overflow {sum(r['overflowDrops'] for r in runs)}."]
    lines+=['','Field build restored and verified.' if s['restore'] else 'Field restoration pending.',
        'One final control attempt was interrupted by AVFoundation (-11847); its files are preserved separately and it was retried.',
        'Incomplete runs are excluded. Selected targets are not a full manual recount of the three-minute clip.',
        'No default change, commit, push or TestFlight upload.']
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines)+'\n');print('Saved',len(runs),'runs and',len(pairs),'pairs.')
if __name__=='__main__':main()
