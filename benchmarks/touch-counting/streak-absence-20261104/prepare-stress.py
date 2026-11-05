#!/usr/bin/env python3
"""Keeps only stretches that are valid juggling: the labelled spans, and the long session."""
import json,os,sys
H,L,OUT=sys.argv[1:4]
labels={f[:-5]:json.load(open(L+f)) for f in os.listdir(L)}
n=0
with open(OUT,'w') as out:
    for l in open(H):
        r=json.loads(l); c=r['clip']
        if '@low-tier' in c: c='low'
        if c=='long-session': spans=[[0,r['samples'][-1][0]]]
        elif c in labels and labels[c].get('events'):
            ev=[e['time_s'] for e in labels[c]['events'] if e.get('label')=='valid']
            if not ev: continue
            bad=sorted((s['start_s'],s['end_s']) for s in labels[c].get('segments',[]) if s.get('label') in('invalid','uncertain'))
            nv=[e['time_s'] for e in labels[c]['events'] if e.get('label')!='valid']
            bad+= [(t-.3,t+.3) for t in nv]; bad.sort()
            spans=[];cur=min(ev)
            for a,b in bad+[(max(ev)+.2,max(ev)+.2)]:
                if a>cur: spans.append([int(cur*1000),int(a*1000)])
                cur=max(cur,b)
        else: continue
        spans=[s for s in spans if s[1]-s[0]>=3000]
        if spans:
            out.write(json.dumps(dict(id=r['id'],clip=c,level=r['level'],touches=r['touches'],samples=r['samples'],spans=spans))+'\n'); n+=1
print('runs',n)
