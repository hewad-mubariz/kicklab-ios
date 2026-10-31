#!/usr/bin/env python3
"""Compare labelled events, shared inputs and evidence demand in repeated phone runs."""
import itertools,json,plistlib,statistics,subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/low-repeatability-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/low-repeatability-iphone17'
NAMES={'clip-a16380ba4a5b':'IMG8606','raw-juggling':'raw-juggling','low':'low.mov'}

def read(p):return json.loads(p.read_text())
def comparable(v):
    if isinstance(v,dict):return {k:comparable(x) for k,x in v.items() if k not in ['frameIndex','sourceFrameIndex']}
    if isinstance(v,list):return [comparable(x) for x in v]
    return v

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    runs=[];data={};pairs=[]
    for marker in sorted(BASE.glob('*/iphone17/*/complete.json')):
        path=marker.parent;s=read(path/'summary.json');profile=read(path/'profile.json')
        assert s['build']=='2026103017' and s['validForAccuracy']
        s.update(experimentArm=path.parts[-3],repeat=int(path.name.rsplit('-r',1)[1]),directory=str(path.relative_to(ROOT)))
        t=plistlib.load((path/'counter.plist').open('rb'));r=read(path/'report.json');score=read(path/'label-score.json')
        s['acceptedLegalSeconds']=sorted(x['label_time_s'] for x in score['matched'])
        s['overflow']=r['overflow_drops'];s['lateRFReplies']=r['late_replies']
        s['maximumActiveInferences']=r['worker']['maximum_active']
        s['notificationMedianMS']=statistics.median(r['notification_latency_ms']) if r['notification_latency_ms'] else None
        s['ablation']=None
        if s['experimentArm']=='both':
            p=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'low-robustness-ablation',str(path/'counter.plist')],capture_output=True,text=True,check=True)
            result=json.loads(p.stdout);assert result['baseExact'] and not result['baseMissingCallbacks']
            s['ablation']=dict(removedMs=sorted(set(result['baseMs'])-set(result['changedMs'])),
                addedMs=sorted(set(result['changedMs'])-set(result['baseMs'])),missingCallbacks=result['changedMissingCallbacks'],
                changedDecisions=result['newDecisions'],removedDecisions=result.get('removedDecisions'))
        runs.append(s);data[s['directory']]=(t,r,profile)
    for a,b in itertools.combinations(runs,2):
        if a['clip']!=b['clip']:continue
        kind='same-setting-repeat' if a['experimentArm']==b['experimentArm'] else 'paired-arm' if a['repeat']==b['repeat'] else None
        if kind is None:continue
        if kind=='paired-arm' and a['experimentArm']=='both':a,b=b,a
        ta,ra,pa=data[a['directory']];tb,rb,pb=data[b['directory']]
        assert a['sourceSHA256']==b['sourceSHA256']
        ca,cb=[t['config'].copy() for t in [ta,tb]]
        for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:
            ca.pop(key,None);cb.pop(key,None)
        assert ca==cb
        ia,ib=[{o['input']['timestampMs']:o['input'] for o in t['operations'] if 'input' in o} for t in [ta,tb]]
        common=sorted(ia.keys()&ib.keys())
        changed=[ms for ms in common if comparable(ia[ms])!=comparable(ib[ms])]
        balls=[ms for ms in common if comparable(ia[ms].get('ball'))!=comparable(ib[ms].get('ball'))]
        regular=[{round(e['source_seconds']*1000) for e in r['rf_events'] if e.get('purpose','regular')=='regular'} for r in [ra,rb]]
        gained=sorted(set(b['acceptedLegalSeconds'])-set(a['acceptedLegalSeconds']))
        lost=sorted(set(a['acceptedLegalSeconds'])-set(b['acceptedLegalSeconds']))
        pair=dict(kind=kind,clip=a['clip'],directories=[a['directory'],b['directory']],
            gainedLegal=gained,lostLegal=lost,commonInputTimestamps=len(common),changedInputs=len(changed),
            firstChangedInputMs=changed[0] if changed else None,firstChangedBallMs=balls[0] if balls else None,
            sourceTimestampsOnlyBefore=sorted(ia.keys()-ib.keys()),sourceTimestampsOnlyAfter=sorted(ib.keys()-ia.keys()),
            firstDifferentRegularExposureMs=min(regular[0]^regular[1]) if regular[0]^regular[1] else None,
            regularExposureIntersectionOverUnion=len(regular[0]&regular[1])/len(regular[0]|regular[1]))
        if kind=='paired-arm':
            pair['windows']=[]
            for seconds in sorted(set(gained+lost)):
                arms=[]
                for t,r in [(ta,ra),(tb,rb)]:
                    arms.append(dict(decisions=[dict(operation=d['operation'],**{k:v for k,v in d['value'].items() if not isinstance(v,(list,dict))}) for d in t['decisions'] if abs(d['value']['timestampMs']/1000-seconds)<=.25],
                        tracking=[x for x in r['samples'] if seconds-.4<=x['source_seconds']<=seconds+.4],
                        rf=[x for x in r['rf_events'] if seconds-.4<=x['source_seconds']<=seconds+.4],
                        rechecks=[x for x in r['rechecks'] if seconds-.4<=x.get('source_seconds',-99)<=seconds+.4]))
                pair['windows'].append(dict(labelSeconds=seconds,arms=arms))
        pairs.append(pair)
    result=dict(build='2026103017',runs=runs,comparisons=pairs,defaultsChanged=False,
        scope='Paced original-video replays through LiveJugglingAnalysis; not new camera recordings.',
        restore=read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None)
    (OUT/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['REVISION 2: LOW-KICK RULE REPEATABILITY — IPHONE17 — 30 OCTOBER 2026','',
        'Same build and source hashes, alternating arm order. Control retains all previously tested common rules;',
        'both enables only directed-forefoot-v1 and observed-unarmed-turn-v1. Neither is a production default.','',
        'Legal counts and known false counts are separate; higher totals do not establish better accuracy.']
    for clip in NAMES:
        lines+=['',NAMES[clip]]
        for arm in ['control','both']:
            rows=sorted([r for r in runs if r['clip']==clip and r['experimentArm']==arm],key=lambda r:r['repeat'])
            lines.append(f"  {arm}: legal {[r['acceptedValid'] for r in rows]}, known false {[r['knownFalse'] for r in rows]}, skipped source frames {[r['lateSourceSkips'] for r in rows]}, raw empty pose calls {[r['poseTiming']['empty'] for r in rows]}.")
    lines+=['','Per-pair legal changes:']
    for p in pairs:
        if p['kind']=='paired-arm':lines.append(f"  {NAMES[p['clip']]} r{next(r['repeat'] for r in runs if r['directory']==p['directories'][0])}: gained {p['gainedLegal']}; lost {p['lostLegal']}; first changed ball {p['firstChangedBallMs']} ms.")
    if runs:lines+=['',f"Completed {len(runs)} runs; thermal states {sorted({r['worstThermal'] for r in runs})}; overflow {sum(r['overflow'] for r in runs)}; late RF replies {sum(r['lateRFReplies'] for r in runs)}."]
    lines+=['','Counter ablations on improved saved inputs:']
    for r in runs:
        if r['ablation'] is not None:lines.append(f"  {NAMES[r['clip']]} r{r['repeat']}: {json.dumps(r['ablation'])}")
    lines+=['','Ablation holds upstream inputs fixed; it cannot exclude timing feedback into the shared worker.',
        'Same-setting comparisons and per-contact evidence are in summary.json.',
        'Restored field build and verified preview.' if result['restore'] else 'Phone restoration pending.']
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
    print('Saved',len(runs),'runs;',len(pairs),'comparisons')

if __name__=='__main__':main()
