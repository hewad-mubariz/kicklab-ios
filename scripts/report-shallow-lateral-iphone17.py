#!/usr/bin/env python3
"""Persist the measured outcome and its limits after the phone comparisons."""
import json,statistics
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT/'artifacts/vision-revisions-20261029/contact-evidence-audit-iphone17'
s=json.loads((BASE/'summary.json').read_text())
lines=['IPHONE 17 CONTACT EVIDENCE EXPERIMENT — 29 OCTOBER 2026','',
'DECISION: Keep the new proof opt-in. Do not promote this experiment to the normal debug profile, main app or TestFlight. The low-clip recovery is real but narrow, and a fresh paired replay lost a previously counted IMG8874 contact.', '',
'COMPARISON: Both arms use body pose revision2, the existing 24 counting flags, automatic compute selection and the existing scheduler with the full evidence window. This is not a legacy-pose versus revision2 comparison. The experimental arm adds only --shallow-lateral-contact-v1, in debug builds.', '',
'WHAT CHANGED: A four-view proof for a shallow ball dip redirected by a lateral foot swing. It requires reliable joints, resolved foot motion in image and hip-relative coordinates, closing distance to the ball, an above-ankle contact, two release views and no confirmed floor proof. It uses already collected evidence and retains the body/hand/holding vetoes. It is evaluated only after the established evidence-collection paths. No clip name or absolute timestamp is used.', '',
'FRESH PHONE RESULTS: legal contacts (known false counts shown separately). Every entry is a completed original-video replay through the paced live pipeline; startup frame omissions are recorded below.']
for p in s['pairs']:
    lines.append(f"{p['clip']} repeat {p['repeat']}: legal {p['legal'][0]} -> {p['legal'][1]}; known false {p['knownFalse'][0]} -> {p['knownFalse'][1]}; unmatched {p['unmatched'][0]} -> {p['unmatched'][1]}; gained {p['gainedSeconds']}; lost {p['lostSeconds']}.")
lines+=['','PERFORMANCE: per-clip averages of completed runs; these small timing differences do not establish a speed improvement.']
for clip in sorted({r['clip'] for r in s['runs']}):
    parts=[]
    for arm in ['baseline','lateral']:
        rs=[r for r in s['runs'] if r['clip']==clip and r['experimentArm']==arm]
        if not rs:continue
        parts.append(f"{arm}: pose calls {[r['poseTiming']['calls'] for r in rs]}, mean pose {statistics.mean(r['poseTiming']['totalMS']/r['poseTiming']['calls'] for r in rs if r['poseTiming']['calls']):.2f} ms/call" if any(r['poseTiming']['calls'] for r in rs) else f'{arm}: no pose calls')
        parts[-1]+=f", frame pipeline median {statistics.mean(r['latencyMedianMs'] for r in rs):.1f} ms"
        notify=[r['notificationLatencyMedianMs'] for r in rs if r['notificationLatencyMedianMs'] is not None]
        if notify:parts[-1]+=f", touch notification median {statistics.mean(notify):.1f} ms"
    lines.append(clip+': '+'; '.join(parts)+'.')
