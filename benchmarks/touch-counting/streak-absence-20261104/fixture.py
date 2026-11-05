#!/usr/bin/env python3
"""Builds the footage fixtures for the streak absence tests."""
import json,os,sys,bisect
H,L,FX=sys.argv[1:4]
labels={f[:-5]:json.load(open(L+f)) for f in os.listdir(L)}
def enc(s,a,b):
    out=[];last=a
    for t,bl,p in s:
        if a<t<b: out.append(f"{t-last}:{bl+2*p}");last=t
    return ' '.join(out)
def worst(s,a,b):
    best=0;run=None;last=a
    for t,bl,p in s:
        if not a<t<b: continue
        if not bl:
            if run is None: run=last
            best=max(best,t-run)
        else: run=None
        last=t
    return best
cases={}
def add(clip,run,expect,why,a,b,s):
    k=(clip,a,b,expect)
    if k not in cases: cases[k]=dict(clip=clip,run=run,expect=expect,why=why,before=a,after=b,samples=enc(s,a,b))
valid=[json.loads(l) for l in open(os.path.join(os.path.dirname(H),'stress/valid.jsonl'))]
for r in valid:
    tt=r['touches']; s=r['samples']; c=r['clip']; picks=[]
    for sp in r['spans']:
        inside=[t for t in tt if sp[0]<=t<=sp[1]]
        for i,a in enumerate(inside):
            b=next((t for t in inside[i+1:] if t-a>=6000),None)
            if b is None: break
            if b-a<=12000: picks.append((worst(s,a,b),a,b))
    for w,a,b in sorted(picks,reverse=True)[:2]:
        add(c,r['id'],'keep',f'Real juggling with the touches in between removed; ball unseen for {w} ms at most',a,b,s)
runs=[json.loads(l) for l in open(H)]
for r in runs:
    c=r['clip']; tt=r['touches']; s=r['samples']
    for a,b in zip(tt,tt[1:]):
        if b-a<3000: continue
        if c=='long-session': add(c,r['id'],'keep','Longest gap in 56 minutes: the player turned away and the legs hid the ball, still juggling',a,b,s)
        if c in labels:
            A,B=a/1000,b/1000
            bad=[x for x in labels[c].get('segments',[]) if x['start_s']<B and x['end_s']>A and x.get('label') in('invalid','uncertain')]
            ev=[e for e in labels[c].get('events',[]) if A<e.get('time_s',-1)<B and e.get('label')!='valid']
            if not bad and not ev: add(c,r['id'],'keep','Counter missed touches in a labelled valid run',a,b,s)
ends=[('normal_juggling_4',12000,14000,'Labelled: ball and then player outside the frame'),('normal_juggling_8',28000,30500,'Labelled: ball outside the frame'),
      ('walkthrough',56000,57000,'Watched: ball rolled out below the frame'),('walkthrough',129000,131000,'Watched: player stands without the ball and picks it up'),
      ('hands',49000,51000,'Watched: ball left, player walked off and came back holding it'),('digest-98c691e079',10000,12000,'Watched: player walked out of the room')]
for r in runs:
    for c,lo,hi,why in ends:
        if not r['clip'].startswith(c): continue
        for a,b in zip(r['touches'],r['touches'][1:]):
            if b-a>=3000 and a<=hi and b>=lo and worst(r['samples'],a,b)>=3300:
                add(c,r['id'],'end',why,a,b,r['samples'])
out=dict(note='Numbers only: ball and player detections per frame between two counted touches. Flags: 1 ball seen, 2 player seen. Built by benchmarks/touch-counting/streak-absence-20261104/fixture.py.',cases=list(cases.values()))
json.dump(out,open(FX+'/streak-absence-cases.json','w'),separators=(',',':'))
print('cases',len(cases),{e:sum(1 for c in cases.values() if c['expect']==e) for e in('keep','end')},'clips',len({c['clip'] for c in cases.values()}),'bytes',os.path.getsize(FX+'/streak-absence-cases.json'))
# Real videos: spans for the real model to look at.
foot=[]
for c,l in labels.items():
    ev=[e['time_s'] for e in l.get('events',[]) if e.get('label')=='valid']
    if len(ev)<8: continue
    bad=sorted((s['start_s'],s['end_s']) for s in l.get('segments',[]) if s.get('label') in('invalid','uncertain'))
    bad+=[(e['time_s']-.3,e['time_s']+.3) for e in l.get('events',[]) if e.get('label')!='valid']
    picked=0;i=0
    while i<len(ev) and picked<3:
        j=next((k for k in range(i+1,len(ev)) if ev[k]-ev[i]>=5),None)
        if j is None: break
        if not [1 for a,b in bad if a<ev[j] and b>ev[i]]:
            foot.append(dict(video=c+('.mp4' if c=='juggling' else '.mov'),before=int(ev[i]*1000),after=int(ev[j]*1000),expect='keep'));picked+=1;i=j
        else: i+=1
exits=[('normal_juggling_4.mov',12560,16200),('normal_juggling_8.mov',28550,32050),('walkthrough.mov',56510,59810),('walkthrough.mov',129320,133450),('left-the-room.mov',11150,20120)]
for v,a,b in exits: foot.append(dict(video=v,before=a-400,after=b+400,expect='end'))
json.dump(dict(cases=foot),open(FX+'/streak-absence-footage.json','w'),indent=1)
print('footage',len(foot),'keep',sum(f['expect']=='keep' for f in foot),'videos',len({f['video'] for f in foot}))
