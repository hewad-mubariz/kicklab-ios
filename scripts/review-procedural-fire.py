#!/usr/bin/env python3
"""Verify the app's procedural Fire export and prepare the input 4 review."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'artifacts/fire-procedural'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
FFPROBE = '/opt/homebrew/bin/ffprobe'


def run(*args):
    return subprocess.check_output([str(arg) for arg in args])


def probe(path):
    return json.loads(run(FFPROBE, '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path))


def audio_packets(path):
    return json.loads(run(FFPROBE, '-v', 'error', '-select_streams', 'a', '-show_packets',
                          '-show_data_hash', 'sha256', '-of', 'json', path))['packets']


def main():
    source = Path(json.loads((ROOT / 'artifacts/reference-effects/analysis.json').read_text())['source'])
    output = OUT / 'fire.mp4'
    baseline = OUT / 'before-strength/fire.mp4'
    if not baseline.exists():
        baseline = ROOT / 'artifacts/reference-effects/fire.mp4'
    original, rendered = probe(source), probe(output)
    a = next(s for s in original['streams'] if s['codec_type'] == 'video')
    b = next(s for s in rendered['streams'] if s['codec_type'] == 'video')
    assert (b['width'], b['height']) == (720, 1280)
    assert int(a['nb_frames']) == int(b['nb_frames']) == 456
    assert abs(float(original['format']['duration']) - float(rendered['format']['duration'])) < .05
    run(FFMPEG, '-v', 'error', '-i', output, '-f', 'null', '-')
    source_audio, result_audio = audio_packets(source), audio_packets(output)
    source_hashes = [p['data_hash'] for p in source_audio]
    result_hashes = [p['data_hash'] for p in result_audio]
    start = source_hashes.index(result_hashes[0])
    assert result_hashes == source_hashes[start:start + len(result_hashes)]
    packet_end = lambda p: float(p['pts_time']) + float(p['duration_time'])

    run(FFMPEG, '-y', '-v', 'error', '-ss', 4, '-i', output, '-frames:v', 1, OUT / 'fire.png')
    run(FFMPEG, '-y', '-v', 'error', '-ss', 3.5, '-i', output, '-vf',
        'fps=8,crop=390:650:235:410,scale=240:400,tile=4x2', '-frames:v', 1, OUT / 'motion-detail.jpg')
    run(FFMPEG, '-y', '-v', 'error', '-i', baseline, '-i', output,
        '-filter_complex', '[0:v]crop=480:800:210:320,scale=360:600[old];'
        '[1:v]crop=480:800:210:320,scale=360:600[new];[old][new]hstack=inputs=2[v]',
        '-map', '[v]', '-map', '1:a:0', '-c:v', 'libx264', '-crf', 18, '-preset', 'fast',
        '-c:a', 'copy', '-movflags', '+faststart', OUT / 'before-after.mp4')
    run(FFMPEG, '-y', '-v', 'error', '-ss', 4, '-i', OUT / 'before-after.mp4', '-frames:v', 1, OUT / 'before-after.jpg')

    shader = (ROOT / 'kicklab/Effects/Metal/EffectShaders.metal').read_text()
    engine = (ROOT / 'kicklab/Effects/Metal/MetalEffectEngine.swift').read_text()
    assert 'proceduralFireFX' in shader
    assert all(name not in shader + engine for name in ['firePlateFX', 'firePlume', 'fireCorona', 'fireTextureDirectory'])
    bundle = ROOT / 'build/fire-procedural/Build/Products/Debug-iphonesimulator/kicklab.app'
    assert bundle.is_dir()
    assert not list(bundle.rglob('fire-plume.png')) and not list(bundle.rglob('fire-corona.png'))
    assert 'Test run with 20 tests in 2 suites passed' in (OUT / 'tests.log').read_text()
    assert '** BUILD SUCCEEDED **' in (OUT / 'device-build.log').read_text()

    report = {
        'source': str(source), 'renderer': 'procedural Metal advection; no flame image materials',
        'lighting': 'original daylight', 'intensity': .85, 'comparison_baseline': str(baseline),
        'video': {'size': [b['width'], b['height']], 'frames': int(b['nb_frames']),
                  'duration': float(rendered['format']['duration']), 'full_decode': 'passed'},
        'audio': {'retained_aac_payloads_unchanged': True,
                  'complete_bitstream_identical': source_hashes == result_hashes,
                  'source_packets': len(source_audio), 'output_packets': len(result_audio),
                  'tail_trim_seconds': round(packet_end(source_audio[-1]) - packet_end(result_audio[-1]), 6),
                  'note': 'Existing export mux timing; audio code was not changed.'},
        'gpu_and_tracking_tests': '20 passed', 'iphone_release_build': 'passed',
        'rejected_flame_images_absent_from_fresh_app_bundle': True,
        'simulator_full_export_timing': (OUT / 'fire-timing.txt').read_text(),
        'physical_device_performance': 'not measured',
    }
    (OUT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    (OUT / 'index.html').write_text('''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>KickLab · Procedural Fire</title>
<style>*{box-sizing:border-box}body{margin:0;background:#101413;color:#f2f4f1;font:16px system-ui}main{max-width:1050px;margin:auto;padding:32px 20px}h1{font-size:clamp(32px,6vw,60px);letter-spacing:-.04em;margin:12px 0}p{color:#bec8c2;line-height:1.6}a{color:#ffb967}video,img{display:block;width:100%;border-radius:16px;background:#000}.labels,.grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}.labels{padding:12px 0;text-align:center}.grid{margin-top:30px}.grid video,.grid img{max-height:650px;object-fit:contain}.note{font-size:13px;margin-top:32px}h2{font-size:22px}@media(max-width:620px){.grid{grid-template-columns:1fr}}</style>
<main><p>KICKLAB / ACTUAL APP EXPORT</p><h1>Fire in motion.</h1>
<p>Code-generated flames on input 4. Fuel follows the recorded ball path, curls in a changing flow field, then rises and fades. Original daylight, 85% intensity.</p>
<div class="labels"><span>Previous Fire strength</span><strong>Stronger procedural Fire</strong></div>
<video controls playsinline loop preload="metadata" poster="before-after.jpg" src="before-after.mp4"></video>
<p><a href="before-after.mp4">Open comparison video</a> · <a href="fire.mp4">Open full-frame export</a></p>
<div class="grid"><section><h2>Full input 4 export</h2><video controls playsinline loop preload="metadata" poster="fire.png" src="fire.mp4"></video></section>
<section><h2>Approved appearance reference</h2><img src="../../design/fire-mockup/fire-input4-v1.png" alt="Generated Fire appearance concept on input 4"><p>This concept guides the appearance. It is not sampled by the renderer.</p></section></div>
<h2>Consecutive frames · 125 ms apart</h2><img src="motion-detail.jpg" alt="Eight successive frames showing evolving procedural fire">
<p class="note">20 GPU/tracking tests passed; iPhone Release build passed. Video dimensions, frame count, duration and full decoding checked. The existing export mux trims approximately 0.1 seconds from the source audio tail; retained AAC payloads are unchanged. Physical-iPhone performance is not measured. <a href="verification.json">Validation details</a> · <a href="../../docs/procedural-fire.md">Implementation notes</a></p></main></html>''')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
