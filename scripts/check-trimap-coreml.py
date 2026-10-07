"""Compare local Core ML output with the exact fixed-size PyTorch experiment."""
import json,sys,time
from pathlib import Path
import cv2,numpy as np,coremltools as ct
from PIL import Image
root=Path(sys.argv[1]);out=root/'coreml-check';out.mkdir(exist_ok=True)
start=time.monotonic();model=ct.models.MLModel(str(root/'PersonMatteRefiner.mlpackage'),compute_units=ct.ComputeUnit.CPU_AND_GPU)
print('Loaded model in',time.monotonic()-start,flush=True);rows=[]
for n in [60,125,150,195]:
 image=Image.open(root/f'baseline/stages/{n:03d}-person-source.png').convert('RGB');factor=768/max(image.size);size=tuple(round(v*factor) for v in image.size)
 trimap=Image.open(root/f'vitmatte-sequence/{n:03d}-r31-trimap.png');rgb=np.array(image.resize(size,Image.Resampling.LANCZOS),np.float32)
 small=np.array(trimap.resize(size,Image.Resampling.NEAREST),np.float32)
 pixels=np.zeros((1,4,768,768),np.float32);pixels[0,:3,:size[1],:size[0]]=(rgb/127.5-1).transpose(2,0,1);pixels[0,3,:size[1],:size[0]]=small/255
 start=time.monotonic();result=model.predict({'pixels':pixels})['alpha'][0,0,:size[1],:size[0]];elapsed=time.monotonic()-start
 assert np.isfinite(result).all(),'Non-finite Core ML alpha'
 result=cv2.resize(result,image.size,interpolation=cv2.INTER_LINEAR);t=np.array(trimap)
 result=np.where(t==255,1,np.where(t==0,0,result));expected=np.array(Image.open(root/f'vitmatte-sequence/{n:03d}-r31-alpha.png'),np.float32)/255
 delta=np.abs(result-expected);row={'frame':n,'seconds':elapsed,'meanError':float(delta.mean()),'maxError':float(delta.max()),'p99Error':float(np.quantile(delta,.99))};rows.append(row);print(row,flush=True)
 Image.fromarray(np.uint8(np.clip(result*255,0,255))).save(out/f'{n:03d}-alpha.png')
(out/'report.json').write_text(json.dumps(rows,indent=2))
