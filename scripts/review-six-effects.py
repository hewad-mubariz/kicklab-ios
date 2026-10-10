#!/usr/bin/env python3
"""Validate app-produced Metal exports and create a local review page.
No effects are synthesized here; every edited video comes from BallStyleBurnIn.
"""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / 'artifacts/six-effects'
previous = root / 'artifacts/effects-validation'
analysis = json.loads((previous / 'analysis.json').read_text())
ffmpeg, ffprobe = '/opt/homebrew/bin/ffmpeg', '/opt/homebrew/bin/ffprobe'
def run(*args):
    return subprocess.check_output(list(args))
def audio_hash(path):
    return hashlib.sha256(run(ffmpeg, '-v', 'error', '-i', str(path), '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-')).hexdigest()
source_hash = audio_hash(analysis['source'])
report = {'source': analysis['source'], 'tracking': 'Existing actual detector track; no detector or counting changes', 'exports': []}
for effect in ['fire', 'ice', 'neon', 'galaxy', 'electric', 'aura', 'fire-daylight']:
    path = folder / f'{effect}.mp4'
    data = json.loads(run(ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)))
    stream = next(s for s in data['streams'] if s['codec_type'] == 'video')
    assert (stream['width'], stream['height']) == (1080, 1920), effect
    assert abs(float(data['format']['duration']) - analysis['duration']) < 0.03, effect
    assert int(stream['nb_frames']) == analysis['frames'], effect
    assert audio_hash(path) == source_hash, f'{effect}: audio changed'
    run(ffmpeg, '-v', 'error', '-i', str(path), '-f', 'null', '-')
    run(ffmpeg, '-y', '-v', 'error', '-ss', '2', '-i', str(path), '-frames:v', '1', '-vf', 'scale=540:960', str(folder / f'{effect}.jpg'))
    report['exports'].append({'effect': effect, 'size': [stream['width'], stream['height']], 'duration': float(data['format']['duration']),
        'frame_count': int(stream['nb_frames']), 'fps': stream['avg_frame_rate'], 'full_decode': 'passed', 'audio_bit_exact': True})
run(ffmpeg, '-y', '-v', 'error', '-i', str(folder / 'fire-daylight.mp4'), '-i', str(folder / 'fire.mp4'),
    '-filter_complex', '[0:v]crop=720:1080:180:580,scale=480:720[a];[1:v]crop=720:1080:180:580,scale=480:720[b];[a][b]hstack=inputs=2[v]',
    '-map', '[v]', '-map', '1:a:0', '-c:v', 'libx264', '-crf', '18', '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', str(folder / 'day-night.mp4'))
run(ffmpeg, '-y', '-v', 'error', '-ss', '2', '-i', str(folder / 'day-night.mp4'), '-frames:v', '1', str(folder / 'day-night.jpg'))
effects=['fire','ice','neon','galaxy','electric','aura']
inputs=[]
filters=[]
for i,name in enumerate(effects):
    inputs+=['-i',str(folder/f'{name}.mp4')]
    filters.append(f'[{i}:v]crop=680:1000:200:630,scale=340:500[v{i}]')
filters.append(''.join(f'[v{i}]' for i in range(6))+'xstack=inputs=6:layout=0_0|340_0|680_0|0_500|340_500|680_500[v]')
run(ffmpeg, '-y','-v','error',*inputs,'-filter_complex',';'.join(filters),'-map','[v]','-map','0:a:0','-c:v','libx264','-crf','18','-preset','fast','-c:a','copy','-movflags','+faststart',str(folder/'six-effects.mp4'))
run(ffmpeg,'-y','-v','error','-ss','2','-i',str(folder/'six-effects.mp4'),'-frames:v','1',str(folder/'effects-grid.jpg'))
report['environment']='Nightfall (cooler, darker original park); Fire daylight is the original lighting comparison'
report['validation']={'unit_tests':14,'metal_gpu_tests':5,'simulator':'iPhone 17 Pro, iOS 26.5','device_build':'Release build passed; physical hardware performance not profiled'}
(folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
cards=''.join(f'<article><h3>{name.title()}</h3><video controls playsinline loop preload="metadata" poster="{name}.jpg" src="{name}.mp4"></video><a href="{name}.mp4" download>Full video · 1080p ↗</a></article>' for name in effects)
(folder/'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Juggle Dude · Six effects / Nightfall</title>
<style>*{box-sizing:border-box}body{margin:0;background:#041214;color:#f3fff7;font:16px system-ui}main{max-width:1160px;margin:auto;padding:44px 24px}h1{font-size:clamp(38px,7vw,70px);letter-spacing:-.055em;line-height:1.02;margin:20px 0}h1 span,small,a{color:#65ffaf}h2{font-size:28px;margin-top:44px}p{line-height:1.6;max-width:790px;color:#b4c9c1}.labels{display:flex;justify-content:space-around;margin:12px 0;color:#70ffaa}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:18px}article{background:#0e2325;border:1px solid #244a42;border-radius:20px;padding:16px}article h3{margin:0 0 12px}video,img{width:100%;display:block;border-radius:16px;background:#020806}.cards video{height:400px}a{display:inline-block;margin-top:12px;font-size:13px}.ui{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:20px}.ui img{max-height:700px;object-fit:contain}footer{border-top:1px solid #294b42;margin-top:40px;padding-top:20px;font-size:13px;color:#91aba3}@media(max-width:640px){main{padding:28px 16px}.ui{grid-template-columns:1fr}.ui img{max-height:640px}}</style>
<main><small>JUGGLE DUDE / REAL CLIP / METAL EFFECTS</small><h1>Six effects.<br><span>A darker park.</span></h1><p>Your supplied footage, with the original ball and detector track. Fire extends above and below the ball. Ice, Neon, Galaxy, Electric and Aura each have their own particles and energy pattern. Nightfall cools and darkens the existing footage.</p>
<h2>Fire · daylight versus Nightfall</h2><div class="labels"><span>Original lighting</span><strong>Nightfall</strong></div><video controls loop playsinline src="day-night.mp4" poster="day-night.jpg"></video>
<h2>All six · same moment</h2><p>Top: Fire, Ice, Neon. Bottom: Galaxy, Electric, Aura. Cropped to inspect detail.</p><video controls loop playsinline src="six-effects.mp4" poster="effects-grid.jpg"></video>
<h2>Full exports</h2><section class="cards">'''+cards+'''</section>
<h2>In the app</h2><div class="ui"><img src="effect-picker.png" alt="Six-effect picker with new artwork"><img src="environment-ui.png" alt="Original and Nightfall environment controls"><img src="share-ui.png" alt="Edited save and share preview"></div><p>Choose an effect in Replay &amp; Effects → View all. Switch the park treatment in Environment → Nightfall. The edited share preview and exported clip use the same grade and shaders.</p>
<h2>Updated picker artwork</h2><img src="artwork.jpg" alt="Six cinematic effect-card illustrations"><p>Generated concept artwork for the picker. The videos above show the actual runtime rendering.</p><a href="image-prompts.json">Artwork paths and generation prompts ↗</a>
<footer>Verified: 422 frames per export, 1080 × 1920, complete 7.04-second duration, full decode, bit-exact original AAC audio, 14 GPU/tracking tests and iPhone Release build. Replay renders video and effects from the same decoded-frame timestamp. This remains a 2D effect: no person-depth occlusion or stadium replacement. Physical-iPhone performance still needs profiling.</footer></main></html>''')
print(json.dumps(report,indent=2))
