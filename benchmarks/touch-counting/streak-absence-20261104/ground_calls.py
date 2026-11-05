#!/usr/bin/env python3
"""Runs StreakGroundCalls over every saved counter trace: which floor calls would stop ending a streak.
Usage: ground_calls.py <root with saved traces> <fixtures folder>"""
import plistlib,glob,os,sys
MAX_FALL,RHYTHM,RUN=2.0,1200,3
def load(p):
    d=plistlib.load(open(p,'rb')); return d,(d.get('trace') or d)
def review(tr):
    balls={o['input']['frameIndex']:o['input']['ball'] for o in tr['operations'] if o.get('input') and o['input'].get('ball')}
    inter={i['timestampMs'] for i in (tr.get('streakInterruptions') or []) if i.get('kind')=='groundContact'}
    ev=[]
    for x in tr['decisions']:
        v=x['value']
        if v.get('rejection')=='groundBounce' and v.get('footConfirmed') is not True and (v.get('plantedFeetConfirmed') is True or v['timestampMs'] in inter):
            ev.append((v['timestampMs'],0,v))
    ev+=[(t['timestampMs'],1,t) for t in tr['touches']]
    ev.sort(key=lambda e:(e[0],e[1]))
    calls,last,run,kept,over=[],None,0,[],[]
    def height(f):
        for k in range(4):
            for g in (f-k,f+k):
                if g in balls: return balls[g]['height']
    for t,kind,o in ev:
        if kind==0:
            h=height(o['frameIndex']); fall=o.get('fall')
            calls.append((o,t,(fall/h) if h and fall is not None else None,last))
            continue
        earlier=[c for c in calls if o['frameIndex']-c[0]['frameIndex']>1]
        run=run+1 if earlier else 0
        for c,tc,f,prev in calls:
            same=o['frameIndex']-c['frameIndex']<=1
            ok=same or (run<RUN and f is not None and f<=MAX_FALL and prev is not None and tc-prev<=RHYTHM and t-tc<=RHYTHM)
            (over if ok else kept).append((c['frameIndex'],tc,f,tc-prev if prev is not None else None,t-tc,same))
        calls,last=[],t
    kept+=[(c['frameIndex'],tc,f,tc-prev if prev is not None else None,None,False) for c,tc,f,prev in calls]
    return kept,over
root,fx=sys.argv[1:3]
seen=set();kept=over=0;rows=[]
for p in sorted(glob.glob(root+'/**/*.plist',recursive=True))+sorted(glob.glob(fx+'/*.plist')):
    if 'session-274' in p or os.path.getsize(p)<20000: continue
    try: d,tr=load(p)
    except Exception: continue
    if not isinstance(tr,dict) or 'decisions' not in tr or 'operations' not in tr: continue
    try: K,O=review(tr)
    except Exception: continue
    tag=os.path.relpath(p,root) if p.startswith(root) else 'Fixtures/'+os.path.basename(p)
    for r in K:
        if (r[1],r[0]) not in seen: seen.add((r[1],r[0])); kept+=1
    for r in O:
        if (r[1],r[0]) not in seen:
            seen.add((r[1],r[0])); over+=1; rows.append((tag[:60],r))
print(f"Other distinct floor stops: {kept} still end a streak, {over} no longer do")
for tag,(f,t,fall,prv,nxt,same) in rows:
    print(f"  {tag}  frame {f}  fall {None if fall is None else round(fall,2)}  touch before {prv} ms  touch after {nxt} ms  {'same contact' if same else 'unbroken juggling'}")
d,tr=load(fx+'/session-274-counter-v9.plist'); K,O=review(tr)
print(f"274 session after the foot rule: {len(K)} still end a streak, {len(O)} no longer do")
