#!/usr/bin/env python3
"""Make a review of the actual Vision/Metal study outputs; verify every movie."""
import json
import subprocess
from pathlib import Path

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT/'artifacts/foreground-study'
FF='/opt/homebrew/bin/ffmpeg'
PROBE='/opt/homebrew/bin/ffprobe'

def run(*args):
    return subprocess.check_output([str(a) for a in args],stderr=subprocess.STDOUT)

verification=[]
for clip in ['park','indoor']:
    folder=OUT/clip
    report=json.loads((folder/'report.json').read_text())
    for name in ['balanced','accurate','camera','mask','locked','source']:
        target=folder/f'{name}.mp4'
        run(FF,'-y','-v','error','-i',folder/f'{name}-silent.mp4','-ss',report['start'],'-i',report['source'],
            '-map','0:v:0','-map','1:a:0?','-c','copy','-t',report['duration'],'-movflags','+faststart',target)
        run(FF,'-v','error','-i',target,'-f','null','-')
        info=json.loads(run(PROBE,'-v','error','-show_streams','-show_format','-of','json',target))
        stream=next(s for s in info['streams'] if s['codec_type']=='video')
        assert int(stream['nb_frames'])==report['frames'], (clip,name)
        assert (stream['width'],stream['height'])==tuple(report['size'])
        assert abs(float(info['format']['duration'])-report['duration']) < .05
        verification.append({'clip':clip,'variant':name,'frames':int(stream['nb_frames']),
            'duration':float(info['format']['duration']),'full_decode':True,'audio':any(s['codec_type']=='audio' for s in info['streams'])})
    run(FF,'-y','-v','error','-i',folder/'source.mp4','-i',folder/'accurate.mp4','-i',folder/'camera.mp4',
        '-filter_complex','[0:v]scale=360:640[a];[1:v]scale=360:640[b];[2:v]scale=360:640[c];[a][b][c]hstack=inputs=3[v]',
        '-map','[v]','-map','0:a:0?','-c:v','libx264','-crf',18,'-preset','fast','-c:a','copy','-movflags','+faststart',folder/'comparison.mp4')
    run(FF,'-y','-v','error','-i',folder/'locked.mp4','-i',folder/'camera.mp4',
        '-filter_complex','[0:v]scale=360:640[a];[1:v]scale=360:640[b];[a][b]hstack=inputs=2[v]',
        '-map','[v]','-map','1:a:0?','-c:v','libx264','-crf',18,'-preset','fast','-c:a','copy','-movflags','+faststart',folder/'camera-comparison.mp4')
    run(FF,'-y','-v','error','-ss',2,'-i',folder/'comparison.mp4','-frames:v',1,folder/'comparison.jpg')
    run(FF,'-y','-v','error','-ss',2,'-i',folder/'camera-comparison.mp4','-frames:v',1,folder/'camera-comparison.jpg')
    run(FF,'-y','-v','error','-i',folder/'accurate.mp4','-vf','fps=1,scale=216:384,tile=7x1','-frames:v',1,folder/'motion.jpg')

(OUT/'verification.json').write_text(json.dumps(verification,indent=2)+'\n')
sections=''
for clip,title in [('park','Outdoor · distant player'),('indoor','Indoor · motion blur and fast feet')]:
    sections+=f'''<section><h2>{title}</h2><div class="labels"><span>Original</span><span>Player + ball cutout</span><span>3D camera study</span></div>
<video controls loop playsinline preload="metadata" poster="{clip}/comparison.jpg" src="{clip}/comparison.mp4"></video>
<details><summary>Compare the camera movement</summary><p>Left: locked camera. Right: gentle side drift and forward movement. Both use the same source footage and masks. This is a 2D subject plane inside a 3D scene; it does not reconstruct unseen sides of the player.</p><video controls loop playsinline preload="metadata" poster="{clip}/camera-comparison.jpg" src="{clip}/camera-comparison.mp4"></video></details>
<div class="links"><a href="{clip}/camera.mp4">Camera clip</a><a href="{clip}/accurate.mp4">Accurate cutout</a><a href="{clip}/balanced.mp4">Balanced cutout</a><a href="{clip}/mask.mp4">Combined mask</a><a href="{clip}/motion.jpg">Motion frames</a><a href="{clip}/report.json">Measurements</a></div></section>'''
(OUT/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KickLab · Foreground & camera study</title>
<style>*{box-sizing:border-box}body{margin:0;background:#071315;color:#eefaf4;font:16px system-ui}main{max-width:1140px;margin:auto;padding:40px 24px}h1{font-size:clamp(32px,6vw,60px);letter-spacing:-.04em;line-height:1.08}small,a{color:#54ecb0}p{max-width:850px;color:#b3c9c0;line-height:1.6}section{margin-top:44px}video{width:100%;display:block;background:#020705;border-radius:14px}.labels{display:grid;grid-template-columns:repeat(3,1fr);text-align:center;padding:12px 0;font-size:14px;color:#67ecc0}.links{display:flex;flex-wrap:wrap;gap:18px;margin-top:18px}a{font-size:14px}details{border:1px solid #244f45;border-radius:14px;padding:16px;margin-top:18px}summary{cursor:pointer}footer{margin-top:35px;border-top:1px solid #244f45;padding-top:20px;color:#a3bcb1}</style>
<main><small>KICKLAB / STEP 1 / ACTUAL VISION + METAL OUTPUT</small><h1>Keep the player.<br>Move the camera gently.</h1><p>Two seven-second clips, processed locally at 720 × 1280 / 30 fps. Apple Vision supplies the person mask; a separate detector-guided edge mask retains the ball. The simple stadium is a calibration scene for perspective, parallax and ground contact. It is not the final Classic Stadium design.</p><p>The camera and player plane share one projection and video clock. Original footage camera motion has not yet been solved. Ground placement is estimated, and hair, fast feet and some ball edges still need refinement before this is ready as an editor preset.</p>'''+sections+'''<footer>27 iOS tests cover camera framing, smooth motion, ground attachment, missing-foot stability, depth parallax, local ball edges and existing effects. Video processing here runs on the Mac; no iPhone runtime performance claim. Source audio excerpts are remuxed into the review clips. <a href="verification.json">Media checks</a></footer></main></html>''')
print(json.dumps(verification,indent=2))
