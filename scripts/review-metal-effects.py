#!/usr/bin/env python3
"""Validate app-produced Metal exports and create a local review page.
No effects are synthesized here; every edited video comes from BallStyleBurnIn.
"""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
folder = root / 'artifacts/metal-effects'
previous = root / 'artifacts/effects-validation'
analysis = json.loads((previous / 'analysis.json').read_text())
ffmpeg, ffprobe = '/opt/homebrew/bin/ffmpeg', '/opt/homebrew/bin/ffprobe'
def run(*args):
    return subprocess.check_output(list(args))
def audio_hash(path):
    return hashlib.sha256(run(ffmpeg, '-v', 'error', '-i', str(path), '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-')).hexdigest()
source_hash = audio_hash(analysis['source'])
report = {'source': analysis['source'], 'tracking': 'Existing actual detector track; no detector or counting changes', 'exports': []}
for effect in ['fire', 'ice', 'neon', 'galaxy']:
    path = folder / f'{effect}.mp4'
    data = json.loads(run(ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)))
    stream = next(s for s in data['streams'] if s['codec_type'] == 'video')
    assert (stream['width'], stream['height']) == (1080, 1920), effect
    assert abs(float(data['format']['duration']) - analysis['duration']) < 0.03, effect
    assert audio_hash(path) == source_hash, f'{effect}: audio changed'
    run(ffmpeg, '-v', 'error', '-i', str(path), '-f', 'null', '-')
    run(ffmpeg, '-y', '-v', 'error', '-ss', '2', '-i', str(path), '-frames:v', '1', '-vf', 'scale=540:960', str(folder / f'{effect}.jpg'))
    report['exports'].append({'effect': effect, 'size': [stream['width'], stream['height']], 'duration': float(data['format']['duration']),
        'frame_count': int(stream['nb_frames']), 'fps': stream['avg_frame_rate'], 'full_decode': 'passed', 'audio_bit_exact': True})
run(ffmpeg, '-y', '-v', 'error', '-i', str(previous / 'fire-original.mp4'), '-i', str(folder / 'fire.mp4'),
    '-filter_complex', '[0:v]crop=720:1080:180:380,scale=480:720[a];[1:v]crop=720:1080:180:380,scale=480:720[b];[a][b]hstack=inputs=2[v]',
    '-map', '[v]', '-map', '1:a:0', '-c:v', 'libx264', '-crf', '18', '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', str(folder / 'before-after.mp4'))
run(ffmpeg, '-y', '-v', 'error', '-ss', '2', '-i', str(folder / 'before-after.mp4'), '-frames:v', '1', str(folder / 'before-after.jpg'))
(folder / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
cards = ''.join(f'<article><h3>{name.title()}</h3><video controls playsinline preload="metadata" poster="{name}.jpg" src="{name}.mp4"></video><a href="{name}.mp4" download>1080p · original audio ↗</a></article>' for name in ['fire', 'ice', 'neon', 'galaxy'])
(folder / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Juggle Dude · Metal effects review</title>
<style>*{box-sizing:border-box}body{margin:0;background:#071113;color:#effff5;font:16px system-ui}main{max-width:1160px;padding:48px 24px;margin:auto}small,a{color:#60f69e}h1{font-size:clamp(40px,7vw,76px);letter-spacing:-.06em;line-height:1;margin:20px 0}h1 span{color:#73ffa7}p{color:#a1b6b1;max-width:760px;line-height:1.6}h2{margin-top:48px;font-size:28px;letter-spacing:-.025em}.labels{display:grid;grid-template-columns:1fr 1fr;padding:14px;text-align:center;color:#c3d6ce}.labels strong{color:#70ffa6}video,img{display:block;width:100%;border-radius:16px;background:#010506}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px}article{background:#102022;padding:16px;border:1px solid #294038;border-radius:20px}article h3{margin:0 0 12px}article video{max-height:400px}a{display:inline-block;margin-top:14px;font-size:13px}button{background:#5dffa0;color:#021b10;border:0;border-radius:30px;padding:14px 24px;font-size:15px;font-weight:700;cursor:pointer}.counter{display:grid;grid-template-columns:minmax(0,420px) 1fr;gap:32px;align-items:center}.counter video{max-height:750px}.note{font-size:13px;border-top:1px solid #294038;padding-top:20px;margin-top:40px}@media(max-width:650px){.counter{grid-template-columns:1fr}main{padding:28px 16px}}</style>
<main><small>JUGGLE DUDE / METAL RENDERER / REAL FOOTAGE</small><h1>Fire with <span>depth.</span><br>Touches with energy.</h1><p>New combustion, embers and bloom, rendered by the app on your supplied seven-second video. The original ball and the existing detector track are preserved.</p><h2>Fire · before / after</h2><div class="labels"><span>Previous vector effect</span><strong>New Metal effect</strong></div><video src="before-after.mp4" poster="before-after.jpg" controls loop playsinline></video><p>The comparison is cropped to show detail. Full-frame exports are below.</p><h2>Counter · a burst for each touch</h2><div class="counter"><video src="counter.mp4" poster="counter-ui.png" controls loop muted playsinline></video><div><p>The shipping HUD uses a larger mint-to-white number, 210 GPU particles, a brief bloom pulse and a brighter milestone pill. Sparks disperse and settle between touches.</p><p>This counter preview uses scripted touches over a still frame to inspect the graphics. It is not a count-accuracy test. Reduced Motion disables the expanding burst.</p></div></div><h2>One rendering pipeline</h2><p>Fire received the detailed visual tuning. Ice, Neon and Galaxy now use the same GPU particle and bloom pipeline, each with its own field.</p><section class="cards">''' + cards + '''</section><p class="note">Validation: 1080 × 1920 exports, complete clip duration, successful full decode, and bit-exact source AAC audio. GPU regression tests cover repeatable timestamps, zero-intensity clearing, count-burst decay, and preview/export compositing. iPhone simulator tested; physical-device thermal and frame-rate profiling remains. Effects follow a 2D track and do not use person-depth occlusion.</p></main></html>''')
print(json.dumps(report, indent=2))
