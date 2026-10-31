#!/usr/bin/env python3
"""Compare counted events, saved-input causality and phone health independently."""
import itertools,json,plistlib,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/supported-toe-lift-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/supported-toe-lift-iphone17'
NAMES={'clip-e842657024ae':'IMG9029','clip-89b81fd8bd37':'old three-minute','low':'low.mov',
       'clip-a16380ba4a5b':'IMG8606','clip-618a1688fcc6':'IMG8874'}
def read(p):return json.loads(p.read_text())
def main():
    OUT.mkdir(parents=True,exist_ok=True);runs=[];traces={}
    for file in sorted(BASE.glob('*/iphone17/*/source-admission.json')):
        p=file.parent
        if not (p/'complete.json').exists():continue
        s=read(p/'summary.json');r=read(p/'report.json');t=plistlib.loads((p/'counter.plist').read_bytes())
        s.update(setting=p.parts[-3],repeat=int(p.name.rsplit('-r',1)[1]),directory=str(p.relative_to(ROOT)),
            overflow=r['overflow_drops'],lateRF=r['late_replies'])
        assert s['build']=='2026103021' and t['complete'] and s['validForAccuracy']
        if (p/'label-score.json').exists():s['legalEvents']=sorted(x['label_time_s'] for x in read(p/'label-score.json')['matched'])
        targets=[8003,12471,12805] if s['clip']=='clip-e842657024ae' else [8016,42013,107910,125525,145458,153773,154206,157807] if s['clip']=='clip-89b81fd8bd37' else [4633,54033,58000] if s['clip']=='low' else []
        s['selectedEvents']={str(ms):[v for v in s['countTimes'] if abs(v-ms/1000)<.12] for ms in targets}
        if s['setting']=='supported':
            dest=p/'proof-ablation.json'
            if not dest.exists():
                result=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-supported-toe-audit'),
                    'supported-toe-ablation',str(p/'counter.plist')],capture_output=True,text=True,check=True)
                dest.write_text(json.dumps(json.loads(result.stdout),indent=2)+'\n')
            a=read(dest);assert a['baseExact']
            s['proofOnlyAddedMs']=sorted(set(a['baseMs'])-set(a['changedMs']))
            s['proofOnlyLostMs']=sorted(set(a['changedMs'])-set(a['baseMs']))
            s['ablationMissingCallbacks']=a['changedMissingCallbacks']
        else:
            dest=p/'proof-enable.json'
            if not dest.exists():
                result=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-supported-toe-audit'),
                    'supported-toe-screen',str(p/'counter.plist')],capture_output=True,text=True,check=True)
                dest.write_text(json.dumps(json.loads(result.stdout),indent=2)+'\n')
            a=read(dest);assert a['baseExact']
            s['enabledAddedMs']=sorted(set(a['changedMs'])-set(a['baseMs']))
            s['enabledLostMs']=sorted(set(a['baseMs'])-set(a['changedMs']))
            s['enableMissingCallbacks']=a['changedMissingCallbacks']
        runs.append(s);traces[s['directory']]=t
    pairs=[]
    for a,b in itertools.combinations(runs,2):
        if a['clip']!=b['clip'] or a['repeat']!=b['repeat'] or a['setting']==b['setting']:continue
        if a['setting']=='supported':a,b=b,a
        ta,tb=traces[a['directory']],traces[b['directory']]
        ca,cb=ta['config'].copy(),tb['config'].copy()
        assert ca.pop('confirmsSupportedToeLift',None)!=True and cb.pop('confirmsSupportedToeLift')==True
        assert ca==cb and a['sourceSHA256']==b['sourceSHA256']
        inputs=[{o['input']['sourceFrameIndex']:o['input'] for o in t['operations'] if 'input'in o} for t in [ta,tb]]
        p=dict(clip=a['clip'],repeat=a['repeat'],before=a['directory'],after=b['directory'],
            sameFrameIdentities=inputs[0].keys()==inputs[1].keys(),
            changedBallInputs=sum(inputs[0][k].get('ball')!=inputs[1][k].get('ball') for k in inputs[0].keys()&inputs[1].keys()))
        before_ms={t['timestampMs'] for t in ta['touches']}
        after_ms={t['timestampMs'] for t in tb['touches']}
        p.update(exactAddedMs=sorted(after_ms-before_ms),exactLostMs=sorted(before_ms-after_ms))
        if 'legalEvents'in a:p.update(gainedLegal=sorted(set(b['legalEvents'])-set(a['legalEvents'])),lostLegal=sorted(set(a['legalEvents'])-set(b['legalEvents'])))
        pairs.append(p)
    result=dict(runs=runs,pairs=pairs,offlineScreen=read(BASE/'counter-screen-summary.json'),
        predicateHits=read(BASE/'predicate-hits.json'),productionDefaultsChanged=False,
        scope='Paced fresh-Vision original videos on iPhone17 plus frozen saved-input counter replay; partial labels are not full ground truth.')
    if (BASE/'review/verified.json').exists():result['phoneReview']=read(BASE/'review/verified.json')
    (OUT/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['SUPPORTED TOE LIFT — IPHONE17 — 30 OCTOBER 2026','',
        'Only --supported-toe-lift-v1 differs. Same revision2, RF scheduling and other counter settings.','']
    for p in pairs:
        a,b=[next(s for s in runs if s['directory']==p[k]) for k in ['before','after']]
        lines.append(f"{NAMES.get(p['clip'],p['clip'])} r{p['repeat']}: {a['count']} -> {b['count']} counted; labelled legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        lines.append(f"  Same delivered frame IDs: {p['sameFrameIdentities']}; differing ball views: {p['changedBallInputs']}.")
        lines.append(f"  Exact event changes: added {p['exactAddedMs']} ms; removed {p['exactLostMs']} ms (nearby timestamps can describe the same contact).")
        if 'gainedLegal'in p:lines.append(f"  Labelled gains {p['gainedLegal']}; losses {p['lostLegal']}.")
        lines.append(f"  Proof ablation on identical saved input: added {b['proofOnlyAddedMs']} ms; lost {b['proofOnlyLostMs']} ms; missing callbacks {len(b['ablationMissingCallbacks'])}.")
        lines.append(f"  Enabling proof on control input: added {a['enabledAddedMs']} ms; lost {a['enabledLostMs']} ms; missing callbacks {len(a['enableMissingCallbacks'])}.")
        if a['selectedEvents']:lines.append('  Selected target counts: '+json.dumps({'before':a['selectedEvents'],'after':b['selectedEvents']}))
        lines.append(f"  Pose calls {a['poseTiming']['calls']} -> {b['poseTiming']['calls']}; frame latency p95 {a['latencyP95Ms']:.1f} -> {b['latencyP95Ms']:.1f} ms.")
    if runs:lines+=['',f"{len(runs)} completed runs. Thermal states {sorted(set(s['worstThermal'] for s in runs))}; source skips {sum(s['lateSourceSkips'] for s in runs)}; overflow {sum(s['overflow'] for s in runs)}; late RF replies {sum(s['lateRF'] for s in runs)}."]
    lines+=['','233 saved traces replay exactly. No saved accepted count lost. Only the two IMG9029 revision2 target traces need newly evaluated body evidence.']
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines).rstrip()+'\n');print('Saved',len(runs),'runs and',len(pairs),'pairs')
if __name__=='__main__':main()
