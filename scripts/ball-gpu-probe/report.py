"""Build a local review page from the Mac paired-clip run and physical-phone probe."""
import hashlib
import html
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[2]
out = root / 'artifacts/ball-gpu-probe'
mac_path = pathlib.Path(sys.argv[1]).resolve()
phone_path = pathlib.Path(sys.argv[2]).resolve()
mac = json.loads(mac_path.read_text())
phone = json.loads(phone_path.read_text())

def row(label, value):
    cpu, gpu = value['cpu']['median_ms'], value['gpu']['median_ms']
    return f'<tr><td>{html.escape(label)}</td><td>{cpu:.2f} ms</td><td>{gpu:.2f} ms</td><td>{100*(1-gpu/cpu):.1f}%</td><td>{value["difference"]["max_byte_error"]}/255</td></tr>'

def table(rows):
    return '<table><thead><tr><th>Test</th><th>CPU median</th><th>GPU candidate median</th><th>Less time</th><th>Max channel difference</th></tr></thead><tbody>'+''.join(rows)+'</tbody></table>'

def pair(stem, title):
    rel = mac_path.parent.relative_to(out)
    return f'<article><h3>{html.escape(title)}</h3><div class="pair">'+''.join(
        f'<figure><img src="{rel}/{stem}-{mode}.png" alt="{html.escape(title)} {mode}"><figcaption>{mode.upper()}</figcaption></figure>'
        for mode in ['cpu','gpu'])+'</div></article>'

page = '''<!doctype html><html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ball GPU prototype — paired comparison</title><style>
body{font:16px/1.55 system-ui,sans-serif;background:#111820;color:#edf2f5;max-width:1040px;margin:48px auto;padding:0 24px}
h1{font-size:36px;line-height:1.15}h2{margin-top:38px}p{max-width:850px;color:#c8d3dc}a{color:#85ceff}
.note{padding:16px 20px;border-left:4px solid #f6c767;background:#273039}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}th,td{text-align:left;padding:10px;border-bottom:1px solid #34414d}th{color:#a9bdd0;font-size:13px}article{border:1px solid #34414d;border-radius:12px;padding:16px;margin:20px 0}h3{margin:0}.pair{display:flex;gap:20px;flex-wrap:wrap}figure{margin:16px 0}img{width:256px;height:256px;object-fit:contain;background:repeating-conic-gradient(#26313d 0% 25%,#1b252e 0% 50%) 0/20px 20px}figcaption{color:#a9bdd0;text-align:center}code{font-size:13px}footer{margin:40px 0;color:#a9bdd0}
</style><h1>A small GPU experiment is worth keeping</h1>
<p>The prototype moves only the normal skins’ 256-pixel surface drawing into Metal. Existing outline, masks, blur and background processing remain unchanged. The production app is unchanged.</p>
<div class="note"><strong>Not a shipping change.</strong> Phone numbers measure the surface draw only. Mac clip numbers measure replacement-patch rendering, not complete playback or export. The phone began and ended at serious thermal state (2); these paired measurements are directional evidence, not a cool-device or battery qualification.</div>
<h2>Physical iPhone 11 Pro Max</h2><p>Optimized standalone app, 30 alternating CPU/GPU pairs per skin. GPU timing includes submission, waiting, CPU readback and image construction. Input maps are warmed and the pose cache is disabled in both arms.</p>'''
page += table([row(x['skin'], x) for x in phone['spheres']])
page += '<h2>Your clips, on the Mac</h2><p>Apple M1 Max. Fresh retained detection/spin data from the earlier clip audit; original videos decoded to 1080 short edge. Every 90th frame, Arctic/Lava/Stealth, three alternating paired rounds. Geometry is computed once for both arms; timing excludes decoding, fitting, final frame composition and encoding.</p>'
page += table([row(x['name'], x) for x in mac['clips']])
page += '<p>All 14 normal skins passed the sampled source-pose and timer-pose comparisons on Mac and phone. Maximum colour-channel difference was 1/255 and alpha matched exactly. Both clip-patch comparisons also stayed within 1/255. This preserves the existing appearance, including existing blur/outline limitations.</p>'
page += '<h2>Visual comparisons</h2>'
for skin in ['arctic','lava','pearl','metal']:
    page += pair('sphere-'+skin, skin.title()+' surface')
for clip in ['better','problem']:
    for index in [270,630,990]:
        if (mac_path.parent/f'{clip}-{index}-cpu.png').exists():
            page += pair(f'{clip}-{index}',f'{clip.title()} clip — frame {index}, replacement patch')
page += '''<h2>Decision and remaining work</h2><p>Keep this limited prototype. A subsequent integration should reuse a bounded renderer, preserve CPU fallback and background behavior, and compare real replay/export timing on a cool phone. The experiment does not replace Lab skin processing or fix blur/edge quality. No broader GPU rewrite is required to evaluate this one stage.</p>
<p>The first diagnostic run caught a timer-only rotation-order mismatch in the prototype. It was corrected; the retained corrected run passes both timer and source-derived orientations. The corrected Mac run overlapped a build in its early surface tests; the real-clip patch measurements ran after that build. Phone work ran in its own finite test app.</p>
<h2>Reproduction</h2><p>From the editor worktree, run <code>bash scripts/ball-gpu-probe/build.sh</code>, then set <code>KICKLAB_BALL_MATERIALS_DIR=kicklab/Resources/BallMaterials</code> and run <code>artifacts/ball-gpu-probe/build/probe NEW_OUTPUT_FOLDER</code>. The build changes only an ignored copy of the CPU renderer. <code>phone-project.rb</code> creates a separate optimized iOS test app from the same adapter and reference renderer.</p>'''
page += f'<footer><a href="{mac_path.relative_to(out)}">Mac evidence</a> · <a href="{phone_path.relative_to(out)}">Phone evidence</a> · <a href="provenance.json">Source and build hashes</a></footer></html>'
(out/'report.html').write_text(page)
paths = [*sorted((root/'scripts/ball-gpu-probe').glob('*')),
         root/'artifacts/ball-gpu-probe/build/BallSkinSphereRenderer.swift',
         root/'artifacts/ball-gpu-probe/phone-build/Build/Products/Release-iphoneos/GPUProbe.app/GPUProbe',
         root/'kicklab/Effects/BallSkinSphereRenderer.swift',root/'kicklab/Effects/BallMaterialRenderer.swift',
         mac_path,phone_path]
provenance = {'phone':'iPhone 11 Pro Max / iPhone12,5', 'phone_thermal': [phone['thermal_start'],phone['thermal_end']],
    'production_changed':False,'source_revision':'2ef44e26819596b205acb544c0fc739a17cd4865 plus existing user edits',
    'sha256':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths if p.is_file()}}
(out/'provenance.json').write_text(json.dumps(provenance,indent=2))
print(out/'report.html')
