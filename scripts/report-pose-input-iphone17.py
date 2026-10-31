#!/usr/bin/env python3
"""Save exact-input evidence and bounded fallback results without overstating causality."""
import hashlib
import json
from collections import defaultdict
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/pose-input-iphone17'
captures={}
for path in sorted((BASE/'iphone17').glob('*/pose-input-audit/inputs.json')):
    data=json.loads(path.read_text());assert not data['errors']
    rows=data['rows'];assert rows and all(r['pixelsUnchanged'] for r in rows)
    for r in rows:
        pixels=(path.parent/r['file']).read_bytes()
        assert hashlib.sha256(pixels).hexdigest()==r['sha256']==r['afterSHA256']
        assert len(pixels)==r['width']*r['height']*4
    repeat=int(path.parent.parent.name.split('-r')[-1])
    captures[repeat]=rows
comparisons=[]
for repeat,rows in captures.items():
    if repeat==1:continue
    a={r['timestampMs']:r for r in captures[1]};b={r['timestampMs']:r for r in rows};common=sorted(a.keys()&b.keys())
    comparisons.append(dict(repeats=[1,repeat],common=len(common),
        pixelChanges=[t for t in common if a[t]['sha256']!=b[t]['sha256']],
        rawPoseCountChanges=[t for t in common if a[t]['rawPoseCount']!=b[t]['rawPoseCount']],
        poseChanges=[t for t in common if a[t]['poses']!=b[t]['poses']]))
probes=[]
for path in sorted(BASE.glob('exact-probe-r*/results.json')):
    repeat=int(path.parent.name.split('-r')[-1]);grouped=defaultdict(list)
    by_file={r['file']:r for r in captures[repeat]}
    for row in json.loads(path.read_text())['rows']:
        assert row['sha256']==by_file[row['file']]['sha256']
        grouped[(row['mode'],row['repeat'])].append(row)
    for (mode,repetition),rows in grouped.items():
        probes.append(dict(captureRepeat=repeat,mode=mode,repeat=repetition,
            calls=len(rows),empty=sum(r['rawPoseCount']==0 for r in rows)))
controls={}
for name,filename,wrapped in [('png-control','results.json',False),('compute-control','compute-results.json',True),('crop-control','results.json',False)]:
    path=BASE/name/filename
    if not path.exists():continue
    data=json.loads(path.read_text());grouped=defaultdict(list)
    for row in data['rows'] if wrapped else data:grouped[row['arm']].append(row)
    controls[name]={arm:dict(calls=len(rows),withPose=sum(bool(r['poses']) for r in rows)) for arm,rows in grouped.items()}
summary=dict(captures=[dict(repeat=n,calls=len(rows),empty=sum(r['rawPoseCount']==0 for r in rows),
    pixelsChanged=sum(not r['pixelsUnchanged'] for r in rows),
    playerSelectionMissesWithPose=sum(r['rawPoseCount']>0 and r['selectedIndex'] is None for r in rows)) for n,rows in captures.items()],
    comparisons=comparisons,exactProbes=probes,controls=controls)
