#!/usr/bin/env python3
"""Scores replay decisions against the hand labels of the 20 corpus clips."""
import json,sys,collections
L='/Users/hewadmubariz/Desktop/projects/kicklab-ball-swaps/benchmarks/touch-counting/corpus-20261014/labels/'
import os
rows=[json.loads(l) for l in open(sys.argv[1])]
labels={f[:-5]:json.load(open(L+f)) for f in os.listdir(L)}
wrong=[];real=collections.Counter();unl=collections.defaultdict(lambda:collections.defaultdict(list));cl=collections.Counter()
pairs=0
for r in rows:
    c=r['clip']; cl[c]+=1
    for k,t,g in zip(r['kinds'],r['times'],r['gaps']):
        a,b=g[0]/1000,g[1]/1000
        if c in labels:
            bad=[s for s in labels[c].get('segments',[]) if s['start_s']<b and s['end_s']>a and s.get('label') in ('invalid','uncertain')]
            ev=[e for e in labels[c].get('events',[]) if a<e.get('time_s',-1)<b and e.get('label') not in ('valid',)]
            if bad or ev: real[(c,round(a))]+=1
            else: wrong.append((c,k,t/1000,a,b,r['id']))
        else:
            unl[c][(k,round(t/2000)*2)].append(round((b-a),1))
print('runs',len(rows),'clips',len(cl),'touches',sum(r['touches'] for r in rows),'gaps>=3s',sum(r['gaps3'] for r in rows),'decisions',sum(len(r['kinds']) for r in rows))
print('by kind',collections.Counter(k for r in rows for k in r['kinds']))
print('second looks',sum(r['looks'] for r in rows),'overruled',sum(r['overruled'] for r in rows))
lab=[r for r in rows if r['clip'] in labels]
print('LABELLED: runs',len(lab),'clips',len({r['clip'] for r in lab}),'touches',sum(r['touches'] for r in lab),'breaks',sum(len(r['kinds']) for r in lab),'WRONG',len(wrong))
for w in wrong[:40]: print('  WRONG',w)
print('  real stops ended (clip, s): runs',sorted(real.items(),key=str))
ls=[r for r in rows if r['clip']=='long-session']
print('LONG SESSION',[(r['touches'],r['kinds'],r['times'],r['gaps3'],r['looks']) for r in ls])
print('UNLABELLED clips with breaks:')
for c,v in sorted(unl.items()):
    print(' ',c,cl[c],'runs',{f'{k[0]}@{k[1]}':f'{len(x)}x gap {min(x)}-{max(x)}' for k,x in sorted(v.items(),key=str)})
