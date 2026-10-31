#!/usr/bin/env python3
"""Keep fresh tracking variation separate from fixed-input contact recovery."""
import json, plistlib, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/low-contact-robustness-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/low-contact-robustness-iphone17'


def read(p):return json.loads(p.read_text())


def ablate(path):
    result={}
    for command in ['directed-foot-ablation','unarmed-turn-ablation','low-robustness-ablation']:
        r=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),command,str(path)],
                         capture_output=True,text=True,check=True)
        row=json.loads(r.stdout)
        assert row['baseExact'] and not row['baseMissingCallbacks']
        result[command]=dict(removedMs=sorted(set(row['baseMs'])-set(row['changedMs'])),
                            addedMs=sorted(set(row['changedMs'])-set(row['baseMs'])),
                            missingCallbacks=row['changedMissingCallbacks'])
    return result


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    runs=[]
    for p in sorted(BASE.glob('build2026103016/*/iphone17/*/complete.json')):
        s=read(p.parent/'summary.json');r=read(p.parent/'report.json')
        s.update(experimentArm=p.parts[-4],repeat=int(p.parent.name.rsplit('-r',1)[1]),
                 directory=str(p.parent.relative_to(ROOT)),overflow=r['overflow_drops'])
        if s['experimentArm']=='both':s['ablation']=ablate(p.parent/'counter.plist')
        runs.append(s)
    pairs=[]
    for a in runs:
        if a['experimentArm']!='control':continue
        b=next((r for r in runs if r['experimentArm']=='both' and r['clip']==a['clip'] and r['repeat']==a['repeat']),None)
        if b is None:continue
        assert a['sourceSHA256']==b['sourceSHA256']
        profiles=[read(ROOT/r['directory']/'profile.json') for r in [a,b]]
        configs=[p['counterConfig'].copy() for p in profiles]
        for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:
            assert configs[0].pop(key,None)!=True and configs[1].pop(key,None)==True
        assert configs[0]==configs[1]
        pair=dict(clip=a['clip'],repeat=a['repeat'],before=a,after=b)
        if 'missedLegalSeconds' in a:
            pair.update(gainedLegal=sorted(set(a['missedLegalSeconds'])-set(b['missedLegalSeconds'])),
                        lostLegal=sorted(set(b['missedLegalSeconds'])-set(a['missedLegalSeconds'])))
        if a['clip']=='clip-89b81fd8bd37':
            pair['reviewedTargets']={str(t):{arm:[x for x in r['countTimes'] if abs(x-t)<=.15]
                for arm,r in [('before',a),('after',b)]} for t in [8.016,42.013,107.91,125.525,145.458,153.773,154.206,157.807]}
        pairs.append(pair)
    frozen=None
    folder=BASE/'frozen-build2026103017'
    if (folder/'complete.json').exists():
        frozen=read(folder/'complete.json')
        for pair in frozen['pairs']:
            pair['ablation']=ablate(folder/(pair['clip']+'-after.plist'))
            pair['addedMs']=sorted(set(pair['afterMs'])-set(pair['beforeMs']))
            pair['removedMs']=sorted(set(pair['beforeMs'])-set(pair['afterMs']))
    summary=dict(runs=runs,pairs=pairs,frozen=frozen,defaultsChanged=False,
                 frozenLabels=read(folder/'label-score.json') if (folder/'label-score.json').exists() else None,
                 targetDecisions=read(folder/'target-decisions.json') if (folder/'target-decisions.json').exists() else None,
                 savedTraceScreen=read(BASE/'final-screen-summary.json') if (BASE/'final-screen-summary.json').exists() else None,
                 restore=read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None)
    (OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    lines=['LOW-CONTACT ROBUSTNESS — REVISION 2 / IPHONE17 — 30 OCT 2026','',
        'Scope: explicit debug flags --directed-forefoot-v1 and --observed-unarmed-turn-v1.',
        'Both fresh arms retain revision2, motion gateV3, observed fall/short-rise/plateau-foot,',
        'recent measured floor and the old contact-window clock. Model and regular RF scheduling are unchanged.',
        'No production default, commit, push or TestFlight promotion.','',
        'The foot proof supplements the ordinary ankle circle only for a directed toe swing:',
        'two adjacent ankle-height ball views, moving/lifting foot, stable opposite support,',
        'resolved approach and two release views, confident bounded evidence and no resolved ground proof.',
        'The new candidate route requires a completed continuous observed turn meeting normal fall/rise/impulse',
        'thresholds after upward motion ends. It requires positive foot proof and retains all later vetoes.',
        'No clip identity or absolute time is used in either production rule.','',
        'Initial saved screen:135 exact baseline traces, no previously accepted counts lost.',
        'Foot shape matches only54.033s in three captures. New candidate evidence is needed at12.633s',
        'and58.000s in low.mov. Missing callbacks in old traces are not accepted-count evidence.',
        (BASE/'contracts.txt').read_text().strip(),'','Fresh paced phone runs:']
    for p in pairs:
        a,b=p['before'],p['after']
        lines.append(f"- {p['clip']} r{p['repeat']}: {a['count']} -> {b['count']}; legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        if 'gainedLegal' in p:lines.append(f"  Gained {p['gainedLegal']}; lost {p['lostLegal']}.")
        if 'reviewedTargets' in p:lines.append('  Reviewed targets '+json.dumps(p['reviewedTargets']))
        lines.append('  Same-input ablation '+json.dumps(b['ablation']))
    if runs:lines+=['',f"{len(runs)} completed paced runs; thermal states {sorted({r['worstThermal'] for r in runs})}, source skips {sum(r['lateSourceSkips'] for r in runs)}, overflow {sum(r['overflow'] for r in runs)}.",
        'Raw-juggling skipped three source frames per arm; old3min skipped one per arm; IMG8606 skipped one in the improved arm.',
        'All other tested runs had zero skipped source frames. Nominal temperature and zero overflow do not mean zero omissions.']
    lines+=['','Frozen tracked-input comparison:']
    if frozen:
        for p in frozen['pairs']:
            lines.append(f"- {p['clip']}: {p['before']} -> {p['after']}; added {p['addedMs']}; removed {p['removedMs']}.")
            lines.append('  Original input operations identical; fresh pose/contact evaluation. Ablation '+json.dumps(p['ablation']))
    else:lines.append('Pending. No causal recovery claim from fresh totals alone.')
    screen=summary['savedTraceScreen']
    if screen:
        lines+=['',f"Final combined-rule saved screen: {screen['traces']} traces; {screen['exactBaselines']} exact baselines; {len(screen['removed'])} traces lose an accepted count; {len(screen['incompleteEvidence'])} need unsaved evidence for new candidates.",
            'This screen is not fresh-Vision validation of those missing callbacks. Frozen phone comparisons supply the target evidence.']
    lines+=['','Frozen contact replay disables the wall-clock contact-recheck rate limit, as in the existing',
        'harness. It tests evidence/rules with fixed original tracked inputs; it is not a live speed benchmark.',
        'Fresh-run input differences must still be reported even when neither new rule activates at the changed contact.',
        'The three-minute clip has selected reviewed targets only, not a complete manual ground-truth count.',
        'Phone field build restored and verified.' if summary['restore'] else 'Phone restoration pending.']
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
    print('Saved',len(runs),'paced runs and',len(pairs),'pairs; frozen complete',frozen is not None)


if __name__=='__main__':main()
