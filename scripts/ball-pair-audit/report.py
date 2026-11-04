"""Summarize the paired native audit and make frame-aligned evidence boards.

Build: bash scripts/ball-pair-audit/build.sh
Infer: artifacts/ball-pair-audit-tools/audit SOURCE OUTPUT_DIR MODEL.mlpackage [384]
Extract export: artifacts/ball-pair-audit-tools/audit EDITED OUTPUT_DIR
Controls: KICKLAB_BALL_MATERIALS_DIR="$PWD/kicklab/Resources/BallMaterials" \
    artifacts/ball-pair-audit-tools/audit --geometry SOURCE VISUAL.plist OUTPUT_DIR 1080 30
Report: python3 scripts/ball-pair-audit/report.py AUDIT_DIRECTORY

Directory names: better-source, better-edited, problem-source, problem-edited,
problem-controls. Optional problem-rf288 and problem-geometry. Python needs Pillow
and NumPy. Media stays in ignored artifacts; the application is never modified.
"""
import hashlib
import html
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont


def read(path):
    return json.loads(path.read_text())


def exposure_support(rows):
    """Independent audit of the production through-origin box-stretch model.

    Valid for these raw full-frame tracks, without recovered observations. This
    metric is descriptive, not a proposed production confidence threshold.
    """
    values = np.array([[r['time'], *r['ball'][:4]] for r in rows if 'ball' in r])
    time = values[:, 0]
    positions = values[:, 1:3] * [720, 1280]
    boxes = values[:, 3:5] * [720, 1280]
    velocity = (positions[2:] - positions[:-2]) / (time[2:] - time[:-2])[:, None]
    speed = np.linalg.norm(velocity, axis=1)
    direction = np.abs(velocity) / np.maximum(speed[:, None], 1e-9)
    axis = direction[:, 0] - direction[:, 1]
    observed = (boxes[1:-1, 0] - boxes[1:-1, 1]) * axis
    predictor = speed * axis**2
    diameter = boxes[1:-1].min(axis=1)
    valid = (speed > 1e-6) & (time[1:-1]-time[:-2] <= .05) & (time[2:]-time[1:-1] <= .05)
    valid &= (observed > -.3*diameter) & (observed < 1.5*diameter)
    valid &= np.all(values[1:-1, 1:3]-values[1:-1, 3:5]/2 > .005, axis=1)
    valid &= np.all(values[1:-1, 1:3]+values[1:-1, 3:5]/2 < .995, axis=1)
    x, y = predictor[valid], observed[valid]
    return dict(samples=int(valid.sum()), estimatedSeconds=float(x@y/(x@x)),
                explainedStretchEnergy=float((x@y)**2/((x@x)*(y@y))))


