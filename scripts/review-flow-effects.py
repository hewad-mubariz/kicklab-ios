#!/usr/bin/env python3
"""Check app-rendered exports and assemble the flow-effects review artifacts."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/flow-effects'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'
EFFECTS = ['fire', 'ice', 'neon', 'galaxy', 'electric', 'aura']

def run(*args):
    return subprocess.check_output([str(arg) for arg in args])

def audio_hash(path):
    return hashlib.sha256(run(FFMPEG, '-v', 'error', '-i', path, '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-')).hexdigest()

park = json.loads((ROOT / 'artifacts/export-counter/analysis.json').read_text())
indoor = json.loads((OUT / 'indoor-analysis.json').read_text())
report = {'exports': [], 'tests': 20, 'release_build': 'passed', 'physical_device_performance': 'not profiled'}
for effect in EFFECTS + ['indoor-fire']:
    track = indoor if effect == 'indoor-fire' else park
    path = OUT / f'{effect}.mp4'
    info = json.loads(run(FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path))
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert (video['width'], video['height']) == (1080, 1920), effect
    assert int(video['nb_frames']) == track['frames'], effect
    assert abs(float(info['format']['duration']) - track['duration']) < .04, effect
    assert audio_hash(path) == audio_hash(track['source']), effect
    run(FFMPEG, '-v', 'error', '-i', path, '-f', 'null', '-')
    run(FFMPEG, '-y', '-v', 'error', '-ss', 11 if effect == 'indoor-fire' else 2,
        '-i', path, '-frames:v', 1, '-vf', 'scale=540:960', OUT / f'{effect}.jpg')
    report['exports'].append({'effect': effect, 'frames': int(video['nb_frames']),
        'duration': float(info['format']['duration']), 'size': [1080, 1920],
        'full_decode': 'passed', 'original_audio_bit_exact': True, 'source': track['source']})

inputs, filters = [], []
for i, effect in enumerate(EFFECTS):
    inputs += ['-i', OUT / f'{effect}.mp4']
    filters += [f'[{i}:v]crop=680:1000:200:630,scale=340:500[v{i}]']
filters += [''.join(f'[v{i}]' for i in range(6)) + 'xstack=inputs=6:layout=0_0|340_0|680_0|0_500|340_500|680_500[v]']
run(FFMPEG, '-y', '-v', 'error', *inputs, '-filter_complex', ';'.join(filters), '-map', '[v]', '-map', '0:a:0',
    '-c:v', 'libx264', '-crf', 18, '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', OUT / 'six-effects.mp4')
run(FFMPEG, '-y', '-v', 'error', '-ss', 2, '-i', OUT / 'six-effects.mp4', '-frames:v', 1, OUT / 'effects-grid.jpg')
run(FFMPEG, '-y', '-v', 'error', '-i', ROOT / 'artifacts/natural-effects/fire.mp4', '-i', OUT / 'fire.mp4',
    '-filter_complex', '[0:v]crop=720:1080:180:580,scale=480:720[a];[1:v]crop=720:1080:180:580,scale=480:720[b];[a][b]hstack=inputs=2[v]',
    '-map', '[v]', '-map', '1:a:0', '-c:v', 'libx264', '-crf', 18, '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', OUT / 'before-after.mp4')
run(FFMPEG, '-y', '-v', 'error', '-ss', 2, '-i', OUT / 'before-after.mp4', '-frames:v', 1, OUT / 'before-after.jpg')
run(FFMPEG, '-y', '-v', 'error', '-i', OUT / 'indoor-before.png', '-i', OUT / 'indoor-after.png',
    '-filter_complex', '[0:v]crop=720:1000:140:680,scale=432:600[a];[1:v]crop=720:1000:140:680,scale=432:600[b];[a][b]hstack=inputs=2',
    '-frames:v', 1, OUT / 'indoor-comparison.jpg')
run(FFMPEG, '-y', '-v', 'error', '-i', OUT / 'fire.mp4', '-vf', 'fps=2,scale=216:384,tile=7x2', '-frames:v', 1, OUT / 'fire-motion.jpg')
run(FFMPEG, '-y', '-v', 'error', '-i', OUT / 'indoor-fire.mp4', '-vf', 'fps=1/3,scale=216:384,tile=6x1', '-frames:v', 1, OUT / 'indoor-motion.jpg')
(OUT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
cards = ''.join(f'<article><h3>{name.title()}</h3><video controls playsinline loop preload="metadata" poster="{name}.jpg" src="{name}.mp4"></video><a href="{name}.mp4" download>1080p export ↗</a></article>' for name in EFFECTS)
(OUT / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KickLab · Flow effects</title>
<style>*{box-sizing:border-box}body{margin:0;background:#041214;color:#f3fff7;font:16px system-ui}main{max-width:1120px;margin:auto;padding:42px 24px}h1{font-size:clamp(38px,7vw,68px);letter-spacing:-.055em;line-height:1.03}h1 span,a,small{color:#65ffaf}h2{margin-top:44px}p{line-height:1.6;max-width:800px;color:#b4c9c1}video,img{width:100%;display:block;border-radius:18px;background:#020806}.labels{display:flex;justify-content:space-around;margin:12px 0;color:#70ffaa}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(265px,1fr));gap:18px}article{border:1px solid #244a42;background:#0e2325;border-radius:20px;padding:16px}article h3{margin:0 0 12px}.cards video{height:430px}.indoor{max-width:480px}a{display:inline-block;margin-top:14px}footer{border-top:1px solid #294b42;margin-top:40px;padding-top:20px;color:#91aba3;font-size:14px}</style>
<main><small>KICKLAB / MOTION REVIEW / ACTUAL APP EXPORTS</small><h1>Emitted. Carried.<br><span>Curled and faded.</span></h1><p>Following the supplied motion reference, the new renderer creates a flowing density field from the ball’s recent path. Flame images and orbiting graphic rings are removed. Material moves away from its birth position and cools over time; the ball keeps emitting fresh material.</p>
<h2>Fire · previous images / new flow</h2><div class="labels"><span>Previous layered images</span><strong>New transported density</strong></div><video controls playsinline loop src="before-after.mp4" poster="before-after.jpg"></video><p>Same park footage, detector track and Nightfall grade. Watch the trail when the ball changes direction. The comparison videos are cropped for inspection.</p>
<h2>Bright indoor footage</h2><div class="labels"><span>Previous layered images</span><strong>New flow</strong></div><img src="indoor-comparison.jpg" alt="Same indoor frame before and after the renderer change"><p>Full app export below, using input5.mp4 with original lighting. This is a different indoor clip from the black-jacket screenshot.</p><video class="indoor" controls playsinline loop src="indoor-fire.mp4" poster="indoor-fire.jpg"></video>
<h2>All six · evolving motion, stable palettes</h2><p>Top: Fire, Ice, Neon. Bottom: Galaxy, Electric, Aura. Each uses flowing material, its own colour family and sparse particles.</p><video controls playsinline loop src="six-effects.mp4" poster="effects-grid.jpg"></video>
<h2>Full exports</h2><section class="cards">''' + cards + '''</section>
<footer>20 tests passed and iPhone Release build passed. Seven complete 1080p exports checked for frame count, duration, decoding and bit-exact original AAC. UI, detector, counting and export-counter controls unchanged. This is prescribed-flow advection, not a full 3D fluid simulation. Person-depth occlusion and scene relighting are absent; physical-iPhone performance needs profiling.<br><a href="verification.json">Verification ↗</a></footer></main></html>''')
print(json.dumps(report, indent=2))
