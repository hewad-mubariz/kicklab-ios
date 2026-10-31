#!/usr/bin/env python3
"""Write a concise, evidence-linked report for the completed iPhone17 experiment."""
import json, collections
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/shared-history-iphone17'
s=json.loads((BASE/'summary.json').read_text())
names={'clip-618a1688fcc6':'IMG_8874 (24 reviewed legal touches)', 'clip-a16380ba4a5b':'IMG_8606 (39 reviewed legal touches)',
       'low':'low (195 reviewed legal touches)', 'ball_in_hand':'ball_in_hand',
       'dribbling_with_ball_3':'dribbling_with_ball_3', 'dribbling_with_the_ball_1':'dribbling_with_the_ball_1'}
lines=['IPHONE 17 SHARED-HISTORY EXPERIMENT — 29 OCTOBER 2026', '',
'DECISION: Keep this prototype off by default. It reduces pose work, but has not preserved counting accuracy reliably or improved measured pipeline latency.', '',
'Both arms use body-pose revision2, automatic compute placement, tracker revision1, RF384, and the same 24 current counting flags. The only experimental flag is --pose-shared-history-v1. This is NOT a revision1-versus-revision2 comparison.', '',
'The experiment thins earlier approach frames in the ground and holding checks to common -300/-200 ms targets. Every eligible view from -101 ms through impact and release remains. It selects complete real observations; it never attaches an old pose to a newer ball. The exact foot trio, direct hand checks, model, confidence thresholds, warmup, capture buffers, and worker capacity stay unchanged.', '',
'COUNTING RESULTS (each list contains successive full runs; legal counts exclude known false counts):']
for c in s['comparisons']:
    a,b=[c['arms'].get(x,{}) for x in ['baseline','shared']]
    if not a or not b:continue
    lines += [f"{names.get(c['clip'],c['clip'])}: baseline {a['legalCounts']}; shared {b['legalCounts']}. Known false counts {a['knownFalseCounts']} -> {b['knownFalseCounts']}."]
lines += ['', 'PERFORMANCE (means of per-run metrics; lower pose work is not an equivalent overall app speedup):']
for c in s['comparisons']:
    a,b=[c['arms'].get(x,{}) for x in ['baseline','shared']]
    if not a or not b or not a['meanPoseCalls']:continue
    lines += [f"{names.get(c['clip'],c['clip'])}: calls {a['meanPoseCalls']:.1f} -> {b['meanPoseCalls']:.1f} ({c['poseCallsChangePercent']:+.1f}%); pose work {a['meanPoseMsPerSourceSecond']:.1f} -> {b['meanPoseMsPerSourceSecond']:.1f} ms per second of video ({c['poseWorkChangePercent']:+.1f}%). Pipeline latency median {a['meanPipelineLatencyMedianMs']:.1f} -> {b['meanPipelineLatencyMedianMs']:.1f} ms; p95 {a['meanPipelineLatencyP95Ms']:.1f} -> {b['meanPipelineLatencyP95Ms']:.1f} ms."]
lines += ['', 'EVENT-LEVEL FINDINGS:',
'- IMG_8874: all 24 reviewed touches in all three runs of each arm. No known false counts.',
'- IMG_8606: legal contact near 16.808 seconds is accepted in 3/3 baseline runs and 1/3 shared-history runs. The two shared misses report missingPose. The saved live inputs contain different ball observations around impact; this is not proven to be a direct threshold regression. The practical comparison still fails to establish equivalent accuracy. A gain near 3.368 seconds partly masks this loss in total counts.',
'- IMG_8606: the existing false ground bounce near 20.176 seconds remains in every run of both arms. The sampling change does not fix it.',
'- Low-juggling both pairs: baseline 161/161 versus shared 159/159. The lost labelled contacts are 46.60 seconds (no nearby candidate) and 46.91 seconds (handsUncertain/body rejection). In reverse run order the losses move to 54.08 and 58.08 seconds. Both pairs lose two legal contacts, but not the same contacts. See low-missed-contacts.json.',
'- The shortest hand/ground negative clips have zero pose requests: they test earlier pipeline rejection, not the reduced pose windows. The additional dribbling_with_the_ball_1 clip exercises pose inference.', '',
'OFFLINE SCREEN:',
'101 saved iPhone17 runs across 23 distinct clips; all 101 baseline numerical replays exact. All 3,247 counted events across these repeated runs were preserved by the sampled-evidence screen, with no added counts. These are repeated-run events, not 3,247 unique labelled legal touches.',
'37 individual ground verdicts changed (34 true-to-false, 3 false-to-true) and 20 holding verdicts changed (19 inPlay-to-uncertain, 1 uncertain-to-inPlay); no held-state change was observed. Final offline counts were unchanged. This screen freezes the prior body/hand verdicts and cannot reproduce changed live inference, tracking or alignment. It therefore cannot replace the phone comparison.', '',
'VALIDATION:']
rows=s['runs']
lines += [f"{len(rows)} completed fresh phone runs; failed-run files: {len(s['failedRuns'])}. Every completed run validates source SHA, build2026102916, both revision selections, explicit experimental switch, full source coverage, trace completeness, exact numeric replay, exported count/report count agreement, and report quality.",
 f"Maximum thermal state across completed runs: {max((r['worstThermal'] for r in rows),default=None)} (0=nominal). Late source-frame skips: {sum(r['lateSourceSkips'] for r in rows)}. Pose request errors: {sum(r['poseTiming']['errors'] for r in rows)}.",
'App build passed. Standalone sampler contract checks passed for actual-frame identity, dense impact/release preservation, sparse history cap, input-order independence, missing views and deterministic ties. Benchmark Python scripts compile; changed tracked files pass git diff --check.', '',
'LIMITS AND NEXT STEP:',
'This is original-video replay through the live engine, not a new camera capture session or the ordinary import analyzer. The import-versus-live discrepancy remains a separate issue. The full 59-video inventory was not freshly replayed here. No iPhone11 was used or inferred from these results.',
'First stabilize which observed frames reach each candidate and measure repeatability with the complete evidence window. Any subsequent compute optimization must preserve legal impact evidence and the ground/hand vetoes. The current lower pose workload alone is insufficient justification to promote shared-history v1.', '',
'PHONE RESTORATION: '+('Verified field build2026102913, revision2 default, shared-history flag absent; original IMG_8874 main preview restored to 24 touches, position zero, outlines off.' if (BASE/'restore/verified.json').exists() else 'Pending until all phone work completes.'), '',
'EVIDENCE: summary.json, offline-screen.jsonl, protocol.json, source-sha256.json, sampling-contract-result.txt, img8606-16_808-investigation.json, low-missed-contacts.json, and baseline/shared run folders.']
(BASE/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
print('Wrote',BASE/'RESULTS.txt')
