#!/usr/bin/env python3
"""Validate shipping exports and build the ten-material visual review."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/distinct-effects'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'
STYLES = ['fire', 'ice', 'neon', 'galaxy', 'electric', 'aura', 'shadow', 'rainbow', 'pixel', 'nature']
DESCRIPTIONS = [
    'Original flowing fire, with scattered embers and small detached flame flecks.',
    'A fractured frost collar and tumbling, faceted ice shards.',
    'Two bright green loops with narrow woven light trails.',
    'Violet spiral arms, drifting nebula dust and twinkling four-point stars.',
    'Branching yellow bolts with a rapid discharge and radial sparks.',
    'Fine silver rings, a quiet trailing filament and restrained shimmer.',
    'Dark drifting smoke with violet edges and expanding wisps.',
    'Seven separated spectral ribbons with multicolor particles.',
    'Cyan square particles with stepped motion and separate square fragments around the ball.',
    'Loose green vines and fluttering leaves with visible veins.',
]

def run(*args):
    return subprocess.check_output([str(a) for a in args])

def audio_hash(path):
    return hashlib.sha256(run(FFMPEG, '-v', 'error', '-i', path, '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-')).hexdigest()

track = json.loads((ROOT / 'artifacts/export-counter/analysis.json').read_text())
source_hash = audio_hash(track['source'])
report = {'exports': []}
for name in STYLES:
    path = OUT / f'{name}.mp4'
    info = json.loads(run(FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path))
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert (video['width'], video['height']) == (1080, 1920), name
    assert int(video['nb_frames']) == track['frames'], name
    assert abs(float(info['format']['duration']) - track['duration']) < .04, name
    assert audio_hash(path) == source_hash, name
    run(FFMPEG, '-v', 'error', '-i', path, '-f', 'null', '-')
    run(FFMPEG, '-y', '-v', 'error', '-ss', 2, '-i', path, '-frames:v', 1, '-vf', 'scale=540:960', OUT / f'{name}.jpg')
    run(FFMPEG, '-y', '-v', 'error', '-i', path, '-vf', 'fps=1,crop=760:1120:120:530,scale=228:336,tile=4x2', '-frames:v', 1, OUT / f'{name}-motion.jpg')
    report['exports'].append({'effect': name, 'frames': int(video['nb_frames']), 'size': [1080, 1920],
        'duration': float(info['format']['duration']), 'full_decode': 'passed', 'original_audio_bit_exact': True})
inputs, filters = [], []
for i, name in enumerate(STYLES):
    inputs += ['-i', OUT / f'{name}.mp4']
    filters += [f'[{i}:v]crop=680:1000:200:630,scale=272:400[v{i}]']
filters += [''.join(f'[v{i}]' for i in range(10)) + 'xstack=inputs=10:layout=0_0|272_0|544_0|816_0|1088_0|0_400|272_400|544_400|816_400|1088_400[v]']
run(FFMPEG, '-y', '-v', 'error', *inputs, '-filter_complex', ';'.join(filters), '-map', '[v]', '-map', '0:a:0',
    '-c:v', 'libx264', '-crf', 18, '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', OUT / 'ten-effects.mp4')
run(FFMPEG, '-y', '-v', 'error', '-ss', 2, '-i', OUT / 'ten-effects.mp4', '-frames:v', 1, OUT / 'effects-grid.jpg')
(OUT / 'verification.json').write_text(json.dumps(report, indent=2)+'\n')
cards = ''.join(f'<article><h2>{name.title()}</h2><p>{desc}</p><video controls playsinline loop preload="metadata" poster="{name}.jpg" src="{name}.mp4"></video><a href="{name}-motion.jpg">Motion contact sheet</a> · <a href="{name}.mp4" download>1080p export</a></article>' for name, desc in zip(STYLES, DESCRIPTIONS))
(OUT / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KickLab · Ten distinct effects</title>
<style>*{box-sizing:border-box}body{margin:0;background:#041214;color:#f3fff7;font:16px system-ui}main{max-width:1400px;margin:auto;padding:40px 24px}h1{font-size:clamp(34px,6vw,64px);letter-spacing:-.045em}h2{font-size:23px}p{line-height:1.6;color:#b5cbc3}a{color:#65ffaf}video{display:block;width:100%;border-radius:14px;background:#020807}.labels{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin:12px 0;text-align:center;color:#7ceeb7;font-size:13px}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(255px,1fr));gap:20px;margin-top:40px}article{border:1px solid #254a42;border-radius:18px;padding:16px}article p{min-height:77px;font-size:14px}article video{max-height:470px}article a{font-size:13px;display:inline-block;margin-top:15px}footer{margin-top:35px;border-top:1px solid #254a42;padding-top:18px;color:#9eb9ae}</style>
<main><h1>Ten effects. Ten distinct looks.</h1><p>Actual app exports using the same recorded ball track and Nightfall lighting. Fire retains its existing flow. Each other effect now has its own material geometry and particle motion. The original ball stays visible.</p>
<div class="labels"><span>Fire</span><span>Ice</span><span>Neon</span><span>Galaxy</span><span>Electric</span></div><video controls playsinline loop preload="metadata" src="ten-effects.mp4" poster="effects-grid.jpg"></video><div class="labels"><span>Aura</span><span>Shadow</span><span>Rainbow</span><span>Pixel</span><span>Nature</span></div><section class="cards">''' + cards + '''</section><footer>Full exports checked for frame count, duration, complete decoding and bit-exact source AAC. GPU tests cover distinct alpha silhouettes, deterministic pause/seek, clearing, and preview/export compositing. Physical iPhone frame rate and thermal behavior remain unprofiled. <a href="verification.json">Media verification</a></footer></main></html>''')
print(json.dumps(report, indent=2))
