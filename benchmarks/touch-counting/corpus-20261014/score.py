"""Match visually reviewed events to current counter output, one to one.

Unmatched predictions require review unless an explicitly labelled negative
interval covers them. Uncertain labels never silently become true/false events.
"""
from functools import lru_cache
from pathlib import Path
import json

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
TOLERANCE=.20

def align(events,touches,tolerance=TOLERANCE):
    @lru_cache(None)
    def solve(i,j):
        if i==len(events) or j==len(touches):return 0,0.0,()
        options=[solve(i+1,j),solve(i,j+1)]
        error=abs(events[i]['time_s']-touches[j]['timestampMs']/1000)
        if error<=tolerance:
            n,cost,pairs=solve(i+1,j+1)
            options.append((n+1,cost-error,((i,j),)+pairs))
        return max(options,key=lambda x:x[:2])
    return solve(0,0)[2]

def score(label,trace):
    events=sorted(label['events'],key=lambda e:e['time_s'])
    touches=trace['touches']
    tolerance=label.get('time_tolerance_s',TOLERANCE)
    pairs=align(events,touches,tolerance); by_event=dict(pairs); used={j for _,j in pairs}
    decisions=[d for d in trace['diagnostics'] if d.get('rejection')]
    matched=[];missed=[];uncertain=[];false=[];unreviewed=[]
    for i,e in enumerate(events):
        if i in by_event:
            t=touches[by_event[i]];row=dict(label_id=e['id'],label_time_s=e['time_s'],counter_time_s=t['timestampMs']/1000,frame=t['frameIndex'])
            (matched if e['label']=='valid' else uncertain if e['label']=='uncertain' else false).append(row)
        elif e['label']=='valid':
            close=[d for d in decisions if abs(d['time']-e['time_s'])<=tolerance]
            reason=min(close,key=lambda d:abs(d['time']-e['time_s'])) if close else None
            missed.append(dict(label_id=e['id'],time_s=e['time_s'],contact=e['contact'],decision={k:v for k,v in reason.items() if k!='ball'} if reason else None,stage='rejected_candidate' if reason else 'no_nearby_candidate'))
    for j,t in enumerate(touches):
        if j in used:continue
        ts=t['timestampMs']/1000
        segments=[s for s in label.get('segments',[]) if s['start_s']<=ts<=s['end_s']]
        row=dict(counter_time_s=ts,frame=t['frameIndex'])
        if any(s['label']=='invalid' for s in segments):
            row['reason']=next(s['reason'] for s in segments if s['label']=='invalid');false.append(row)
        elif any(s['label']=='uncertain' for s in segments):uncertain.append(row)
        else:unreviewed.append(row)
    return dict(source=label['source_name'],source_sha256=label['source_sha256'],label_review_status=label['review_status'],time_tolerance_s=tolerance,total_count=len(touches),labelled_valid=sum(e['label']=='valid' for e in events),labelled_uncertain=sum(e['label']=='uncertain' for e in events),accepted_valid=len(matched),missed_valid=missed,false_accepted=false,uncertain_accepted=uncertain,unmatched_needing_review=unreviewed,matched=matched)

if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--predictions',type=Path,default=HERE/'predictions',help='Directory of compact per-clip touches and diagnostics JSON')
    args=parser.parse_args()
    (HERE/'results').mkdir(exist_ok=True)
    rows=[]
    for p in sorted((HERE/'labels').glob('*.json')):
        raw=args.predictions/p.name
        label=json.loads(p.read_text()); prediction=json.loads(raw.read_text())
        if prediction['source_sha256']!=label['source_sha256']:
            raise ValueError(f'Source hash mismatch: {p.stem}')
        row=score(label,prediction)
        (HERE/'results'/p.name).write_text(json.dumps(row,indent=2)+'\n')
        brief={k:row[k] for k in ['source','total_count','labelled_valid','labelled_uncertain','accepted_valid','missed_valid','false_accepted','uncertain_accepted','unmatched_needing_review']}
        rows.append(brief)
    (HERE/'summary.json').write_text(json.dumps({'scope':'Assistant visual event review of development footage; uncertain contacts excluded from definitive error totals. Not a blind held-out accuracy benchmark.','clips':rows},indent=2)+'\n')
    print(json.dumps(rows,indent=2))
