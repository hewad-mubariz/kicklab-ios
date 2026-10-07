#!/usr/bin/env python3
"""Verify the ten app exports on input4 and build a synchronized daylight review."""
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/player-effects'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'
STYLES = ['fire', 'ice', 'neon', 'galaxy', 'electric', 'aura', 'shadow', 'rainbow', 'pixel', 'nature']
DESCRIPTIONS = [
    'Existing flowing fire and embers retained.',
    'Fractured frost, tumbling crystals and cold mist around the player.',
    'Brighter emerald tubes, moving highlights and wide ribbons around the body.',
    'Purple and blue nebula, spiral dust and scattered twinkling stars.',
    'Long golden discharges, branching sparks and ball-centered arcs.',
    'Layered silver filaments and fine shimmer through the lower body.',
    'Charcoal smoke with torn violet edges around the legs and shoulders.',
    'Seven separated colored ribbons and scattered spectral particles.',
    'Broken cyan voxel streams and square debris with stepped motion.',
    'Irregular green vines and fluttering leaves with visible veins.',
]

def run(*args):
    return subprocess.check_output([str(a) for a in args])

def probe(path):
    return json.loads(run(FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path))

def audio_hash(path):
    return hashlib.sha256(run(FFMPEG, '-v', 'error', '-i', path, '-map', '0:a:0', '-c:a', 'copy', '-f', 'adts', '-')).hexdigest()

track = json.loads((OUT / 'analysis.json').read_text())
source = Path(track['source'])
source_info = probe(source)
source_video = next(s for s in source_info['streams'] if s['codec_type'] == 'video')
source_audio = audio_hash(source)
shutil.copyfile(source, OUT / 'input4-original.mp4')
report = {'source': str(source), 'lighting': 'Original daylight, no Nightfall grade', 'intensity': 0.85,
          'analyzed_frames': track['frames'], 'player_boxes': sum('personX' in row for row in track['track']), 'exports': []}
for name in STYLES:
    path = OUT / f'{name}.mp4'
    info = probe(path)
    video = next(s for s in info['streams'] if s['codec_type'] == 'video')
    assert (video['width'], video['height']) == (720, 1280), name
    assert int(video['nb_frames']) == int(source_video['nb_frames']), name
    assert abs(float(info['format']['duration']) - float(source_info['format']['duration'])) < .05, name
    assert audio_hash(path) == source_audio, name
    run(FFMPEG, '-v', 'error', '-i', path, '-f', 'null', '-')
    run(FFMPEG, '-y', '-v', 'error', '-ss', 4, '-i', path, '-frames:v', 1, OUT / f'{name}.png')
    run(FFMPEG, '-y', '-v', 'error', '-i', path, '-vf', 'fps=1/2,crop=500:825:195:325,scale=200:330,tile=4x2', '-frames:v', 1, OUT / f'{name}-motion.jpg')
    report['exports'].append({'style': name, 'size': [720, 1280], 'frames': int(video['nb_frames']),
        'duration': float(info['format']['duration']), 'full_decode': 'passed', 'original_audio_bit_exact': True})
    print(f'{name}: verified', flush=True)

inputs, filters = [], []
for i, name in enumerate(STYLES):
    inputs += ['-i', OUT / f'{name}.mp4']
    filters += [f'[{i}:v]crop=500:825:195:325,scale=240:396[v{i}]']
filters += [''.join(f'[v{i}]' for i in range(10)) + 'xstack=inputs=10:layout=0_0|240_0|480_0|720_0|960_0|0_396|240_396|480_396|720_396|960_396[v]']
run(FFMPEG, '-y', '-v', 'error', *inputs, '-filter_complex', ';'.join(filters), '-map', '[v]', '-map', '0:a:0',
    '-c:v', 'libx264', '-crf', 18, '-preset', 'fast', '-c:a', 'copy', '-movflags', '+faststart', OUT / 'input4-ten-effects.mp4')
