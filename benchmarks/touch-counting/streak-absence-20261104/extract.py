#!/usr/bin/env python3
"""Pull ball, person and touch timelines out of every saved counter run."""
import json,os,plistlib,re,sys,bisect
P='/Users/hewadmubariz/Desktop/projects/'
ROOTS=[P+'kicklab/artifacts',P+'kicklab/benchmarks',P+'kicklab-ball-swaps/artifacts',P+'kicklab-ball-swaps/benchmarks']
OUT=sys.argv[1]
CLIP=re.compile(r'((?:normal|nomral)_juggling_\d|34dd|eighteen|juggling_second_ball_in_video|juggling_second_ball_very_far|juggling|low|raw-juggling|dribbling_with_ball_\d|dribbling_with_the_ball_\d|ball_in_hand)(?:[-.]|$)')
def load(p):
    try:
        if p.endswith('.json'):
            raw=open(p,'rb').read()
            if b'operations' not in raw and b'rf_events' not in raw: return None
            return json.loads(raw)
        return plistlib.load(open(p,'rb'))
    except Exception: return None
def clip_of(p,d):
    f=os.path.basename(p); m=CLIP.match(f)
    if m: return m.group(1)
    if 'walkthrough' in p: return 'walkthrough'
    if 'sparse-floor' in f: return 'sparse-floor-bounces'
    if 'ground-bounces' in f: return 'ground-bounces'
    if isinstance(d,dict) and d.get('sourceDigest'): return 'digest-'+d['sourceDigest'][:10]
    return re.sub(r'-(before|after|trace|archive|counter).*','',f)+'@'+os.path.basename(os.path.dirname(p))
seen=set();n={'trace':0,'rf':0}
with open(OUT,'w') as out:
    for r in ROOTS:
        for dp,dn,fn in os.walk(r):
            if 'mac-full' in dp: continue
            for f in fn:
                if not f.endswith(('.json','.plist')): continue
                p=os.path.join(dp,f)
                try: sz=os.path.getsize(p)
                except OSError: continue
                if sz<20000 or sz>80_000_000: continue
                d=load(p)
                if not isinstance(d,dict): continue
                t=d if 'operations' in d and 'touches' in d else d.get('trace')
                if not isinstance(t,dict) or 'operations' not in t: continue
                ops=[o['input'] for o in t['operations'] if isinstance(o,dict) and o.get('input')]
                tou=t.get('touches') or []
                if len(ops)<100 or len(tou)<2: continue
                z=ops[0]['timestampMs']
                ts=[o['timestampMs']-z for o in ops]
                person=[(o.get('player') or {}).get('peopleCount',0)>0 or o.get('person') is not None for o in ops]
                touches=sorted(x['timestampMs']-z for x in tou)
                bounds=sorted(x['timestampMs']-z for x in (t.get('streakInterruptions') or []))
                clip=clip_of(p,d)
                key=(clip,tuple(touches),len(ops))
                if key in seen: continue
                seen.add(key)
                base=dict(id=os.path.relpath(p,P),clip=clip,touches=touches,boundaries=bounds)
                out.write(json.dumps(dict(base,level='trace',samples=[[a,int(o.get('ball') is not None),int(b)] for a,o,b in zip(ts,ops,person)]))+'\n'); n['trace']+=1
                # The reply-by-reply view, which is what the app really records.
                rep=os.path.join(dp,'report.json')
                if os.path.exists(rep):
                    e=(load(rep) or {}).get('rf_events') or []
                    if e:
                        s=[]
                        for ev in sorted(e,key=lambda x:x['source_seconds']):
                            ms=int(round(ev['source_seconds']*1000)); i=min(bisect.bisect_left(ts,ms),len(ts)-1)
                            s.append([ms,int(ev.get('candidate_count',0)>0),int(person[i])])
                        out.write(json.dumps(dict(base,id=base['id']+'#rf',level='rf',samples=s))+'\n'); n['rf']+=1
    R=P+'kicklab/artifacts/long-video-6500-20261104/mac-full/'
    s=[]
    for l in open(R+'frames.jsonl'):
        x=json.loads(l); i=x['input']; pl=i.get('player') or {}
        s.append([int(round(x['time']*1000)),int(i.get('ball') is not None),int(pl.get('peopleCount',0)>0)])
    tt=sorted(json.loads(l)['timestampMs'] for l in open(R+'touches.jsonl'))
    out.write(json.dumps(dict(id='long-video-6500-20261104/mac-full',clip='long-session',touches=tt,boundaries=[],level='trace',samples=s))+'\n')
print(n)