rows=s['runs']
lines+=['',f"Completed runs: {len(rows)}. Highest thermal state: {max(r['worstThermal'] for r in rows)} (0=nominal, 1=fair). Pose errors: {sum(r['poseTiming']['errors'] for r in rows)}. Late source skips: {sum(r['lateSourceSkips'] for r in rows)}. Overflow drops: {sum(r['overflowDrops'] or 0 for r in rows)}.", '',
'CAUSAL CHECK: Disabling only the new proof on each completed experimental low trace changes 162 to 161 on identical inputs: the recovered counter event is 9.500 s, matched to the reviewed 9.56 s contact. It loses no other event in either replay. All six other experimental traces have identical touches with the proof enabled or disabled. The extra fresh-run count in normal_juggling_4 is therefore not isolated to this proof. This is stronger evidence than comparing totals from different detector schedules.', '',
'SOURCE SKIPS: normal_juggling_4 skipped ten startup source frames in each arm. Both traces begin at 0.337 s and have no later source-time gaps over 50 ms. The original file starts at 0.000 s, so these are replay startup skips, not missing frames in the file. All other tested runs have zero late source skips. Do not treat the normal_juggling_4 pair as a complete first-frame-to-last-frame throughput result.', '',
'IMG8874 REGRESSION: In repeat 1, the 7.39 s legal contact was counted by baseline and rejected as ground by the experimental fresh run. The regular detector samples near it shifted from 7.103/7.203/7.303/7.403 s to 7.170/7.270/7.370/7.470 s, with an additional impact-gap measurement. Removing the new proof from that saved run still produces 23, so the proof itself is not the direct rejection cause. Both arms returned 24 on repeat 2. The changed end-to-end result still fails the promotion requirement; scheduling variability is not a reason to ignore a lost legal touch.', '',
'LOW REPEAT VARIATION: The second unchanged-baseline run fell to 156, while the experimental arm again reached 162. That pair gained eight labelled contacts but lost the legal contacts at 28.06 and 37.43 s. Only the 9.56 s gain is isolated to the new proof by the identical-input ablation. Do not advertise the six-count net gain as the effect of this rule. These runs do not separate ordinary timing variation from the experimental code perturbing processing timing.', '',
'OTHER MISSES: The examined low baseline has 34 reviewed misses: 22 have no nearby candidate and 12 have rejected candidates. Four early no-candidate windows occur before player lock. Two later windows have no ball input near impact. Fourteen no-candidate windows have continuous ball observations. Production trajectory replay shows that some compact reversals leave only one falling frame after smoothing, below the two-frame arming requirement; at 4.06 s the smoothed rise is about 0.006 versus the 0.007 normal minimum, with insufficient impulse for the stronger early probe. These are candidate-generation/evidence problems, not proof that revision2 latency alone caused the misses.', '',
'VALIDATION: App build2026102921 succeeded. Seventeen evidence contracts passed, including missing/duplicate views, weak joints, stationary feet, absent reversal, below-ankle ball, shifted absolute timestamps and an overriding real floor proof. The opt-in flag is absent from all shipping/field default profiles. All 107 historical traces replayed exactly with the default path; evidence-only screening spans 23 unique clips and matched only the same low contact in four repeated traces. This screen cannot supply missing downstream callbacks and is not a fresh 23-clip phone benchmark. Fresh run count, exported touches, trace replay, source coverage, build, revision flags and quality reports were verified.', '',
'LIMITS: iPhone17 only. Original-video paced replay is not a new camera capture session and does not fix the ordinary-import discrepancy. These results do not establish iPhone11 performance, whole-corpus accuracy, or a replacement for the current production pose implementation.', '',
'NEXT: Keep the stable field build. Investigate compact-reversal candidate generation with saved motion evidence and the ground-verdict sensitivity to measured impact timing. Any candidate change needs an independent fresh comparison and event-level ground/hand regressions; do not globally lower the movement thresholds.', '',
'PHONE: '+('Restored and verified field build2026102913, revision2 default, no experimental flags, IMG8874 main preview 24 touches at position zero with outlines off.' if (BASE/'restore/verified.json').exists() else 'Restoration not yet verified.'), '',
'EVIDENCE: summary.json, protocol.json, source-sha256.json, offline-screen.jsonl, historical-replay.txt, ablation.jsonl, contract-results.txt, baseline-low-miss-audit.json, low-trajectory.jsonl, img8874-7.39-investigation.json and per-arm phone run folders.']
(BASE/'RESULTS.txt').write_text('\n'.join(lines)+'\n')
dest=ROOT/'benchmarks/touch-counting/vision-revisions-20261029/contact-evidence-audit-iphone17'
dest.mkdir(parents=True,exist_ok=True);(dest/'RESULTS.txt').write_text((BASE/'RESULTS.txt').read_text())
print('Wrote',dest/'RESULTS.txt')
