"""Official dynamic RVM, consecutive SDR native-detail crops; no uploads.

SOURCE.mp4 MODEL.torchscript OUTPUT_FOLDER [ratio]
"""
import json
import sys
import time
from pathlib import Path
import cv2
import numpy as np
import torch
from PIL import Image

source, model_path, output = sys.argv[1:4]
ratio = float(sys.argv[4]) if len(sys.argv)>4 else .6
folder=Path(output);folder.mkdir(parents=True,exist_ok=True)
device="mps" if torch.backends.mps.is_available() else "cpu"
model=torch.jit.load(model_path,map_location=device).eval()
capture=cv2.VideoCapture(source)
width,height=int(capture.get(cv2.CAP_PROP_FRAME_WIDTH)),int(capture.get(cv2.CAP_PROP_FRAME_HEIGHT))
writer=cv2.VideoWriter(str(folder/'composite.mp4'),cv2.VideoWriter_fourcc(*'mp4v'),30,(width,height))
recurrent=[None]*4
count=0;timings=[];start=time.monotonic()
with torch.inference_mode():
    while True:
        ok,bgr=capture.read()
        if not ok:break
        rgb=cv2.cvtColor(bgr,cv2.COLOR_BGR2RGB)
        tensor=torch.from_numpy(rgb).permute(2,0,1).unsqueeze(0).float().to(device)/255
        before=time.monotonic()
        foreground,alpha,*recurrent=model(tensor,*recurrent,ratio)
        f=foreground[0].permute(1,2,0).cpu().numpy();a=alpha[0,0].cpu().numpy()
        timings.append(time.monotonic()-before)
        composite=np.uint8(np.clip((f*a[:,:,None]+np.array([.28,.04,.35])*(1-a[:,:,None]))*255,0,255))
        writer.write(cv2.cvtColor(composite,cv2.COLOR_RGB2BGR))
        if count%15==0 or 55<=count<=65 or 120<=count<=130 or 145<=count<=155 or count==195:
            Image.fromarray(composite).save(folder/f'{count:03d}-composite.png')
            Image.fromarray(np.uint8(a*255)).save(folder/f'{count:03d}-alpha.png')
            Image.fromarray(np.uint8(np.clip(f*255,0,255))).save(folder/f'{count:03d}-foreground.png')
        count+=1
        if count%30==0:print('frame',count,'seconds',round(time.monotonic()-start,1),flush=True)
writer.release();capture.release()
(folder/'report.json').write_text(json.dumps({'frames':count,'device':device,'input':[width,height],'ratio':ratio,'meanMs':np.mean(timings)*1000,'elapsed':time.monotonic()-start,'note':'Official dynamic TorchScript model; recurrent states retained; local comparison only.'},indent=2))
