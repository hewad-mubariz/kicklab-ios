#!/usr/bin/env python3
"""Preserve the outcome of each scheduling prototype and its accuracy limits."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261030/impact-neighbor-iphone17'
summaries=[]
for version in [1,2,3,4]:
    folder=BASE if version==1 else BASE/('budget-only' if version==4 else f'v{version}')
    if (folder/'summary.json').exists():summaries.append((version,json.loads((folder/'summary.json').read_text())))
rows=[r for _,s in summaries for r in s['runs']]
lines=['IMPACT EVIDENCE DELIVERY — IPHONE 17, 30 OCTOBER 2026','',
    'STATUS: Explicit debug experiments only. No main-app, default field profile or TestFlight promotion. Counting, body/hand/holding/ground thresholds and pose revision are unchanged in this study. Earlier compact-candidate and floor-margin experiments remain off.', '',
    'DECISION: Do not promote any of these four scheduling prototypes. The final budget-only pair keeps low at161 and IMG8874 at24; IMG8606 improves33->35 but loses the12.505s legal contact, and raw-juggling stays7 while trading5.60s for4.98s. This has not demonstrated reliable recovery while preserving existing legal touches. No additional labelled false counts or unmatched counts appeared in these four-clip comparisons; the existing IMG8606 false count remains in the final pair. This is not a complete ground-bounce regression certification.', '',
    'CONFIRMED PROBLEM: When the single RF worker refuses a gap retry because it is busy, the ordinary schedule spends its 300 ms cooldown despite performing no retry. The prior retry-on-admission experiment already addressed later opportunities but exposed false ground counts; it was not enabled here. This study instead reserves the SAME requested source frame briefly, with no new inference queue or substituted exposure.', '',
    'PROTOTYPES:',
    '1. Build2026103001 / --rf-reserved-gap-v1: one pending original frame after busy admission, maximum 50 ms wait and the existing 250 ms start/backlog limit. Score >=0.7, identity gate and 400 ms result deadline remain. Actual admitted work owns the cooldown.',
    '2. Build2026103002 / --rf-reserved-gap-v2: newly admitted reserved retries leave the existing regular timing clock unchanged. Ordinary non-reserved retries and regular admission retain their established behavior; this is not a source-clock grid.',
    '3. Build2026103003 / --rf-reserved-gap-v3: retain version2 and yield additional overdue tracking work after an 8 ms processing slice. Always process at least one frame; a Vision call cannot be preempted, so this is a soft budget, not a maximum per-call guarantee. Keep the existing 16-frame tracking buffer, 32-frame counter queue and one RF model/worker. Both arms record drain duration and frame count.', '',
    '4. Build2026103004 / --rf-drain-budget-v1: isolate the catch-up budget with the ORIGINAL gap retry and regular scheduling rules. No reserved retry is admitted in this arm. The result-directory name reserved is retained by the harness, but the verified reservedImpactGap flag is false and trackingDrainBudget is true.', '',
    'WHY THE THIRD PROTOTYPE EXISTS: In version2 low footage, a reserved retry at 19.800 s is followed by a burst of overdue frames. Individual processing costs include 11.5,21.5,8.1,7.5,16.6,6.1,5.8 ms; the source frame at 20.167 s is then omitted. Similar new gaps appear at 45.633 and 51.933 s. Preserving only the regular timer does not prevent this catch-up burst. The experiment tests whether yielding that work protects capture ingestion.', '',
    'FRESH PAIRS — legal contacts; known false and unmatched counts reported separately:']
for version,s in summaries:
    lines.append(f'Prototype {version}: {s["completedRuns"]} completed runs.')
    for p in s['pairs']:
        lines.append(f"  {p['clip']} repeat {p['repeat']}: legal {p['legal'][0]} -> {p['legal'][1]}, false {p['false'][0]} -> {p['false'][1]}, unmatched {p['unmatched'][0]} -> {p['unmatched'][1]}; gained {p['gainedSeconds']}; lost {p['lostSeconds']}; reserved {p['reservedSubmitted']}, used {p['reservedUsed']}, expired {p['reservedExpired']}.")
lines += ['', 'REPEATABILITY OF THE COMPARATOR:']
for clip in sorted({r['clip'] for r in rows}):
    controls=[r for r in rows if r['clip']==clip and r['experimentArm']=='baseline']
    counts=[r['acceptedValid'] for r in controls]
    if counts:
        lines.append(f"  {clip}: experiment-off legal counts {counts}, range {min(counts)}–{max(counts)}. These runs share the existing revision2 counting rules; they are not App Store/legacy comparisons.")
lines += ['',
    'INTERPRETATION: A gained/lost label identifies a difference between two fresh executions, not proof that the experimental flag alone caused that individual difference. The comparator itself varies as detector scheduling shifts. A higher total can conceal lost legal contacts. These single pairs are sufficient to withhold promotion when preservation is unproven, but do not establish statistical superiority or inferiority.', '',
    'REFERENCE QUALITY: Counts use the existing manually reviewed development labels, including supplemental IMG8606/IMG8874 references. They are not a new independent ground-truth audit or an accuracy percentage for all footage.']
lines += ['', 'FRAME DELIVERY AND PERFORMANCE:']
for version,s in summaries:
    for r in s['runs']:
        mean=r['poseTiming']['totalMS']/r['poseTiming']['calls'] if r['poseTiming']['calls'] else 0
        lines.append(f"v{version} {r['experimentArm']} {r['clip']} r{r['repeat']}: source skips {r['lateSourceSkips']}, late RF {r['lateReplies']}, overflow {r['overflowDrops']}, thermal {r['worstThermal']}, regular/gap RF {r['worker']['regular']}/{r['worker']['impact_gap']}, pose calls {r['poseTiming']['calls']} at {mean:.2f} ms mean, frame latency median {r['latencyMedianMs']}, notification median {r['notificationLatencyMedianMs']}, max drain {r.get('maxDrainMs')}, max frames/drain {r.get('maxFramesPerDrain')}, budget yields {r.get('drainBudgetYields')}.")
if (BASE/'same-source-rf-audit.json').exists():
    a=json.loads((BASE/'same-source-rf-audit.json').read_text())
    lines += ['', f"SAME-SOURCE AUDIT: Across the targeted impact windows, {a['repeatedSourceFrames']} source timestamps were measured more than once; RF candidate-count disagreements {a['repeatedCandidateCountDisagreements']}, accepted-box disagreements {a['acceptedBoxDisagreements']}. This compares only actually measured frames, not the entire corpus or unobserved frames. It does not audit all pose outputs.",
        'Raw-juggling example: RF repeatedly finds no candidate at 4.368 s and finds the ball at 4.402 s; neighboring 4.335 and 4.435 s measurements can also be empty. A sampling phase that misses 4.402 s can therefore lose a visible kick. A busy retry fix cannot guarantee a positive model result on its reserved frame. The same video contains visible motion blur; this is not solely a body-pose request-time issue.']
if (BASE/'same-timestamp-pose-evidence.json').exists():
    a=json.loads((BASE/'same-timestamp-pose-evidence.json').read_text())
    lines += ['', 'SEPARATE POSE-EVIDENCE REPEATABILITY FINDING:']
    for p in a['pairs']:
        if p['changedTimestampsMs']:
            lines.append(f"  v{p['version']} {p['clip']}: {len(p['changedTimestampsMs'])}/{p['commonTimestamps']} common timestamps have different selected ankle records; aggregate raw empty-pose calls baseline/candidate {p['rawPoseEmptyCalls']}.")
    lines += [
        'For v3 IMG8606, 29 of472 common timestamps differ, beginning17.941s: a baseline sample has two confident ankles while the candidate has none. The v4 budget-only pair reverses the aggregate empty-pose pattern (35 baseline,1 candidate), so this cannot be attributed solely to reserved retries. The other three clips show identical ankle records at their common saved timestamps in every pair.',
        a['limitation'], '',
        'NEXT TARGETED INVESTIGATION: Preserve the actual pose input pixels/hash, raw per-frame observation count and selected-player result around17.9–19.6s of IMG8606, then repeat the exact images independently. This separates image preparation/retention, Vision request behavior and person matching before changing another counting or ground threshold. Do not weaken a hand or ground veto to compensate for missing landmarks.']
lines += ['',
    'SOURCE TIMELINE CAVEAT: raw-juggling.mov itself has timestamps 0.000, then 1.966667,2.000,..., confirmed with ffprobe. Do not call that original 1.97 s discontinuity a pipeline-induced gap. Additional reported source skips are separate. The actual mid-clip low-video gaps listed above are new admitted-frame omissions.', '',
    'VALIDATION: Build logs and contract results are retained per prototype. Each completed phone run validates build, explicit flags, source SHA, end coverage, complete exact counter replay, exported touches/report count and quality status. Existing counting source files and default feature selections were not changed in this turn. Both arms include the same new diagnostic instrumentation. Python tools compile; whitespace checks pass.', '',
    'LIMITS: iPhone17 Pro Max only, nominal/fair admission, paced original-video replays rather than new live camera recordings. Not a legacy-versus-revision2 benchmark, not an iPhone11 or long-session thermal certification. Frame counts and raw RF recoveries are not themselves legal-touch gains. Fresh pairs still require event-level interpretation when detector phases differ. No wider corpus accuracy percentage is claimed.', '',
    'PHONE: '+('Field build2026102913 restored and verified; revision2, existing24 flags, no experimental scheduling flags, IMG8874 preview at24 touches and position0 with outlines off.' if (BASE/'restore/verified.json').exists() else 'Restoration not yet verified.'), '',
    'EVIDENCE: Per-version protocol/source SHA snapshots, contracts, build logs, summary.json, per-arm original-video reports/traces/labels, same-source-rf-audit.json, same-timestamp-pose-evidence.json, raw-phase-audit.json, raw-source-start.csv and raw-impact-strip.jpg.']
(BASE/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
dest=ROOT/'benchmarks/touch-counting/vision-revisions-20261030/impact-evidence-delivery-iphone17'
dest.mkdir(parents=True,exist_ok=True);(dest/'RESULTS.txt').write_text((BASE/'RESULTS.txt').read_text())
print('Saved',len(rows),'completed runs to',dest/'RESULTS.txt')