(BASE/'input-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
lines=['POSE INPUT REPEATABILITY AND EMPTY-RESULT FALLBACK — IPHONE17, 30 OCT 2026','',
    'SCOPE: iPhone17 Pro Max, iOS27.0.1, IMG_8606 3.MOV. Build2026103005 diagnostic captures and fixed-image probes; build2026103006 debug-only fallback. Main app and TestFlight unchanged.', '',
    'CONFIRMED: The missing selected ankle records can begin with revision2 returning ZERO raw body observations. They are not solely an active-player matching rejection or counter-rule veto. In capture1 versus capture3, common frames have identical packed BGRA bytes but different raw body results. Each original buffer is hashed immediately before and after inference. Captured bytes do not mutate during these calls. No player-selection misses occur when raw poses exist in the captured windows.', '',
    'CAPTURES (17.7–19.8s only, up to96 uncached calls; disk writes after replay):']
for row in summary['captures']:lines.append('  '+str(row))
lines += ['', 'CROSS-RUN COMPARISONS:']
for row in comparisons:lines.append('  '+str(row))
lines += ['', 'EXACT-PIXEL PROBES:']
for row in probes:lines.append('  '+str(row))
lines += ['', 'DECODED PNG / API / COMPUTE / PLAYER CROP CONTROLS:']
for name,arms in controls.items():
    for arm,row in arms.items():lines.append(f'  {name} {arm}: {row["withPose"]}/{row["calls"]} calls returned a body.')
lines += ['',
    'INTERPRETATION: Recreating the request and processing images chronologically did not fix this isolated-image failure. Direct async revision2 and the synchronous bridge both returned empty on the four PNG controls; integrated-hand revision2 also returned empty. The older body request found the player. Explicit supported Neural Engine selection did not restore revision2 detections. This establishes a raw pose-observation problem for these images; it does NOT establish the internal Apple cause of why the full pipeline sometimes succeeds on the same bytes.', '',
    'CROP CONTROL: Crop the same four images around the existing selected-player box, with1.5x width and1.3x height margins, clipped to the image. This is an offline image diagnostic, not a change to the live pipeline. Each revision2 arm finds a body in6/8 calls; the first repetition misses17.941s and18.241s, the second finds all four. Legacy finds8/8. This suggests subject framing is relevant, but neither cropping nor request repetition has been shown to be a stable correction. Raw crop-to-original transforms are saved in crop-map.json. No contact-count or ground-bounce claim is made from this image probe.', '',
    'CAPTURE LIMITS: Before/after CPU snapshots add roughly0.5–0.6ms per captured call and can shift live scheduling. Captured pixel bytes and propagated color metadata are preserved; all these captured buffers had no propagated color attachments. This is not a capture of every private framework state or all non-propagated buffer metadata. Diagnostic replay counts are not performance or promotion evidence. Exact raw-pixel probes and decoded-PNG controls deliberately test different input construction paths.', '',
    'API CHECK: The installed iOS27.1 SDK declares DetectHumanBodyPoseRequest as ImageProcessingRequest with revision2, and supports asynchronous CVPixelBuffer/CIImage/CGImage/Data input. Apple documents this as a body-observation request, not a guarantee of a detection for every visible person. No documented requirement to recreate the request or sort independent image calls was found. The runtime here was iOS27.0.1.',
    '  https://developer.apple.com/documentation/vision/detecthumanbodyposerequest',
    '  https://developer.apple.com/documentation/vision/imageprocessingrequest', '',
    'FALLBACK EXPERIMENT: --pose-empty-legacy-fallback-v1 is DEBUG only and off by default. Only an empty revision2 response with an already matchable selected player permits one legacy body inference on the same requested frame. Both requests warm before the paced clock. The returned whole pose must still pass existing player matching; normal caching and all body, hand, holding, foot and ground rules remain. No interpolation, joint splicing or lowered thresholds. Revision2-empty counters retain their original meaning; separate logs record fallback calls, matches and time.', '',
    'FRESH FALLBACK COMPARISONS (paired executions can still vary in detector timing):']
path=BASE/'fallback/summary.json'
if path.exists():
    fallback=json.loads(path.read_text())
    lines.append('Completed runs: '+str(fallback['completedRuns']))
    for pair in fallback['pairs']:lines.append('  '+str(pair))
    for row in fallback['runs']:
        lines.append(f"  {row['experimentArm']} {row['clip']} r{row['repeat']}: raw empty {row['poseTiming']['empty']}, fallback calls/matched {row['fallbackCalls']}/{row['fallbackMatched']}, fallback total {row['fallbackMS']:.2f}ms, thermal {row['worstThermal']}, late source skips {row['lateSourceSkips']}, pose errors {row['poseTiming']['errors']}, frame median/p95 {row['latencyMedianMs']:.2f}/{row['latencyP95Ms']:.2f}ms.")
    lines += ['',
        'FALLBACK CAUSAL LIMIT: IMG8606 repeat1 has35 fallback calls, all matched, and counts18.875s. Its proposed18.308s contact is still rejected as handsNearBall; the neighboring18.275s proposal is amplitudeTooSmall. Baseline proposed18.241s and counted it. Repeat2 gains18.25s and18.875s but has only one fallback at another timestamp, so those gains cannot be credited to recovery of empty poses at the two contacts. IMG8874, low and raw-juggling have zero fallback calls yet their paired counts vary. That establishes a continuing comparator/timing variability problem, not a measured fallback-caused regression.', '',
        'SEPARATE TIMING OUTLIER: In the low fallback-labelled run, one ordinary revision2 body call at55.800s takes488.93ms. The fallback never runs in that clip. The counter queue reaches19 frames, with no overflow or source skips. This outlier overlaps the region with contact differences but does not by itself prove the cause of every lost label. Median timing alone hides this event; do not attribute it to fallback compute.', '',
        'VALIDATION: Debug and non-DEBUG standalone builds each pass14 eligibility/player-matching contracts; the experiment flag cannot enable the release path. Both iPhone app builds succeeded. All16 paired runs complete exact saved counter replay, source-hash/build/profile checks and labelled scoring. Thermal stayed nominal/fair; no pose errors, RF late replies or buffer overflows. No new labelled false or unmatched counts appeared; IMG8606 retains its existing false at20.176s.']
decision=BASE/'decision.txt'
lines += ['', 'DECISION:', decision.read_text().strip() if decision.exists() else 'Validation in progress. Do not promote from these preliminary results.', '',
    'LIMITS: Development contact labels, small selected corpus, iPhone17 only. No iPhone11 qualification or 15-minute camera/thermal claim. A higher total does not prove preservation of every legal contact. Existing ground false positives must be reported separately from new gains.', '',
    'PHONE: '+('Previous field build2026102913 and saved24-touch IMG8874 preview restored and verified; diagnostics/fallback disabled.' if (BASE/'restore/verified.json').exists() else 'Restoration pending.'), '',
    'EVIDENCE: inputs.json plus raw BGRA files and SHA hashes; exact-probe results; PNG and supported-compute controls; pose overlays; per-build source snapshots and logs; fallback paired traces, labels, runtime profile and source hashes.']
text='\n'.join(lines)+'\n';(BASE/'RESULTS.txt').write_text(text)
dest=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/pose-input-iphone17';dest.mkdir(parents=True,exist_ok=True)
(dest/'RESULTS.txt').write_text(text)
print('Saved',dest/'RESULTS.txt')
