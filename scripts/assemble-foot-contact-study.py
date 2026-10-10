#!/usr/bin/env python3
"""Compare the existing prototype to the visible-foot contact correction."""
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/foot-contact-study'
STUDY = ROOT / 'artifacts/foreground-study'
FF = '/opt/homebrew/bin/ffmpeg'
PROBE = '/opt/homebrew/bin/ffprobe'

def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT)

checks = []
sections = ''
for clip, title in [('park', 'Outdoor'), ('indoor', 'Indoor')]:
    folder = OUT / clip
    shutil.copy2(STUDY / clip / 'camera.mp4', folder / 'after.mp4')
    run(FF, '-y', '-v', 'error', '-i', folder / 'before.mp4', '-i', folder / 'after.mp4',
        '-filter_complex', '[0:v]scale=360:640[a];[1:v]scale=360:640[b];[a][b]hstack=inputs=2[v]',
        '-map', '[v]', '-map', '1:a:0?', '-c:v', 'libx264', '-crf', 18, '-preset', 'fast',
        '-c:a', 'copy', '-movflags', '+faststart', folder / 'comparison.mp4')
    run(FF, '-v', 'error', '-i', folder / 'comparison.mp4', '-f', 'null', '-')
    info = json.loads(run(PROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', folder / 'comparison.mp4'))
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert int(video['nb_frames']) == 210
    assert abs(float(info['format']['duration']) - 7) < 0.05
    assert any(s['codec_type'] == 'audio' for s in info['streams'])
    checks.append({'clip': clip, 'frames': 210, 'full_decode': True, 'audio': True})
    run(FF, '-y', '-v', 'error', '-ss', 2, '-i', folder / 'comparison.mp4', '-frames:v', 1, folder / 'poster.jpg')
    sections += f'''<section><h2>{title}</h2><div class="labels"><span>Previous placement</span><span>Visible-foot contact</span></div>
<video controls loop playsinline preload="metadata" poster="{clip}/poster.jpg" src="{clip}/comparison.mp4"></video></section>'''

(OUT / 'verification.json').write_text(json.dumps(checks, indent=2) + '\n')
(OUT / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Juggle Dude · Foot contact correction</title><style>*{box-sizing:border-box}body{margin:0;background:#071315;color:#eefaf4;font:16px system-ui}main{max-width:960px;margin:auto;padding:36px 24px}h1{font-size:clamp(30px,5vw,52px);letter-spacing:-.035em}p{color:#bdcdc6;line-height:1.6}small,a{color:#54ecb0}section{margin:36px 0}video,img{display:block;width:100%;border-radius:12px;background:#020705}.labels{display:grid;grid-template-columns:repeat(2,1fr);text-align:center;padding:12px 0;color:#67ecc0}figcaption{font-size:14px;color:#bdcdc6;margin:12px 0}figure{margin:24px 0}footer{border-top:1px solid #244f45;padding-top:18px;color:#a3bcb1}</style>
<main><small>JUGGLE DUDE / FOOT CONTACT STUDY</small><h1>Why the foot looks buried</h1><p>The original outdoor grass already hides the bottom of the standing foot. Apple Vision removes the surrounding background, but it cannot reveal the missing toes. The crop below shows the original, cutout, mask and previous scene, from left to right.</p>
<figure><img src="diagnosis.png" alt="Original grass hiding the standing foot, then the cutout, alpha mask and previous stadium composite"><figcaption>Original → cutout → alpha mask → previous stadium. The incomplete foot shape is already present in the source.</figcaption></figure>
<p>The revised prototype estimates the visible supporting boundary from connected lower-leg pixels. It uses that point for foreground depth and a tighter contact shadow, while leaving the scene camera unchanged. If a foot disappears or the estimate jumps, it holds the last depth and fades the shadow. No body or foot pixels are generated.</p>'''+sections+'''<footer>27 iOS tests pass. These two seven-second videos preserve the source-audio excerpts. The contact estimate is still a single-player heuristic, not a complete foot-pose, jump or 3D-depth solution. Hidden toes and uncertain mask edges remain unresolved. <a href="verification.json">Media verification</a></footer></main></html>''')
print(json.dumps(checks, indent=2))
