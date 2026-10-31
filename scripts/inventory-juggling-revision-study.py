#!/usr/bin/env python3
"""Inventory existing raw juggling sources by content, retaining every alias."""
import concurrent.futures,hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'artifacts/vision-revisions-20261029'
RELEASE=Path('/Users/hewadmubariz/.codex/worktrees/touch-counter-release/kicklab')
PRIMARY=Path('/Users/hewadmubariz/Desktop/projects/kicklab')
CORPUS=Path('/Users/hewadmubariz/Desktop/projects/kicklab-lab/data/v2/rfdetr-juggling-corpus-001')
roots=[RELEASE/'artifacts',PRIMARY/'artifacts',CORPUS]
if (OUT/'phone-backups').exists():roots.append(OUT/'phone-backups')
paths=[]; excluded=[]
for root in roots:
 r=subprocess.run(['rg','--files','--hidden','--no-ignore','-g','*.mov','-g','*.MOV','-g','*.mp4','-g','!**/*.xcarchive/**',str(root)],capture_output=True,text=True,check=True)
 for p in map(Path,r.stdout.splitlines()):
  rel=str(p.relative_to(root))
  include=(root==CORPUS or (root==RELEASE/'artifacts' and not p.name.startswith('export-'))
    or p.name in ['source.mov','source.mp4','input.mov'] or '/inputs/' in rel)
  if p.suffix.lower()=='.mp4' and root!=CORPUS and p.name not in ['source.mp4']:include=False
  if '/launch-demo-20261018/' in str(p) and 'shot' in str(p):include=False
  if include:paths.append(p)
  else:excluded.append({'path':str(p),'reason':'Rendered/effects output or non-source artifact; retained in inventory, excluded from raw-source comparison.'})
for name in ['IMG_8606 3.MOV','IMG_8878.MOV','IMG_8880 3.MOV']:
 p=Path('/Users/hewadmubariz/Downloads')/name
 if p.exists():paths.append(p)
inodes={};missing=[]
for p in dict.fromkeys(paths):
 try:s=p.stat()
 except OSError:missing.append(str(p));continue
 key=(s.st_dev,s.st_ino)
 inodes.setdefault(key,{'paths':[],'bytes':s.st_size})['paths'].append(str(p))
def digest(row):
 h=hashlib.sha256()
 with open(row['paths'][0],'rb') as f:
  for b in iter(lambda:f.read(8*1024*1024),b''):h.update(b)
 return h.hexdigest(),row
by_hash={}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
 for sha,row in pool.map(digest,inodes.values()):
  group=by_hash.setdefault(sha,{'sha256':sha,'bytes':row['bytes'],'aliases':[]})
  group['aliases']+=row['paths']
manifest=json.loads((ROOT/'benchmarks/touch-counting/corpus-20261014/manifest.json').read_text())
labels={c['sha256']:c for c in manifest['clips']}
rows=[]
for sha,row in by_hash.items():
 aliases=sorted(row['aliases'],key=lambda p:(0 if '/FinalValidation/' in p else 1 if str(CORPUS) in p else 2,len(p)))
 row['aliases']=aliases;row['source']=aliases[0]
 probe=subprocess.run(['ffprobe','-v','error','-select_streams','v:0','-show_entries','format=duration:stream=width,height,avg_frame_rate','-of','json',row['source']],capture_output=True,text=True)
 if probe.returncode:row['probeError']=probe.stderr
 else:
  meta=json.loads(probe.stdout);row['duration']=float(meta['format']['duration']);row['video']=meta.get('streams',[{}])[0]
 old=labels.get(sha)
 row['id']=old['id'] if old else 'clip-'+sha[:12]
 row['labelFile']=str(ROOT/'benchmarks/touch-counting/corpus-20261014/labels'/f"{old['id']}.json") if old else None
 row['referenceCoverage']='reviewed_with_uncertainty' if old else 'partial_or_unreviewed'
 row['state']='ready' if 'duration' in row else 'unreadable'
 rows.append(row)
rows.sort(key=lambda r:(r['duration'],r['id']))
missing_expected=[{'id':c['id'],'source':c['source'],'sha256':c['sha256']} for c in manifest['clips'] if c['sha256'] not in by_hash]
result={'scope':'All locally backed-up source videos from release/primary artifacts, original 23-file juggling corpus including intake recordings, and the three user-named clips. Content-identical copies deduplicated. Phone-only and external-drive footage require separate reconciliation.','clips':rows,'totals':{'uniqueSources':len(rows),'aliases':sum(len(r['aliases']) for r in rows),'sourceMinutes':round(sum(r.get('duration',0) for r in rows)/60,2),'labelledOriginalCorpusSources':sum(r['labelFile'] is not None for r in rows)},'missingExpectedOriginalCorpus':missing_expected,'missingPaths':missing,'excludedRenderedArtifacts':excluded}
OUT.mkdir(parents=True,exist_ok=True)
(OUT/'corpus-inventory.json').write_text(json.dumps(result,indent=2)+'\n')
(ROOT/'benchmarks/touch-counting/vision-revisions-20261029/corpus-inventory.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result['totals'],indent=2));print('Missing known original corpus:',len(missing_expected))
for r in rows:print(r['id'],round(r.get('duration',0),3),Path(r['source']).name,len(r['aliases']),flush=True)