def main(root):
    pairs = {}
    for name in ['better', 'problem']:
        source, edited = (read(root/f'{name}-{kind}/frames.json') for kind in ['source', 'edited'])
        spin = read(root/f'{name}-source/spin.json')
        source_times = [r['time'] for r in source['rows']]
        edited_times = [r['time'] for r in edited['rows']]
        assert source_times == edited_times, f'{name}: pair is not frame aligned'
        visible = sum(r['visible'] for r in spin['rows'])
        diameter = [r['maskRadius']*2 for r in source['rows'] if 'maskRadius' in r and r['time'] < 11]
        pairs[name] = dict(source=source['source'], edited=edited['source'],
            decodedFrames=source['frames'], nativeCompositionTimestampsIdentical=True,
            rawDetections=source['detections'], spinVisibleFrames=visible,
            acceptedSpinPairs=spin['accepted'], spinAcceptedFraction=spin['accepted']/visible,
            photographicExposureSeconds=spin['photographicExposure'],
            boxExposureSeconds=spin['boxExposure'],
            medianMaskDiameterAt720First11Seconds=float(np.median(diameter)),
            boxStretchModel=exposure_support(source['rows']))
    controls = {r['index']: r for r in read(root/'problem-controls/geometry.json')['rows']}
    indices = [240, 270, 690, 720, 990, 1020]
    font = ImageFont.load_default(size=14)
    sheet = Image.new('RGB', (960, 265*len(indices)), '#17191e')
    draw = ImageDraw.Draw(sheet)
    evidence = []
    for n, index in enumerate(indices):
        row = controls[index]
        x, y, width, height = row['crop']
        scale = 720/row['size'][0]
        box = (round(x*scale), round(y*scale), round((x+width)*scale), round((y+height)*scale))
        for col, (suffix, label) in enumerate([
                ('source', 'Original'), ('supplied', 'Supplied export'),
                ('current', 'Fresh current code'), ('no-blur', 'Same, blur disabled')]):
            image = (Image.open(root/'problem-edited'/f'frame-{index:05}.jpg').crop(box)
                     if suffix == 'supplied' else Image.open(root/'problem-controls'/f'{index:05}-{suffix}.png'))
            sheet.paste(image.convert('RGB').resize((240,240), Image.Resampling.LANCZOS), (col*240,n*265+25))
            draw.text((col*240+5,n*265+5), f'{row["time"]:.3f}s  {label}', font=font, fill='white')
        evidence.append(dict(index=index, time=row['time'], smear1080=row['smear']))
    sheet.save(root/'comparison.jpg', quality=96)
    # Two rows are sufficient for the main conversation; retain all six in the report.
    compact = Image.new('RGB', (960,530))
    for i, row in enumerate([3,4]):
        compact.paste(sheet.crop((0,row*265,960,(row+1)*265)), (0,i*265))
    compact.save(root/'blur-evidence.jpg', quality=96)
    alternate = None
    if (root/'problem-rf288/spin.json').exists():
        spin = read(root/'problem-rf288/spin.json')
        frames = read(root/'problem-rf288/frames.json')
        alternate = dict(rawDetections=frames['detections'], frames=frames['frames'],
            acceptedSpinPairs=spin['accepted'], visibleSpinFrames=sum(r['visible'] for r in spin['rows']),
            boxExposureSeconds=spin['boxExposure'], photographicExposureSeconds=spin['photographicExposure'],
            boxStretchModel=exposure_support(frames['rows']))
    report = dict(scope='Fresh macOS RF model/production appearance controls, not the exact app analysis cache. Spin acceptance is solver self-consistency, not ground-truth spin accuracy.',
        pairs=pairs, problemRF288Control=alternate, selectedEvidence=evidence,
        conclusions=[
            'Both supplied pairs share the exact timestamps produced by native composition; a whole-frame clock mismatch is not supported.',
            'Detection and accepted source-spin pairs are strong in both raw controls. This does not establish exact physical spin accuracy.',
            'The poor clip receives substantially more box-inferred blur without a successful photographic exposure calibration. Disabling only smear visibly reduces excess softness in selected frames.',
            'The through-origin stretch fit has no goodness-of-fit rejection or static aspect-bias term; shape errors can be interpreted as exposure.',
            'White ball against pale clothing, a larger displayed ball, and textured grass make boundary errors more visible. The sampled raw masks do not support deep occlusion cuts as the primary explanation.',
            'Blur ablation leaves contour/rim errors. It is diagnostic evidence, not a validated global fix or a replacement export.'
        ], nextSteps=[
            'Separate a blur direction/search hint from a trusted rendering exposure. Distinguish measured sharp edges, measured blur, and unobservable edges.',
            'Reject unsupported box-based blur; test sharp biased/noisy boxes and real blurred footage before choosing a confidence threshold.',
            'Evaluate silhouette fit and foreground overlap on the supplied problem frames; avoid indiscriminate radius expansion.',
            'Regression-check both sources at source cadence, with the app crop/gap repair and saved export path.'
        ])
    repo = Path(__file__).resolve().parents[2]
    report['branch'] = subprocess.check_output(['git','branch','--show-current'],cwd=repo,text=True).strip()
    report['head'] = subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
    report['productionSHA256'] = {str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in [repo/'kicklab/Effects'/name for name in ['BallEffectTrack.swift','BallReplacementCoverage.swift',
            'BallReplacementFootprint.swift','BallReplacementMotionBlur.swift','BallReplacementBackground.swift',
            'BallMaterialRenderer.swift','BallSurfaceTimeline.swift','BallSurfaceMotion.swift']]}
    (root/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    rows = ''.join(f'<tr><th>{html.escape(label)}</th><td>{better}</td><td>{problem}</td></tr>' for label,better,problem in [
        ('Source / export resolution','2160 × 3840','1080 × 1920'),('Cadence','120 fps','120 fps'),
        ('Native decoded frames',pairs['better']['decodedFrames'],pairs['problem']['decodedFrames']),
        ('Accepted spin comparisons',f"{pairs['better']['spinAcceptedFraction']:.1%}",f"{pairs['problem']['spinAcceptedFraction']:.1%}"),
        ('Box-inferred exposure',f"{pairs['better']['boxExposureSeconds']*1000:.2f} ms",f"{pairs['problem']['boxExposureSeconds']*1000:.2f} ms"),
        ('Photographic exposure confirmed','No','No')])
    conclusions = ''.join(f'<li>{html.escape(text)}</li>' for text in report['conclusions'])
    steps = ''.join(f'<li>{html.escape(text)}</li>' for text in report['nextSteps'])
    (root/'report.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8">
<title>Ball replacement: paired clip investigation</title>
<style>body{{font:17px/1.55 system-ui;max-width:1100px;margin:40px auto;padding:0 24px;color:#20232a;background:#fafafa}}h1{{line-height:1.15}}table{{border-collapse:collapse;width:100%}}td,th{{padding:10px;text-align:left;border-bottom:1px solid #ddd}}img{{max-width:100%;height:auto}}li{{margin:10px 0}}small{{color:#555}}</style>
<h1>Why the same ball replacement looks different</h1><p>2 November 2026 · feature/leaderboard-editor-upgrade</p>
<p><strong>The strongest controlled finding is excess inferred blur.</strong> Removing blur alone improves sharpness, while contour and original-rim errors remain. This is a focused rendering investigation; a detector rewrite is not justified by these controls.</p>
<table><tr><th>Check</th><th>IMG_8649 — stronger clip</th><th>IMG_9094 — weaker clip</th></tr>{rows}</table>
<h2>Evidence</h2><p>Each row uses the same source timestamp. The last two columns share geometry, material, spin and lighting; only the smear input changes.</p>
<img src="comparison.jpg" alt="Original, supplied export, fresh current render, and same render with blur disabled">
<p><small>The fresh controls use raw RF384 masks, without the app’s crop/gap repairs, and a per-frame white estimate. They are not exact re-exports of the app’s retained analysis. Spin acceptance measures consistency, not ground truth. Disabling blur everywhere is not the recommended fix.</small></p>
<h2>Findings</h2><ul>{conclusions}</ul><h2>Fix strategy</h2><ol>{steps}</ol>
<p><a href="report.json">Machine-readable evidence and source-code hashes</a></p></html>''')
    print(json.dumps(dict(report=str(root/'report.html'),pairs=pairs,problemRF288Control=alternate),indent=2))


if __name__ == '__main__':
    main(Path(sys.argv[1]).resolve())
