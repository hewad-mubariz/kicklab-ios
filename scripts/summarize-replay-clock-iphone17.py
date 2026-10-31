#!/usr/bin/env python3
"""Report clock-only comparisons separately from counter-rule comparisons."""
import itertools,json,plistlib,statistics,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/low-repeatability-iphone17/clock-build2026103018'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/low-repeatability-iphone17'
def read(p):return json.loads(p.read_text())

def main():
    OUT.mkdir(parents=True,exist_ok=True);runs=[];traces={};reports={}
    for path in sorted(BASE.glob('*/iphone17/*/source-admission.json')):
        d=path.parent
        if not(d/'complete.json').exists():continue
        s=read(d/'summary.json');a=read(path);r=read(d/'report.json')
        t=plistlib.load((d/'counter.plist').open('rb'));assert t['complete']
        s.update(experimentArm=d.parts[-3],repeat=int(d.name.rsplit('-r',1)[1]),directory=str(d.relative_to(ROOT)))
        assert s['build']=='2026103018' and not a['dropped_rows']
        assert [x['source_frame'] for x in a['rows'] if x['admitted']]==[o['input']['sourceFrameIndex'] for o in t['operations'] if 'input' in o]
        s['acceptedLegalSeconds']=sorted(x['label_time_s'] for x in read(d/'label-score.json')['matched'])
        s['sourceAudit']=dict(firstRows=a['rows'][:5],skipped=[x for x in a['rows'] if not x['admitted']],
            largestWakeLatenessMS=max((x['admission_lateness_ms'] for x in a['rows'] if x['requested_wait_ms']>0),default=0),
            sleepCount=sum(x['requested_wait_ms']>0 for x in a['rows']))
        s['overflow']=r['overflow_drops'];s['lateRFReplies']=r['late_replies']
        if s['experimentArm'].endswith('both'):
            output=subprocess.run([str(ROOT/'build/offline-counter-lab/counterlab-debug'),'low-robustness-ablation',str(d/'counter.plist')],capture_output=True,text=True,check=True)
            q=json.loads(output.stdout);assert q['baseExact'] and not q['baseMissingCallbacks']
            s['ruleAblation']=dict(removedMs=sorted(set(q['baseMs'])-set(q['changedMs'])),addedMs=sorted(set(q['changedMs'])-set(q['baseMs'])),missingCallbacks=q['changedMissingCallbacks'],removedDecisions=q['removedDecisions'],addedDecisions=q['newDecisions'])
        traces[s['directory']]=t;reports[s['directory']]=r;runs.append(s)
    pairs=[]
    for a,b in itertools.combinations(runs,2):
        if a['clip']!=b['clip'] or a['repeat']!=b['repeat']:continue
        arms={a['experimentArm'],b['experimentArm']}
        if arms=={'legacy-both','precise-both'}:kind='clock-only';first='legacy-both'
        elif arms=={'precise-control','precise-both'}:kind='rules-with-precise-clock';first='precise-control'
        else:continue
        if a['experimentArm']!=first:a,b=b,a
        ta,tb=[traces[r['directory']] for r in [a,b]]
        ca,cb=[t['config'].copy() for t in [ta,tb]]
        if kind=='rules-with-precise-clock':
            for key in ['confirmsDirectedForefoot','recoversObservedUnarmedTurn']:ca.pop(key,None);cb.pop(key,None)
        assert ca==cb and a['sourceSHA256']==b['sourceSHA256']
        ids=[[o['input']['sourceFrameIndex'] for o in t['operations'] if 'input' in o] for t in [ta,tb]]
        inputs=[{o['input']['timestampMs']:o['input'] for o in t['operations'] if 'input' in o} for t in [ta,tb]]
        changedBalls=[ms for ms in sorted(inputs[0].keys()&inputs[1].keys()) if inputs[0][ms].get('ball')!=inputs[1][ms].get('ball')]
        pair=dict(kind=kind,clip=a['clip'],repeat=a['repeat'],beforeDirectory=a['directory'],afterDirectory=b['directory'],
            beforeLegal=a['acceptedValid'],afterLegal=b['acceptedValid'],beforeFalse=a['knownFalse'],afterFalse=b['knownFalse'],
            gainedLegal=sorted(set(b['acceptedLegalSeconds'])-set(a['acceptedLegalSeconds'])),
            lostLegal=sorted(set(a['acceptedLegalSeconds'])-set(b['acceptedLegalSeconds'])),sourceFrameIdentitiesEqual=ids[0]==ids[1],
            beforeSkips=a['lateSourceSkips'],afterSkips=b['lateSourceSkips'],
            firstChangedBallMs=changedBalls[0] if changedBalls else None,changedBallViews=len(changedBalls))
        if changedBalls:
            first=changedBalls[0]/1000
            pair['firstDivergenceRF']=[[e for e in reports[r['directory']]['rf_events'] if first-.35<=e['source_seconds']<=first+.2] for r in [a,b]]
        pairs.append(pair)
    summary=dict(build='2026103018',runs=runs,pairs=pairs,defaultsChanged=False,
        documentation='https://docs.swift.org/main/documentation/swift/continuousclock/clock-implementations/',
        scope='Explicit paced replay only. Same model, capture pipeline, counter configuration and source videos; clock-only pairs differ solely in file replay clock mode.')
    (OUT/'clock-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    lines=['FILE-REPLAY CLOCK CHECK — IPHONE17 — BUILD2026103018','',
        'Precise mode anchors time after the first frame is decoded and requests zero timer tolerance.',
        'It preserves the existing one-frame lateness/drop limit; no backlog catch-up or saved touch injection.',
        'This debug replay change does not alter live camera capture, model inference or counting defaults.','']
    for r in runs:
        lines.append(f"{r['clip']} {r['experimentArm']} r{r['repeat']}: legal {r['acceptedValid']}, known false {r['knownFalse']}, skips {r['lateSourceSkips']}, empty pose {r['poseTiming']['empty']}, maximum wake lateness {r['sourceAudit']['largestWakeLatenessMS']:.2f}ms.")
    lines+=['','Paired comparisons:']
    for p in pairs:lines.append(f"{p['kind']} {p['clip']} r{p['repeat']}: {p['beforeLegal']} -> {p['afterLegal']} legal; gains {p['gainedLegal']}; losses {p['lostLegal']}; admitted source frames identical: {p['sourceFrameIdentitiesEqual']}.")
    if runs:lines+=['',f"{len(runs)} completed runs; thermal states {sorted({r['worstThermal'] for r in runs})}; overflow {sum(r['overflow'] for r in runs)}; late RF replies {sum(r['lateRFReplies'] for r in runs)}."]
    lines+=['','Zero requested tolerance is not a real-time deadline guarantee. Measured wake lateness remains recorded.',
        'Swift documents that omitting tolerance lets the system coalesce wake-ups:',summary['documentation'],
        'A matched delivery schedule does not freeze asynchronous detector scheduling or pose outputs.']
    (OUT/'CLOCK.txt').write_text('\n'.join(lines)+'\n')
    print('Saved',len(runs),'clock runs and',len(pairs),'pairs')

if __name__=='__main__':main()
