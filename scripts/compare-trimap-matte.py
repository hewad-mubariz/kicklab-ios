"""Local ViTMatte trial on exact traced frames. STAGES OUTPUT [frame ...]."""
import argparse,json,time
from pathlib import Path
import cv2,numpy as np,torch
from PIL import Image
from transformers import VitMatteImageProcessor,VitMatteForImageMatting

parser=argparse.ArgumentParser()
parser.add_argument('source',type=Path);parser.add_argument('out',type=Path)
parser.add_argument('frames',type=int,nargs='*',default=[60,125,150,195])
parser.add_argument('--radii',type=int,nargs='+',default=[7,15])
parser.add_argument('--edge',type=int,default=0,help='Resize longest edge before inference; 0 keeps native detail.')
parser.add_argument('--square',action='store_true',help='Pad the normalized model input to a fixed edge-square for Core ML parity.')
args=parser.parse_args();source,out=args.source,args.out;out.mkdir(parents=True,exist_ok=True)
model_id='hustvl/vitmatte-small-composition-1k'
revision='6a58ad7646403c1df626fbd746900aec7361ea1d'
processor=VitMatteImageProcessor.from_pretrained(model_id,revision=revision)
model=VitMatteForImageMatting.from_pretrained(model_id,revision=revision).eval().to('mps')
records=[]
for n in args.frames:
 image=Image.open(source/f'{n:03d}-person-source.png').convert('RGB');rgb=np.array(image)
 alpha=np.array(Image.open(source/f'{n:03d}-person-repaired.png'))/255
 guide=np.array(Image.open(source/f'{n:03d}-person-guide.png').resize(image.size,Image.Resampling.BILINEAR))/255
 for radius in args.radii:
  foreground=cv2.erode((alpha>.98).astype(np.uint8),np.ones((radius*2+1,)*2,np.uint8)) & (guide>.7)
  possible=cv2.dilate(((alpha>.01)|(guide>.1)).astype(np.uint8),np.ones((9,9),np.uint8))
  trimap=np.where(foreground,255,np.where(possible,128,0)).astype(np.uint8)
  Image.fromarray(trimap).save(out/f'{n:03d}-r{radius}-trimap.png')
  inference_image=image;inference_trimap=Image.fromarray(trimap)
  if args.edge and max(image.size)>args.edge:
   factor=args.edge/max(image.size);size=tuple(round(v*factor) for v in image.size)
   inference_image=image.resize(size,Image.Resampling.LANCZOS)
   inference_trimap=inference_trimap.resize(size,Image.Resampling.NEAREST)
  start=time.monotonic();inputs=processor(images=inference_image,trimaps=inference_trimap,return_tensors='pt').to('mps')
  if args.square:
   pixels=inputs['pixel_values'];inputs['pixel_values']=torch.nn.functional.pad(pixels,(0,args.edge-pixels.shape[-1],0,args.edge-pixels.shape[-2]))
  with torch.inference_mode():result=model(**inputs).alphas[0,0,:inference_image.height,:inference_image.width].cpu().numpy()
  if inference_image.size!=image.size:result=cv2.resize(result,image.size,interpolation=cv2.INTER_LINEAR)
  result=np.where(trimap==255,1,np.where(trimap==0,0,result))
  Image.fromarray(np.uint8(np.clip(result,0,1)*255)).save(out/f'{n:03d}-r{radius}-alpha.png')
  bg=np.array([.28,.04,.35]);composite=np.uint8(np.clip(rgb*result[:,:,None]+255*bg*(1-result[:,:,None]),0,255))
  Image.fromarray(composite).save(out/f'{n:03d}-r{radius}-composite.png')
  record={'frame':n,'radius':radius,'seconds':time.monotonic()-start};records.append(record);print(record,flush=True)
(out/'report.json').write_text(json.dumps({'model':model_id,'revision':revision,'maxEdge':args.edge,'device':'mps','records':records},indent=2))
