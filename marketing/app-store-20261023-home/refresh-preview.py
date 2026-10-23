"""Refresh only the final 2.1-second Home scene in the user-selected preview.

Uses the existing preview's caption animation, an actual Release screenshot,
and the original AAC audio. The original file is left untouched.
Run with kicklab-lab/.venv/bin/python from the repository root.
"""
from pathlib import Path
import sys, subprocess, json, hashlib
import cv2, numpy as np

repo = Path(__file__).resolve().parents[2]
old_root = repo / 'artifacts/launch-demo-20261018/ui-v11'
sys.path.insert(0, str(old_root))
import appstore as style

source = old_root / 'appstore/Juggle-Dude-App-Preview.mp4'
home = Path(__file__).parent / 'sources/home-release-1.0.1-27.png'
out = repo / 'artifacts/releases/20261023-home-polish/store-media'
out.mkdir(parents=True, exist_ok=True)
W,H,FPS = 886,1920,30
start, duration = 25.5, 2.1
screen = cv2.cvtColor(cv2.imread(str(home)), cv2.COLOR_BGR2RGB)
screen = cv2.resize(screen, (W, round(screen.shape[0]*W/screen.shape[1])), interpolation=cv2.INTER_AREA)
y = (screen.shape[0]-H)//2
screen = screen[y:y+H].copy()
cap = style.caption_img('Beat your best')
rd = cv2.VideoCapture(str(source)); rd.set(cv2.CAP_PROP_POS_FRAMES,764)
ok,previous = rd.read(); rd.release(); assert ok
previous = cv2.cvtColor(previous, cv2.COLOR_BGR2RGB)
end = out/'home-ending.mkv'
enc = subprocess.Popen(['ffmpeg','-v','error','-y','-f','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-','-an','-c:v','ffv1',str(end)],stdin=subprocess.PIPE)
for i in range(round(duration*FPS)):
    frame = screen.copy()
    p = style.out_back((i/FPS-0.1)/0.35,1.6)
    if p > 0:
        caption = style.scaled(cap,max(0.05,0.8+0.2*p))
        style.blit(frame,caption,(W-caption.shape[1])/2,1810-caption.shape[0]/2,style.clamp(p*1.5))
    if i < 4:
        weight=(i+1)/5
        frame=(previous*(1-weight)+frame*weight).astype(np.uint8)
    enc.stdin.write(np.ascontiguousarray(frame).tobytes())
enc.stdin.close(); assert enc.wait()==0
result=out/'Juggle-Dude-App-Preview-1.0.1.mp4'
subprocess.run(['ffmpeg','-v','error','-y','-i',str(source),'-i',str(end),'-filter_complex',
    '[0:v]trim=end_frame=765,setpts=PTS-STARTPTS,setsar=1,format=yuv420p[a];[1:v]setpts=PTS-STARTPTS,setsar=1,format=yuv420p[b];[a][b]concat=n=2:v=1:a=0[v]',
    '-map','[v]','-map','0:a:0','-c:v','libx264','-preset','slow','-crf','16','-profile:v','high','-level:v','4.0',
    '-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-c:a','copy','-t','27.6','-movflags','+faststart',str(result)],check=True)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
(out/'preview-refresh.json').write_text(json.dumps({'source':str(source),'source_sha256':sha(source),'output':str(result),'output_sha256':sha(result),'home_source':str(home),'home_sha256':sha(home),'replaced_interval_seconds':[25.5,27.6],'audio':'Original AAC stream copied without re-encoding','other_content':'Same first 25.5 seconds, re-encoded for concatenation. Original file preserved.'},indent=2)+'\n')
print(result,flush=True)
