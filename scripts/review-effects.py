#!/usr/bin/env python3
"""Verify native app exports and build a local, playable comparison gallery.
Usage: python3 scripts/review-effects.py artifacts/effects-validation
The .mp4 files and analysis.json come from EffectsVideoReview, not Python effects.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

folder = Path(sys.argv[1]).resolve()
ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
analysis = json.loads((folder / 'analysis.json').read_text())
variants = [('original-720', 'Original · SDR preview'), ('fire-original', 'Fire'),
            ('neon-gold', 'Neon + Gold'), ('ice-matrix', 'Ice + Matrix'),
            ('galaxy-chrome', 'Galaxy + Chrome'), ('classic-ball', 'Classic ball')]

def audio_hash(path):
    data = subprocess.check_output([ffmpeg, '-v', 'error', '-i', str(path), '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-'])
    return hashlib.sha256(data).hexdigest()

source_audio = audio_hash(analysis['source'])
report = {'input': analysis['source'], 'frames_analyzed': analysis['frames'],
          'detected_frames': analysis['detections'], 'exports': []}
for name, label in variants:
    video = folder / (name + '.mp4')
    probe = json.loads(subprocess.check_output([ffprobe, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(video)]))
    v = next(x for x in probe['streams'] if x['codec_type'] == 'video')
    short_edge = 720 if name == 'original-720' else 1080
    assert min(v['width'], v['height']) == short_edge, (name, v['width'], v['height'])
    assert abs(float(probe['format']['duration']) - analysis['duration']) < 0.03, name
    assert audio_hash(video) == source_audio, f'Audio changed: {name}'
    subprocess.run([ffmpeg, '-v', 'error', '-i', str(video), '-f', 'null', '-'], check=True)
    report['exports'].append({'name': name, 'width': v['width'], 'height': v['height'],
                              'duration': probe['format']['duration'], 'audio_bit_exact': True, 'full_decode': 'passed'})
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', str(video), '-vf',
                    'select=eq(n\\,240),scale=540:960', '-frames:v', '1', str(folder / (name + '.jpg'))], check=True)

args = [ffmpeg, '-v', 'error', '-y']
for name, _ in variants:
    args += ['-i', str(folder / (name + '.mp4'))]
filters = []
for i, (_, label) in enumerate(variants):
    label = label.replace('·', '/')
    filters.append(f"[{i}:v]scale=720:1280,crop=480:560:120:400,scale=360:420[v{i}]")
filters.append(''.join(f'[v{i}]' for i in range(6)) + 'xstack=inputs=6:layout=0_0|360_0|720_0|0_420|360_420|720_420[v]')
args += ['-filter_complex', ';'.join(filters), '-map', '[v]', '-map', '0:a:0', '-c:v', 'libx264', '-crf', '20',
         '-preset', 'fast', '-c:a', 'aac', '-b:a', '128k', '-movflags', '+faststart', str(folder / 'comparison.mp4')]
subprocess.run(args, check=True)
(folder / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
cards = ''.join(f'<article><h2>{label}</h2><video controls playsinline preload="metadata" poster="{name}.jpg" src="{name}.mp4"></video><a href="{name}.mp4" download>Download clip</a></article>' for name, label in variants)
(folder / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KickLab / Effects video test</title>
<style>*{box-sizing:border-box}body{margin:0;background:#061114;color:#eef8f4;font:16px system-ui}main{max-width:1200px;margin:auto;padding:40px 24px}header{max-width:780px;margin-bottom:32px}small,a{color:#62f7a8}h1{font-size:clamp(30px,5vw,56px);line-height:1.05;margin:12px 0}p{color:#a3b8b2;line-height:1.6}h2{font-size:17px;margin:0 0 16px}.hero{width:100%;border-radius:18px;margin-bottom:36px}section{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:20px}article{background:#0d2023;border:1px solid #254038;border-radius:18px;padding:18px}article video{display:block;width:100%;max-height:480px;background:#000;border-radius:12px;margin-bottom:14px}a{font-size:13px}</style>
<main><header><small>KICKLAB / REAL VIDEO VALIDATION</small><h1>One ball.<br>Five different looks.</h1><p>Rendered by the app on your supplied seven-second clip. These are exported videos using actual detector results. The comparison is cropped for a closer view; the individual downloads preserve the full frame and original audio.</p></header>
<p>Comparison order: top row — Original, Fire, Neon + Gold; bottom row — Ice + Matrix, Galaxy + Chrome, Classic.</p><video class="hero" src="comparison.mp4" controls playsinline preload="metadata"></video><section>''' + cards + '''</section><p>Known limit: this is a 2D tracked overlay. Very fast motion, weak detections and body occlusion can still affect placement. Detection coverage is not a measure of tracking accuracy.</p></main></html>''')
print(json.dumps(report, indent=2))
