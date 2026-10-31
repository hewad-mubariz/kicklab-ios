#!/usr/bin/env python3
import json,statistics,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];BASE=ROOT/'artifacts/vision-revisions-20261029'
OUT=BASE/'source-cadence-investigation-20261029'
allruns=json.loads((OUT/'all-runs.json').read_text());summary=json.loads((BASE/'source-cadence-reserved-iphone17/summary.json').read_text())
events=json.loads((BASE/'source-cadence-reserved-iphone17/event-comparison.json').read_text())
text=['IPHONE 17 PIPELINE TIMING INVESTIGATION — 29 OCTOBER 2026','',
'OUTCOME: A source of frame-selection variation is confirmed, but none of the tested scheduling changes is a safe general counting improvement. Keep all --rf-source-cadence-v1/v2/v3/v4 experiments disabled. The shared-pose-history experiment also remains disabled. No production/default or TestFlight change was made.', '',
'CONFIRMED BEHAVIOR:',
'BufferedTracking originally schedules regular RF inference using uptime minus the last submitted job. Impact-gap retries on older images update that same timestamp. Small workload changes can therefore shift later regular detector frames. The same video can present different ball observations to an unchanged counter.',
'At a 30 Hz frame-ingestion cadence, waiting at least 1/12 second from the previous submission usually selects every third frame: approximately 10 Hz, not an evenly spaced 12 Hz. The old policy is a maximum-rate interval, not a guarantee of 12 detections each second. This is an integration limitation; the study does not prove that one scheduler defect explains all misses.',
'In the previous low-juggling comparisons, all 1,507 and 1,511 common ankle/hip evidence sets were identical between the two runs. IMG_8606 matched 378/385 and 386/386. This compares saved ankle/hip data on common timestamps, not every body or hand output and not a raw-pixel digest. It supports investigating frame selection rather than assuming random pose output.', '',
'TESTED, WITH FULL POSE EVIDENCE AND UNCHANGED COUNTING RULES:',
'1. Build2026102917: source-clock opportunities near the existing effective10Hz rate, but retaining the shared wall-rate guard. Failed accuracy: IMG_8606 37 -> 30 legal; low 160 -> 157; IMG_8874 24 -> 24. Retries suppressed scheduled regular opportunities. Six phone runs.',
'2. Build2026102919: separate regular/retry timing with either nominal10Hz or true12Hz source grids. IMG_8606 baseline33, source10=31, source12=33. Low baseline161, source10=157, source12=165. IMG_8874 remained24 in all arms. The 12Hz low result gained eight legal contacts but lost four others. A higher total alone did not establish no regression. Nine phone runs.',
'3. Build2026102920: true12Hz grid plus one pending reference to the original scheduled image. The image can be submitted when the worker is available only while estimated completion fits the existing200ms analysis window and image age is at most100ms. No extra image copy, no enlarged32-frame contact queue, and no additional model instance. Twelve phone runs, with reversed order for the second pair.', '',
'FINAL PAIRED LEGAL COUNTS (two runs per arm):']
names={'clip-a16380ba4a5b':'IMG_8606 (39 labelled legal)', 'clip-618a1688fcc6':'IMG_8874 (24 labelled legal)', 'low':'low (195 labelled legal)'}
for c in summary['comparisons']:
 a,b=[c['arms'][k] for k in ['baseline','source']]
 text += [f"{names[c['clip']]}: current {a['legalCounts']} -> prototype {b['legalCounts']}; labelled false counts {a['falseCounts']} -> {b['falseCounts']}."]
text += ['', 'EVENT TRADE-OFFS:']
for e in events:
 text += [f"{names[e['clip']]}, pair {e['repeat']}: lost legal seconds {e['lostLegalSeconds']}; gained legal seconds {e['gainedLegalSeconds']}."]
