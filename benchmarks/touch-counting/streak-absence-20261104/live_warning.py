#!/usr/bin/env python3
"""How often would a live warning fire during valid juggling, at each wait before it shows?"""
import json,sys,collections
PAIR=600; GAP=600
def episodes(samples,touches,col,wait,spans):
    """Causal clock, same rules as StreakVisibilityEvidence: a confirmed sighting or a touch resets it."""
    out=[]; since=None; prev=None; lastSight=None; firing=False; ti=0; touches=sorted(touches)
    for s in samples:
        t=s[0]; seen=bool(s[col]); confirmed=False
        while ti<len(touches) and touches[ti]<=t:
            tt=touches[ti]; ti+=1
            if lastSight is not None and tt-lastSight<=PAIR: confirmed=True
            lastSight=tt; confirmed=True  # a counted touch always clears the warning
        if seen:
            if lastSight is not None and t-lastSight<=PAIR: confirmed=True
            lastSight=t
        if confirmed:
            since=None; prev=None; firing=False; continue
        if prev is None or t-prev>GAP: since=t; firing=False
        prev=t
        if t-since>=wait and not firing:
            firing=True
            if any(a<=t<=b for a,b in spans): out.append(t)
    return out
for name in sys.argv[1:]:
    runs=[json.loads(l) for l in open(name)]
    mins=sum((b-a) for r in runs for a,b in r['spans'])/60000
    tch=sum(1 for r in runs for t in r['touches'] if any(a<=t<=b for a,b in r['spans']))
    print(f"{name.split('/')[-1]}: {len(runs)} runs, {mins:.0f} min of valid juggling, {tch} touches")
    for col,label in ((1,'player'),(2,'ball')):
        for wait in (500,1000,1500,2000,2500):
            n=0; per=collections.Counter()
            for r in runs:
                e=episodes(r['samples'],r['touches'],col,wait,r['spans']); n+=len(e); per[r['clip']]+=len(e)
            worst=per.most_common(2)
            print(f"  {label:6} wait {wait/1000:.1f}s: {n:5} warnings, {n/max(mins,.01):6.2f}/min, {n*1000/max(tch,1):7.1f}/1000 touches  worst {worst}")
