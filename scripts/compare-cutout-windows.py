"""Compare exact captured person windows; flow scores are stability proxies, not accuracy.

ROOT contains baseline/stages, vitmatte-sequence and rvm-person. Every method
uses the exact source RGB for alpha-only comparisons; the saved ball branch is
identical in all full-frame composites. No segmentation ground truth is assumed.
"""
import json,sys
from pathlib import Path
import cv2,numpy as np
from PIL import Image,ImageDraw

root=Path(sys.argv[1]);stages=root/'baseline/stages';out=root/'window-review';out.mkdir(exist_ok=True)
manifest=json.loads((stages/'stages.json').read_text());records={(r['frame'],r['stage']):r for r in manifest}
frames=sorted({r['frame'] for r in manifest});rows=[];previous=None
methods=['native','spatial','temporal','vitmatte','rvm']
engine=cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
def alpha(path,size):return np.asarray(Image.open(path).convert('L').resize(size,Image.Resampling.BILINEAR),np.float32)/255
def regions(n):
 if n<100:return {'hair':(540,130,760,355),'hand':(795,585,960,770)}
 if n<140:return {'hair':(470,175,695,420),'hand':(680,575,785,750)}
 return {'hair':(530,135,730,355),'hand':(835,565,980,730)}
def display(rgb,a,bg):
 srgb=rgb/255;linear=np.where(srgb<=.04045,srgb/12.92,((srgb+.055)/1.055)**2.4)
 bg=np.array(bg);bl=np.where(bg<=.04045,bg/12.92,((bg+.055)/1.055)**2.4)
 c=linear*a[:,:,None]+bl*(1-a[:,:,None]);c=np.where(c<=.0031308,c*12.92,1.055*c**(1/2.4)-.055)
 return Image.fromarray(np.uint8(np.clip(c*255,0,255)))
for n in frames:
 source=Image.open(stages/f'{n:03d}-person-source.png').convert('RGB');rgb=np.asarray(source);w,h=source.size
 masks={k:alpha(p,source.size) for k,p in {
  'native':stages/f'{n:03d}-person-repaired.png','spatial':stages/f'{n:03d}-spatial-alpha.png',
  'temporal':stages/f'{n:03d}-refined-alpha.png','vitmatte':root/f'vitmatte-sequence/{n:03d}-r31-alpha.png',
  'rvm':root/f'rvm-person/{n:03d}-alpha.png'}.items()}
 gray=cv2.cvtColor(rgb,cv2.COLOR_RGB2GRAY)
 # Person-only ROIs have no ball. Shared ball is added only to full-frame views.
 if previous is not None and previous[0]==n-1:
  _,oldgray,oldrgb,oldmasks=previous;flow=engine.calc(gray,oldgray,None)
  xx,yy=np.meshgrid(np.arange(w,dtype=np.float32),np.arange(h,dtype=np.float32));mx,my=xx+flow[:,:,0],yy+flow[:,:,1]
  photo=np.max(np.abs(rgb.astype(float)-cv2.remap(oldrgb,mx,my,cv2.INTER_LINEAR)),axis=2)<20
  warped={k:cv2.remap(a,mx,my,cv2.INTER_LINEAR) for k,a in oldmasks.items()}
  boundary=np.zeros((h,w),np.uint8)
  for a in [*masks.values(),*warped.values()]:boundary|=((a>.01)&(a<.99)).astype(np.uint8)
  boundary=cv2.dilate(boundary,np.ones((5,5),np.uint8)).astype(bool)
  for region,(x0,y0,x1,y1) in regions(n).items():
   eligible=photo[y0:y1,x0:x1]&boundary[y0:y1,x0:x1]
   row={'frame':n,'region':region,'eligible':int(eligible.sum())}
   for k in methods:
    delta=np.abs(masks[k]-warped[k])[y0:y1,x0:x1]
    row[k]={'sum':float(delta[eligible].sum()),'large':int(((delta>.5)&eligible).sum())}
   rows.append(row)
 previous=(n,gray,rgb,masks)
 if n in [55,60,65,120,125,130,145,150,155]:
  panel=Image.new('RGB',(6*240,2*285),'#eeeeee');draw=ImageDraw.Draw(panel)
  for r,(name,box) in enumerate(regions(n).items()):
   views=[('source',source)]+[(k,display(rgb,masks[k],[.28,.04,.35])) for k in methods]
   for c,(label,im) in enumerate(views):
    crop=im.crop(box);crop.thumbnail((235,250));panel.paste(crop,(c*240,r*285+30));draw.text((c*240+4,r*285+8),f'{n} {name}: {label}',fill='black')
  panel.save(out/f'{n:03d}-regions.jpg')
 if n in [60,125,150,195]:
  personRect=records[n,'person-source']['rect'];ball=records.get((n,'ball'));shared=np.zeros((h,w),np.float32)
  if ball:
   ba=alpha(stages/ball['file'],(ball['width'],ball['height']));x,y,bw,bh=ball['rect'];px,py,pw,ph=personRect
   transform=np.float32([[bw/pw*w/ba.shape[1],0,(x-px)/pw*w],[0,bh/ph*h/ba.shape[0],(y-py)/ph*h]])
   shared=cv2.warpAffine(ba,transform,(w,h),flags=cv2.INTER_LINEAR)
  panel=Image.new('RGB',(4*360,470),'#eeeeee');draw=ImageDraw.Draw(panel)
  for c,k in enumerate(['native','temporal','vitmatte','rvm']):
   im=display(rgb,np.maximum(masks[k],shared),[.28,.04,.35]);im.thumbnail((355,435));panel.paste(im,(c*360,30));draw.text((c*360+5,8),f'{n} / {k} / shared ball',fill='black')
  panel.save(out/f'{n:03d}-shared-ball.jpg')
summary={region:{k:{'meanChange':sum(r[k]['sum'] for r in rows if r['region']==region)/max(1,sum(r['eligible'] for r in rows if r['region']==region)),
 'largeChanges':sum(r[k]['large'] for r in rows if r['region']==region)} for k in methods} for region in ['hair','hand']}
(out/'stability.json').write_text(json.dumps({'note':'Unlabeled flow proxy; same eligible pixels per method. Less alpha change does not establish better segmentation. Methods spatial/temporal include production edge processing; candidate methods here do not. RVM input is the earlier SDR crop movie, so it also differs in source compression.','summary':summary,'rows':rows},indent=2))
print(json.dumps(summary,indent=2))
