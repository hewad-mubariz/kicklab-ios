#!/usr/bin/env python3
"""Report event preservation, scheduling changes and compute cost separately."""
import argparse,itertools,json,plistlib,statistics,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/independent-regular-clock-iphone17'
OUT=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/independent-regular-clock-iphone17'
NAMES={'raw-juggling':'raw-juggling','clip-a16380ba4a5b':'IMG8606','low':'low.mov','clip-618a1688fcc6':'IMG8874','clip-89b81fd8bd37':'old three-minute clip'}
def read(p):return json.loads(p.read_text())
def main():
    global BASE,OUT
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--variant',choices=['independent','failed'],default='independent')
    args=parser.parse_args();failed=args.variant=='failed';build='2026103020' if failed else '2026103019'
    if failed:BASE=BASE.with_name('failed-retry-clock-iphone17');OUT=OUT.with_name('failed-retry-clock-iphone17')
    OUT.mkdir(parents=True,exist_ok=True);runs=[];data={}
    for sourcePath in sorted(BASE.glob('*/iphone17/*/source-admission.json')):
        path=sourcePath.parent
        if not(path/'complete.json').exists():continue
        s=read(path/'summary.json');r=read(path/'report.json');source=read(sourcePath)
        trace=plistlib.load((path/'counter.plist').open('rb'))
        s.update(experimentArm=path.parts[-3],repeat=int(path.name.rsplit('-r',1)[1]),directory=str(path.relative_to(ROOT)))
        assert s['build']==build and trace['complete'] and s['validForAccuracy']
        assert source['precise_clock'] and not source['dropped_rows']
        assert [x['source_frame'] for x in source['rows'] if x['admitted']]==[o['input']['sourceFrameIndex'] for o in trace['operations'] if 'input'in o]
        enabled=s['experimentArm']==args.variant
        assert r['failed_retry_clock' if failed else 'independent_regular_clock']==enabled
        assert r['worker']['model_instances']==r['worker']['maximum_active']==1
        s.update(clockAdjustments=r['failed_retry_clock_refunds' if failed else 'retry_clock_bypasses'],
            retryClockBypasses=r['retry_clock_bypasses'],failedRetryClockRefunds=r.get('failed_retry_clock_refunds',0),overflow=r['overflow_drops'],lateRFReplies=r['late_replies'],
            maximumCounterQueue=r['counter']['maximum_queue_depth'],
            regularRFHz=r['worker']['regular']/s['sourceSeconds'],
            allRFHz=sum(r['worker'][x] for x in ['regular','contact','impact_gap'])/s['sourceSeconds'],
            poseMsPerSourceSecond=s['poseTiming']['totalMS']/s['sourceSeconds'],
            notificationMedianMS=statistics.median(r['notification_latency_ms']) if r['notification_latency_ms'] else None)
        if (path/'label-score.json').exists():s['acceptedLegalSeconds']=sorted(x['label_time_s'] for x in read(path/'label-score.json')['matched'])
        if s['clip']=='clip-89b81fd8bd37':
            s['reviewedTargets']={str(ms):[x for x in s['countTimes'] if abs(x-ms/1000)<=.15] for ms in [8016,42013,107910,125525,145458,153773,154206,157807]}
        if s['clip']=='low':s['lowTargets']={str(ms):[x for x in s['countTimes'] if abs(x-ms/1000)<=.12] for ms in [4633,54033,58000]}
        if enabled and not failed:
            s['bypassedExposures']=[dict(sourceSeconds=e['source_seconds'],gapFromRegularMS=(e['submission_uptime']-e['previous_regular_submission_uptime'])*1000,gapFromAnyMS=(e['submission_uptime']-e['previous_submission_uptime'])*1000) for e in r['rf_events'] if e.get('purpose','regular')=='regular' and e.get('retry_clock_bypassed')]
            assert len(s['bypassedExposures'])==s['retryClockBypasses']
        if enabled and failed:
            s['refundedRetries']=[e for e in r['impact_gap_rechecks'] if e.get('failed_retry_clock_restored')]
            assert len(s['refundedRetries'])==s['failedRetryClockRefunds'] and all(not e['applied'] for e in s['refundedRetries'])
        runs.append(s);data[s['directory']]=(trace,r)
    pairs=[];repeatability=[]
    for a,b in itertools.combinations(runs,2):
        if a['clip']!=b['clip']:continue
        if a['experimentArm']==b['experimentArm']:
            if 'acceptedLegalSeconds'in a:repeatability.append(dict(clip=a['clip'],arm=a['experimentArm'],repeats=[a['repeat'],b['repeat']],changedLegal=sorted(set(a['acceptedLegalSeconds'])^set(b['acceptedLegalSeconds']))))
            continue
        if a['repeat']!=b['repeat']:continue
        if a['experimentArm']==args.variant:a,b=b,a
        ta,ra=data[a['directory']];tb,rb=data[b['directory']]
        assert ta['config']==tb['config'] and a['sourceSHA256']==b['sourceSHA256']
        inputs=[{o['input']['timestampMs']:o['input'] for o in t['operations'] if 'input'in o} for t in [ta,tb]]
        changedBalls=[ms for ms in sorted(inputs[0].keys()&inputs[1].keys()) if inputs[0][ms].get('ball')!=inputs[1][ms].get('ball')]
        row=dict(clip=a['clip'],repeat=a['repeat'],before=a['directory'],after=b['directory'],
            appliedExperimentCount=b['clockAdjustments'],
            sourceFrameIdentitiesEqual=[i['sourceFrameIndex'] for i in inputs[0].values()]==[i['sourceFrameIndex'] for i in inputs[1].values()],
            firstChangedBallMs=changedBalls[0] if changedBalls else None,changedBallViews=len(changedBalls))
        if 'acceptedLegalSeconds'in a:
            row.update(gainedLegal=sorted(set(b['acceptedLegalSeconds'])-set(a['acceptedLegalSeconds'])),lostLegal=sorted(set(a['acceptedLegalSeconds'])-set(b['acceptedLegalSeconds'])))
        row['windows']=[]
        for sec in sorted(set(row.get('gainedLegal',[])+row.get('lostLegal',[]))):
            row['windows'].append(dict(labelSeconds=sec,arms=[dict(
                decisions=[dict(operation=d['operation'],**{k:v for k,v in d['value'].items() if not isinstance(v,(list,dict))}) for d in t['decisions'] if abs(d['value']['timestampMs']/1000-sec)<=.25],
                tracking=[x for x in r['samples'] if sec-.4<=x['source_seconds']<=sec+.4],
                detector=[x for x in r['rf_events'] if sec-.4<=x['source_seconds']<=sec+.4]) for t,r in [(ta,ra),(tb,rb)]]))
        pairs.append(row)
    restored=read(BASE/'restore/verified.json') if (BASE/'restore/verified.json').exists() else None
    handoff=read(BASE/'phone-handoff.json') if (BASE/'phone-handoff.json').exists() else None
    result=dict(build=build,variant=args.variant,runs=runs,pairs=pairs,repeatability=repeatability,restore=restored,phoneHandoff=handoff,defaultsChanged=False,
        scope='Paced original videos through the live engine, using the precise replay clock; not new physical camera recordings.')
    (OUT/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    flag='--rf-failed-retry-clock-v1' if failed else '--rf-independent-regular-clock-v1'
    lines=[('FAILED-RETRY CLOCK' if failed else 'INDEPENDENT REGULAR/RETRY CLOCK')+' — IPHONE17 — 30 OCTOBER 2026','',
        f'Only {flag} differs between arms. Counter config is identical.',
        'Both use revision2, precise replay timing and the same prior low-contact/ground opt-ins.',
        'No source-grid/reservation prototype or new threshold is enabled. Production default remains off.','']
    for p in pairs:
        a,b=[next(r for r in runs if r['directory']==p[key]) for key in ['before','after']]
        lines.append(f"{NAMES.get(p['clip'],p['clip'])} r{p['repeat']}: total {a['count']} -> {b['count']}; legal {a.get('acceptedValid','unlabelled')} -> {b.get('acceptedValid','unlabelled')}; known false {a.get('knownFalse','unlabelled')} -> {b.get('knownFalse','unlabelled')}.")
        if 'gainedLegal'in p:lines.append(f"  Gains {p['gainedLegal']}; losses {p['lostLegal']}.")
        lines.append(f"  Regular RF {a['regularRFHz']:.2f} -> {b['regularRFHz']:.2f}/s; all RF {a['allRFHz']:.2f} -> {b['allRFHz']:.2f}/s; pose work {a['poseMsPerSourceSecond']:.1f} -> {b['poseMsPerSourceSecond']:.1f}ms/s; frame p95 {a['latencyP95Ms']:.1f} -> {b['latencyP95Ms']:.1f}ms; clock adjustments {b['clockAdjustments']}.")
        if not p['sourceFrameIdentitiesEqual']:lines.append(f"  Delivered source frames differ (skips {a['lateSourceSkips']} -> {b['lateSourceSkips']}); this is not an identical-input comparison.")
        if not b['clockAdjustments']:lines.append('  No scheduling adjustment executed in the experimental arm; score changes cannot be credited to this mechanism.')
        if 'reviewedTargets'in a:lines.append('  Selected three-minute targets '+json.dumps(dict(before=a['reviewedTargets'],after=b['reviewedTargets'])))
        if 'lowTargets'in a:lines.append('  Low targets '+json.dumps(dict(before=a['lowTargets'],after=b['lowTargets'])))
    if runs:lines+=['',f"{len(runs)} completed runs; thermal states {sorted({r['worstThermal'] for r in runs})}; overflow {sum(r['overflow'] for r in runs)}; source skips {sum(r['lateSourceSkips'] for r in runs)}; late RF replies {sum(r['lateRFReplies'] for r in runs)}.",
        'One RF model and at most one active RF inference in every run; regular submissions retain the full wall-rate interval.']
    lines+=['','Same-setting repeat event changes:']+[json.dumps(x) for x in repeatability]
    lines+=['','Old three-minute footage has selected reviewed events only; its total is not a full legal-touch score.',
        'Field build restored and verified.' if restored else ('Phone left in the subsequent user-requested replay; see phone-handoff.json.' if handoff else 'Phone restoration pending.')]
    if (BASE/'conclusion.txt').exists():lines+=['',(BASE/'conclusion.txt').read_text().strip()]
    (OUT/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
    print('Saved',len(runs),'runs and',len(pairs),'pairs')
if __name__=='__main__':main()