run(FFMPEG, '-y', '-v', 'error', '-ss', 4, '-i', OUT / 'input4-ten-effects.mp4', '-frames:v', 1, OUT / 'daylight-grid.jpg')
(OUT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
buttons = ''.join(f'<button data-style="{n}" aria-pressed="{str(n == "neon").lower()}">{n.title()}</button>' for n in STYLES)
cards = ''.join(f'<article><h2>{n.title()}</h2><p>{d}</p><video controls playsinline preload="none" poster="{n}.png" src="{n}.mp4"></video><a href="{n}.mp4" download>Full video</a> · <a href="{n}-motion.jpg">Motion sheet</a></article>' for n, d in zip(STYLES, DESCRIPTIONS))
(OUT / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>KickLab · Input 4 effects review</title>
<style>*{box-sizing:border-box}body{margin:0;background:#061316;color:#f5fff9;font:16px system-ui}main{max-width:1320px;margin:auto;padding:36px 24px}h1{font-size:clamp(32px,5vw,58px);letter-spacing:-.045em;margin-bottom:12px}p{line-height:1.6;color:#b9cec5}small,a{color:#66ffb7}button{font:inherit;background:#122a29;color:#d9eee5;border:1px solid #34534a;border-radius:24px;padding:10px 18px;cursor:pointer}button[aria-pressed=true]{background:#55fbb2;color:#03130c;border-color:#55fbb2}nav{display:flex;flex-wrap:wrap;gap:8px;margin:24px 0}.compare,.cards{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:20px}video{width:100%;display:block;border-radius:16px;background:#000}.compare video{max-height:680px}.label{display:block;margin:8px 0 12px;color:#b8cec6}.cards{grid-template-columns:repeat(auto-fit,minmax(240px,1fr));margin-top:36px}article{border:1px solid #24463e;border-radius:18px;padding:16px}article h2{margin:0}article p{min-height:75px;font-size:14px}article video{max-height:440px}article a{display:inline-block;margin-top:14px;font-size:14px}.labels{display:grid;grid-template-columns:repeat(5,1fr);text-align:center;gap:6px;font-size:13px;margin:12px 0}.transport{display:flex;align-items:center;gap:16px;margin:20px 0}input{flex:1;accent-color:#55fbb2}footer{margin-top:40px;border-top:1px solid #24463e;padding-top:20px;font-size:14px;color:#adc7bc}@media(max-width:600px){main{padding:24px 12px}.compare{gap:8px}button{padding:8px 12px}}</style>
<main><small>KICKLAB / ACTUAL APP EXPORTS</small><h1>Effects on input 4.</h1><p>Original daylight. 85% intensity. Real ball and player detections. Select an effect, play both views together, or scrub to compare the same moment.</p>
<nav>''' + buttons + '''</nav><div class="compare"><div><span class="label">Original</span><video id="original" playsinline muted preload="metadata" src="input4-original.mp4"></video></div><div><span id="effect-label" class="label">Neon</span><video id="effect" playsinline preload="metadata" src="neon.mp4" poster="neon.png"></video></div></div>
<div class="transport"><button id="play">Play comparison</button><input id="seek" aria-label="Video position" type="range" min="0" max="15.3" step="0.01" value="4"><span id="time">4.0s</span></div>
<p>Fire is retained. The other nine effects now have larger forms and particles around the player as well as the ball. These are 2D overlays; they do not have person-depth occlusion.</p>
<h2>All ten in motion</h2><div class="labels"><span>Fire</span><span>Ice</span><span>Neon</span><span>Galaxy</span><span>Electric</span></div><video controls playsinline preload="metadata" poster="daylight-grid.jpg" src="input4-ten-effects.mp4"></video><div class="labels"><span>Aura</span><span>Shadow</span><span>Rainbow</span><span>Pixel</span><span>Nature</span></div><section class="cards">''' + cards + '''</section>
<footer>Every full export is checked for resolution, frame count, duration, complete decoding and bit-exact original audio. Physical iPhone frame rate and thermal behavior have not been measured. <a href="verification.json">Media checks</a></footer></main>
<script>
const original=document.querySelector('#original'), effect=document.querySelector('#effect'), seek=document.querySelector('#seek'), play=document.querySelector('#play');
let position=4, playing=false;
function pause(){original.pause();effect.pause();playing=false;play.textContent='Play comparison'}
function sync(){original.currentTime=position;effect.currentTime=position;seek.value=position;document.querySelector('#time').textContent=position.toFixed(1)+'s'}
original.addEventListener('loadedmetadata',()=>{seek.max=original.duration;original.currentTime=position});
effect.addEventListener('loadedmetadata',()=>{effect.currentTime=position});
play.onclick=async()=>{if(playing){pause();return}if(position>=original.duration-.1)position=0;sync();try{await Promise.all([original.play(),effect.play()]);playing=true;play.textContent='Pause'}catch{pause()}};
seek.oninput=()=>{pause();position=Number(seek.value);sync()};
effect.ontimeupdate=()=>{if(!playing)return;position=effect.currentTime;seek.value=position;document.querySelector('#time').textContent=position.toFixed(1)+'s';if(Math.abs(original.currentTime-position)>.12)original.currentTime=position};
effect.onended=()=>{pause();position=0;sync()};
document.querySelectorAll('[data-style]').forEach(button=>button.onclick=()=>{pause();const style=button.dataset.style;document.querySelectorAll('[data-style]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));document.querySelector('#effect-label').textContent=button.textContent;effect.poster=style+'.png';effect.src=style+'.mp4';effect.load()});
</script></html>''')
print(json.dumps(report, indent=2))