text += ['The same known false ground bounce near20.176 seconds remains in IMG_8606. No additional labelled false or unmatched counts appeared in these three tested clips. That is not a claim about the whole corpus.', '',
'SPEED AND REPEATABILITY OF THE FINAL PROTOTYPE:']
for c in summary['comparisons']:
 a,b=[c['arms'][k] for k in ['baseline','source']]
 rs={arm:[r for r in summary['runs'] if r['clip']==c['clip'] and r['experimentArm']==arm] for arm in ['baseline','source']}
 notification={arm:statistics.mean(r['notificationLatencyMedianMs'] for r in rrs) for arm,rrs in rs.items()}
 text += [f"{names[c['clip']]}: regular RF rate {a['meanRegularRFHz']:.2f} -> {b['meanRegularRFHz']:.2f} Hz; pose work {a['meanPoseMsPerSecond']:.1f} -> {b['meanPoseMsPerSecond']:.1f} ms/second; frame-pipeline median {a['meanLatencyMedianMs']:.1f} -> {b['meanLatencyMedianMs']:.1f} ms; touch-notification median {notification['baseline']:.1f} -> {notification['source']:.1f} ms.",
 f"  Actual regular-source-timestamp intersection/union across the two repeats: {a['regularScheduleIntersectionOverUnion']:.3f} -> {b['regularScheduleIntersectionOverUnion']:.3f}. Compare source timestamps, not sequential admitted-frame IDs, because skipped frames can renumber those IDs."]
text += ['The final design improves schedule agreement on IMG_8874, but not on IMG_8606 or low. It does not establish a general repeatability improvement. It also performs more regular RF inference; this is not a compute-saving optimization.',
'The final source arm has four late RF replies and four late source-frame skips across its six runs; paired baseline has zero of each. Examples of late RF replies: source17.342s completed212.1ms after its due time, and source52.333s completed218.3ms after its due time, beyond the unchanged200ms buffer. Late results are discarded rather than used to revise prior counts. The completion estimate is not a guarantee and does not fully account for contact work queued on the shared worker or runtime spikes.', '',
'VALIDATION AND SCOPE:',
'27/27 fresh phone runs completed. All completed traces replayed exactly, source hashes and revision/flag selections were verified, and counts agreed across trace, exported touches and report. Workload logs had no dropped audit rows and the uncached body-request totals matched pose timing. Every run remained nominal; pose request errors and tracking-buffer overflow drops were zero. One model instance and at most one active inference were maintained.',
'Builds17,18,19,20 compiled; build18 was superseded before phone testing. Source-clock unit contracts cover fixed-source scheduling, duplicate/backward inputs, skipped slots, thermal rate changes, burst guards, deadline estimates,12Hz sampling, and explicit opt-in flags. Python scripts compile; changed tracked sources pass whitespace checks.',
'Only iPhone17 Pro Max was used. These are paced original-video replays through the live engine, not ordinary imports or new camera recordings. Three clips, not the full59-video inventory, were tested here. This does not certify iPhone11 performance or a15-minute continuous session.', '',
'DECISION / NEXT ENGINEERING TARGET:',
'Do not ship a global scheduler change based on higher totals on one clip. Retain the current default and full evidence windows. The final prototype repeatedly loses IMG_8606 contacts at0.566,8.403,18.25s while gaining3.368s. The loss ledger distinguishes no candidate, ground rejection and body-hand rejection. Those original-frame contact/recovery decisions are the next useful investigation while holding the regular schedule fixed. Avoid compensating with clip-specific thresholds or relaxing ground/hand vetoes wholesale.', '',
'PHONE STATE:',
('Restored and freshly verified build2026102913 with revision2, all24 existing counter flags, no shared-history/source-cadence flag, and IMG_8874 main preview at24 touches, position0, outlines off.' if (OUT/'restore/verified.json').exists() else 'Restoration pending.'), '',
'EVIDENCE:',
'Full raw results and source snapshots: sibling folders source-cadence-iphone17, source-cadence-final-iphone17 and source-cadence-reserved-iphone17. This folder includes all-runs.json. Final comparison: source-cadence-reserved-iphone17/summary.json and event-comparison.json. Prior same-frame audit: source-cadence-reserved-iphone17/prior-same-frame-pose-audit.json.']
(OUT/'RESULTS.txt').write_text('\n'.join(text)+'\n')
print(OUT/'RESULTS.txt')
