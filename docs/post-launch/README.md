# Four-week post-launch plan

Documented: 2026-10-11. Product priorities updated: 2026-10-18.
Status: in progress; implementation and verification status must be read separately.
Week 1 starts after the first public release, rather than on the documentation date.

The first month's priorities are trustworthy counting, better ball detection and
tracking, dependable sessions on older devices, and a fair leaderboard. Replay quality
and shot-camera improvements follow.
The first post-launch update is limited to the improved counter and older-device
session reliability. Leaderboard submissions and voluntary video sharing follow in
a separate release. Google/email rollout must not delay the counter update. TikTok
sign-in, additional effects and production trick recognition can follow later.

## Next three product targets — 18 October 2026

The owner selected these three targets, in this order. This ordering supersedes the
original weekly allocation below; the current candidate's release checks continue
alongside this work.

1. **Google and email sign-in.** Enable the existing flows after verifying provider
   readiness, cancellation/retry, expired links, restored sessions and preservation
   of guest history and account/subscription access. The controls are enabled in
   source as of 18 October; building and runtime verification are deferred at the
   owner's request. Existing guest history stays in its separate local library.
   The [account setup notes](../auth-setup.md) record completed Google branding and
   SES production setup; email sending limits and delivery monitoring still need
   an explicit rollout decision.
2. **Reviewed leaderboard beta.** Implement continuous ranked streaks, deliberate
   original-video submission, pending/approved/rejected states and backend-controlled
   approval. Start with reviewed scores and separate optional training-data consent
   from score review. Confirm the proposed contact policy before implementing scoring;
   the 18 October design draft below recommends including clean knee/thigh contacts.
3. **Ball replacement edges and consistency.** Improve original-ball edge leakage,
   motion-blur coverage and flicker across preview and saved exports, with acceptable
   preparation cost on older phones. Keep appearance repairs separate from touch
   evidence and preserve existing counts.

### Ball replacement handoff

- **Known issue:** the original patterned ball can remain visible outside the
  replacement, and coverage can flicker around fast contacts/indoor motion blur.
  The source-frame timing fix preserves captured frames; it does not solve these
  outline/coverage errors or recover frames missing from the original recording.
- **Evidence:** the [replacement comparison](../../benchmarks/touch-counting/rf-ball-replacement-20261018.json)
  compares 288/384 preparations of the same 29.6-second indoor recording. The
  report is also mirrored in the sibling lab repository at
  `benchmarks/v2/rf-ball-replacement-20261018.json`. Local visual evidence and exports
  live under `artifacts/rf-ball-replacement-20261018/`; these are not bundled Git assets.
- **Finding:** 384 improved outline continuity on this clip, but did not eliminate
  blur/edge errors. Full preparation on iPhone 11 was expensive. This one clip/skin
  is development evidence, not an independent quality evaluation.
- **Test-build candidate:** bounded higher-resolution repair of weak/missing
  outlines, followed by edge/blur refinement. Do not indiscriminately enlarge the
  replacement over the player or require a full 384 pass on every older-device clip.
- **18 October isolated follow-up:** the [live/replay path audit](../../benchmarks/touch-counting/ball-replacement-path-audit-20261018.json)
  confirms the recording-screen glow trail consumes delayed counter snapshots:
  200 ms tracking buffering, contact processing, then roughly 8 Hz UI publication.
  Correct live appearance needs a coherent camera-frame/observation path; raising
  SwiftUI refresh rate alone cannot align those historical positions.
  A focused `BallReplacementCoverage` correction now retains valid mask lobes at
  the source-frame boundary. The previously failing photographed fast-ball test
  and 71 other rendering tests pass in an isolated simulator; counting is unchanged.
  Separately, an offline RF384 crop experiment produced masks for all four missing
  frames among 12 selected indoor stills and improved a truncated outline with
  Pearl, Gold and Stealth. That initial crop experiment was **not enabled in the app**:
  automatic selection/identity checks, occlusion controls, motion continuity and
  device cost remain unqualified. One pre-existing simulator reanalysis test also
  failed with “Ball tracking was interrupted”; the broader suite is not all green.
  No physical phone was accessed or installed during this follow-up.
- **18 October combined test build:** [integration report](../../benchmarks/touch-counting/ball-replacement-integrated-20261018.json).
  Build **1.0.1 (24)** is installed in the main Juggle Dude app on iPhone 17 Pro Max.
  Live glow now renders a matched source frame and observation together, using
  one replaceable packet and the existing Metal compositor. The preview inherits
  the tracker's roughly 200 ms delay, draws at up to 30 Hz, and reveals the normal
  camera if tracking stalls. Counting and recorded-video timing are unchanged.
  Replay/export now run a bounded RF crop pass after existing gap repair. It uses
  current pixels, strict identity/size/alpha-support checks, thermal pacing and
  at most 240 requests; repaired masks remain separate from counting input.
  The combined simulator selection passed 121 tests; seven physical-camera tests
  were skipped. A full saved-video simulator rerun could not launch the app and
  is not a completed quality or performance check. Manual live/replay/export,
  occlusion, memory and thermal acceptance remains required before shipping.
- **Completion checks:** fresh indoor/outdoor and fast/occluded recordings, preview
  versus exported placement, multiple skins, unchanged touch events, and measured
  preparation/export time, memory and thermal behavior on older/newer phones.

The iOS integration is in `kicklab/Effects/` in this repository; model/segmentation
experiments may be developed in `kicklab-lab`, with provenance and results brought
back here before application integration. A local report or artifact existing on
disk does not mean it has been committed or pushed.

## Schedule and scope

Assume one primary developer and 20 working days, including five days for device
verification, fixes and release preparation. Ship smaller updates as they are ready;
App Store review and external provider approvals are outside the engineering estimate.
These are planning allocations, not guarantees that every investigation will succeed.

### Immediate release sequence

1. Prepare and validate the counter update while the initial version is in review.
   Keep this work separate from leaderboard, upload and sign-in feature changes.
2. After the initial version is released and Ready for Distribution, submit the
   counter/reliability update as soon as its release gates pass. The Week 1 budget
   is not a reason to wait if the update is ready earlier.
3. Follow with the reviewed leaderboard beta, including private original-video
   submission. Optional model-training consent is separate from score review.

Smaller releases limit implementation and verification scope; they do not guarantee
an App Review turnaround. Apple's guidance says minor updates and bug fixes typically
move through review quickly, but individual submissions can take longer. See
[review timing](https://developer.apple.com/help/app-review/after-submitting-for-review/review-status/)
and [creating the next version](https://developer.apple.com/help/app-store-connect/update-your-app/create-a-new-version).

| Week | Implementation allocation | Verification / fixes | Intended release |
| --- | --- | --- | --- |
| 1 | 4 days: detection baseline, contact accuracy and older-device reliability | 1 day | Counter and core reliability update |
| 2 | 1 day: Google/email; 3 days: reviewed leaderboard beta | 1 day | Sign-in rollout and a gated leaderboard beta |
| 3 | 3 days: detection/tracking and ball replacement; 1 day: essential effects/UI fixes | 1 day | More continuous tracking and cleaner replays |
| 4 | 1 day: shot camera; 2 days: far-ball detection and measurement validation if time permits | 2 days | Camera/detection improvements; measurement beta only if validated |

The dependency order is detection/contact accuracy and session reliability, then
ranked streak validation, then the public leaderboard. Authentication must work before
ranked submissions. Far-ball detection and tracking must be validated before expanding
shot measurements. Measurement validity determines the supported camera setup.

The added detection work uses the same four-week budget: cosmetic UI work and broader
effect enhancements become stretch scope, and measurement expansion is conditional.
Full model retraining is not a guaranteed first-month deliverable; ship bounded,
validated improvements and carry larger experiments into the next cycle.

## Prioritized backlog

The original item numbers refer to the launch follow-up list. Google/email and TikTok
are separated because their priority and release scope differ.

| Order | Original item | Task | Priority | Difficulty | First-month commitment |
| --- | --- | --- | --- | --- | --- |
| 1 | 4 | One-hand touches mistaken for chest/head | Critical | High | Fix known cases while preserving valid touches. |
| 2 | 3 | iPhone 11/12 live counting | Critical | High | Improve live performance and provide reliable record-then-analyse fallback. |
| 3 | Added follow-up | Model accuracy, far-ball detection and continuous tracking | High | High | Benchmark in Week 1; bounded accuracy/continuity improvements in Week 3 and far-ball work in Week 4. |
| 4 | 1 | Google and email sign-in | High | Low–medium | Complete production rollout and verify account continuity. |
| 5 | 2 | Fair leaderboard | High | High | Small opt-in beta with reviewed scores after counting validation. |
| 6 | 8 | Ball masking and replacement | High | Medium–high | Remove original-ball edge leakage and improve preview/export consistency. |
| 7 | 6 | UI edge cases and transitions | Medium | Low–medium | Address usability problems throughout the month; cosmetic work is stretch scope. |
| 8 | 9 | Existing fire/rainbow effects and execution cost | Medium | Medium | Fix essential performance issues; broader enhancements and new effects are stretch work. |
| 9 | 10 | Distance-shot camera experience | Medium | Medium | Improve placement guidance, framing and recording feedback. |
| 10 | 5 | Real speed and distance travelled | Medium | High | Validate a defined measurement mode if detection work leaves time; ship only with supporting evidence. |
| 11 | 7 | Around the World recognition | Later | High | Deferred beyond this beta; no recognition, badges or trick points in this release. |
| 12 | 1 | TikTok sign-in | Low | Medium | Defer until there is clear demand. |

An edge case that blocks recording, loses a session or prevents saving is a critical
fix regardless of the general UI priority above.

## Model improvements: accuracy, far balls and continuous tracking

Treat these as three related goals. Improving the detector and improving continuity
across frames both matter; a visually smooth prediction is not proof the ball was detected.

| Goal | Planned work | Evidence of improvement |
| --- | --- | --- |
| Better ball detection | Collect and label missed balls and false positives across ball designs, lighting, backgrounds, fast motion and partial occlusion. Compare detector tuning and targeted fine-tuning candidates against the current model. | Higher detection recall without an unacceptable rise in false positives; stable ball location/size and no counting regression. |
| Far-ball detection | Add small/distant-ball examples and confusing background objects. Evaluate targeted crops, selective higher-resolution analysis and distant-ball recovery within device budgets. | Better recall for visible small balls, fewer false detections on background objects and a documented supported range. |
| Continuous ball detection/tracking | Reduce flickering detections, short dropouts and switches to another ball/object. Improve short-gap recovery and reacquisition after occlusion or leaving/re-entering the frame. | Fewer and shorter gaps while the ball is visible, fewer identity switches and faster correct reacquisition. |

- [ ] Establish a versioned baseline in Week 1, covering both live capture and imported
  video. Include iPhone 11/12 and a newer device, near/far balls and difficult negatives.
- [ ] Split training/tuning and evaluation by recording/session, and by player where
  practical; do not place adjacent frames from the same recording in both sets.
- [ ] Measure precision, recall and location/size error. Break results down by the
  ball's pixel size at detector input, visibility, lighting and device. Do not promise
  a distance in metres unless camera setup and ball size are controlled.
- [ ] Measure visible-ball coverage, gap duration, identity switches and reacquisition
  time. Label full occlusions/out-of-frame intervals separately from missed visible balls.
- [ ] Keep observed detections distinct from predictions. Bound any gap recovery and
  stop or mark tracking uncertain when evidence is insufficient; do not invent touches,
  bridge ranked streaks or calculate speed/distance from unsupported predictions.
- [ ] Compare model changes and tracking-policy changes separately so the source of
  an improvement or regression is clear. Include masks/replacement quality in evaluation.
- [ ] Record model/data versions and evaluate inference latency, memory, dropped frames
  and thermal behaviour on physical devices before replacing the shipped model.
- [ ] Keep the existing model available for rollback. Ship a candidate only after
  held-out accuracy, counting and device-performance checks pass.

**Release gate:** set numerical targets and acceptable tradeoffs after the Week 1
baseline, before evaluating candidates. Ship only measured improvements within the
older-device budget. Broad retraining or a larger model moves to the next cycle if
the bounded experiments do not meet those checks.

## Week 1: Core session reliability

See [current touch counting strategy and gaps](../touch-counting-strategy.md) for
the implemented decision order, verified results and remaining validation work.

**2026-10-13 candidate:** 1.0.1 (14) promotes the tested counter rules and makes the
Normal counter and timer free in capture, replay and export. 118 regression tests
and the free replay UI check pass; the signed Release archive is installed locally.
The user reported a device-test issue and requested holding the TestFlight upload.
Resolve that report before uploading. Physical iPhone 11/12 performance remains
unverified; frame-rate simulation on a newer phone does not close that gate.

**2026-10-16 physical iPhone 11 Pro Max check:** iPhone12,5 on iOS 26.6.2
cannot load the current RF-DETR FP16 export with CPU + GPU execution. A
model-load fallback for RF models now keeps that same export on CPU when accelerated
loading fails. Thirteen focused device checks pass. A 30.2-second automated
camera recording retained 1,813 frames at approximately 60 fps with no capture
or writer drops, while live analysis processed 222 frames (about 7.3 fps).
Sampled app footprint peaked at 94.4 MiB and thermal state stayed nominal.
No verified juggling contacts or pose requests occurred in this smoke check;
it does not close counting accuracy, warm-session or release validation.
The subsequent real juggling recording retained 1,816 frames over 30.3 seconds,
with four capture drops and zero writer drops. It processed 204 frames live
(6.7 fps) and counted three touches. Uncached saved-video analysis counted eight
in 489.5 seconds, with 210.5 seconds of thermal pacing and serious thermal state.
Preliminary frame review suggests ten genuine kicks; two full-frame candidates
were rejected as ground bounces. Ground-truth confirmation and broader validation
remain pending. Live throughput, ground rejection and a practical saved-video
fallback therefore remain open. See the
[README investigation notes](../../README.md) and local evidence in
`artifacts/iphone11-20261016/`. No TestFlight upload was made.

**GPU follow-up:** a reproducible four-layer export rewrite now executes with
CPU + GPU on that physical iPhone 11, retaining identical learned weight bytes.
Four rewrite tests pass. A 24-image comparison measured 121 ms CPU, 879 ms for the
compatibility GPU export and 421 ms for a newer GPU export. All measured frames
were at serious thermal state; these are diagnostic prediction times, not live
FPS qualification. There were no ball-confidence threshold flips in those images,
but touch accuracy remains unqualified. A Metal trace confirms real GPU work in
the earlier eight-layer variant. The app model was not replaced: the GPU exports
would currently make live counting slower. The GPU load blocker has a verified
workaround; live throughput and contact accuracy remain open release blockers.
See the [GPU evidence](../../benchmarks/touch-counting/iphone11-gpu-20261016.json).

**17 October overnight comparison:** 64 attempted trials yielded 58 completed
trials, four original RF16 accelerated-load failures and two unresolved YOLO26
Small GPU-load timeouts. All six ten-minute endurance runs completed. YOLO26
Small automatic measured 30 ms median prediction and 34 ms input/output cycle,
versus RF16 CPU at 152/158 ms; measured whole-run cycle rates were 28.3 and 6.4/s.
These are isolated model loops on 24 repeated development stills, not live FPS
or counting accuracy. All long runs reached serious thermal state. Diagnostic
logging confounds process-memory growth, and selected-box review found spare-ball
selection errors. Active-ball association, bounded-logging endurance and actual
camera/pose/counter validation remain required before any model promotion.
See the [reviewed overnight report](../../benchmarks/touch-counting/iphone11-endurance-20261017.json).

The owner has excluded paid Ultralytics enterprise licensing from the release
plan. YOLO26 timing results do not authorize a model switch. Continue the
RF-DETR work. The owner's subsequent direction is one shared RF-DETR model across
devices: keep the current Seg Small checkpoint and optimize its export/runtime and
live pipeline. YOLO/YOLOX and device-specific detector models are outside this plan.
Different CPU/GPU execution choices do not change the shared model. Preserve masks,
ball/person outputs and counting checks; faster inference alone does not qualify a
release. See the [shared RF-DETR study](../../benchmarks/touch-counting/iphone11-rf-shared-20261017.json).

**2026-10-17 cross-device follow-up:** identical standalone Metal/MPS tests passed
on both physical phones, including FP16 (630 measured GPU timings per device).
The A13/newer-phone gap varied from ~2× for copying to 12–52× for the tested
matrix shapes. Different OS versions prevent a hardware-only attribution.
RF-DETR still measured ~117 ms on A13 CPU versus ~353 ms with the rank-two GPU
export; the newer phone measured ~41 ms CPU and ~19 ms with that same GPU export.
Explicit dense matmul caused an A13 MPSGraph assertion before measured predictions;
Core ML optimization/low-precision hints did not provide a useful speedup.
No candidate was promoted and the live-counting release gate remains open. See
the [cross-device study](../../benchmarks/touch-counting/metal-rf-cross-device-20261017.json)
for numerical checks, conditions and raw evidence.

**2026-10-17 targeted profiling and tracking:** actual GPU work overlapped 9.59 of
13.23 seconds across 37 A13 RF prediction intervals. The GPU is executing; CPU
fallback alone does not explain the slow compatible export. A narrower rewrite of
24 backbone feed-forward operations retained checked outputs but gave no useful
GPU gain (355 → 353 ms on A13; 19.11 → 19.13 ms on the newer phone). Six focused
rewrite tests pass. See the
[backbone report](../../benchmarks/touch-counting/iphone11-rf-backbone-20261017.json).

Four bounded tracking comparisons on both phones retained the same original
RF-DETR 384 model on CPU. On an eight-second development segment sampled at 30 fps,
fixed RF cadence plus native pixel tracking took 6.64 seconds on A13 but supplied
only 162/240 observations; immediate recovery took 11.61 seconds for 220/240.
Budgeted recovery took 7.23 seconds for 172/240. At 20 fps, recovery with regular
cadence after empty RF results still took 9.31 seconds for 144/160 observations.
That already exceeds clip duration without camera, pose or counting costs.
Reference RF sometimes selects a second floor ball, so availability and agreement
are not accuracy. This is diagnostic evidence, not a promoted live-counting fix.
See the [initial/recovery](../../benchmarks/touch-counting/rf-tracking-feasibility-20261017.json),
[budgeted recovery](../../benchmarks/touch-counting/rf-tracking-budget-20261017.json)
and [20 fps](../../benchmarks/touch-counting/rf-tracking-20fps-20261017.json) reports.
Next evaluate asynchronous RF inference with bounded history and tracker catch-up,
primary-ball association, observation provenance and contact/mask validation.
Sustained full-pipeline performance and labelled live counting remain release gates.

**2026-10-17 asynchronous prototype, iPhone 11 only:** the owner excluded iPhone 17
while another test ran. A diagnostic worker now runs one RF inference at a time
with bounded video retention. Immediate tracker catch-up reduced delay but left
large observation gaps. A chronological 200 ms analysis buffer processed all
scheduled 60 fps samples in repeated short replays, with no late RF replies or
buffer overflow; this excludes the camera, pose, counter and mask pipeline.
The initially high coverage was rejected because it tracked the spare floor ball.
A fixed-camera acquisition heuristic avoided that reviewed region, but still has
camera-motion and reacquisition limitations. A guarded confidence experiment
improved fast-section observation availability to 127–131/240 versus 97–114/240
for strict tracking, while gaps still reached 267–283 ms. Five focused policy
checks pass; original model hashes and production tracker remain unchanged.
This is a scheduling prototype, not a qualified live-counting fix. See the
[asynchronous investigation](../../benchmarks/touch-counting/rf-async-iphone11-20261017.json)
and [diagnostic source](../../benchmarks/rf-async-control/README.md).

**Full-counter follow-up:** ten full development-clip replays with a frozen copy of the pose,
motion compensation and contact rules showed that high tracking throughput alone
does not ensure correct counts. Direct RF288 counted 7/6 versus RF384's 4/0;
the second rotated round coincided with elevated thermal state. A separate
nominal-start comparison isolated a bounded contact worker: 288/12 Hz counted
8/9 versus 4/4 inline, and dropped 2/1 versus 229/230 source frames. All emitted
timestamps match the approximately reviewed ten development contacts, and all
14 counter traces replay exactly. These are not independent or live-camera tests.
The recurring missed impact has one missing tracker observation; fresh Mac RF
inference can detect the ball on that exact frame. Test a bounded contact-frame
recheck while retaining hand/ground exclusions, then validate live camera/writer
load and independent negatives. These diagnostics did not modify the production
app/model; their frozen source copies exclude concurrent counting changes.
See the [counter matrix](../../benchmarks/touch-counting/rf-async-counter-20261017.json),
[contact queue](../../benchmarks/touch-counting/rf-contact-queue-20261017.json), and
[impact-frame check](../../benchmarks/touch-counting/rf-impact-detectability-20261017.json).

The interrupted shared-export comparison was restarted in its own diagnostic app
after the GPU test finished. All four resumed trials passed provenance, geometry,
queue and exact-trace audits: the original 384/6 Hz strategy matched 9 of 10 reviewed
contacts in each repeat; 288/12 Hz matched 7 and 9. Original 384 processed about
59 frames/second with median touch-notification delay around 0.55 seconds.
This supports retaining the shared original export while testing scheduling fixes.
It is still paced development replay, with fixed-camera acquisition and no live
writer/rendering load. See the
[resumed comparison](../../benchmarks/touch-counting/rf-contact-queue384-resume-20261017.json).

The subsequent eight-trial generic gap-retry test did not justify adding another
RF worker: at 384, control counts were 7/6 and retry counts 5/7; at 288, controls
were 10/10 and retries 9/9 (each entry is a repeat's count out of ten reviewed
contacts). Retry memory and notification delay increased, and one 384 trial
dropped nine counter inputs after reaching the 32-frame queue limit. All eight
audits passed; the variant is not promoted. A contact-candidate-only retry is a
separate untested idea. Even the 384 controls vary across runs, so earlier 9/10
results must not be treated as established live reliability. See the
[retry study](../../benchmarks/touch-counting/rf-contact-retry-20261017.json).

The six-clip sustained 384/6 Hz check then exposed a launch blocker: counts were
8, 7, 7, 5, 4, 4 as thermal state reached serious, RF prediction median rose
123→170 ms and late replies rose 0→49 per replay. The counter queue did not
overflow and throughput remained 58–60 fps. One count was a visually reviewed
stationary-spare-ball false positive. All six traces/provenance audits passed,
but this is evidence against promoting the current workaround as reliable.
See the [sustained study](../../benchmarks/touch-counting/rf-contact-sustained384-20261017.json).

The subsequent six-clip 288/12 Hz study performed better: 10, 9, 9, 9, 9, 8
reviewed contacts, no unmatched counts, and 0–5 late RF replies per clip. Median
prediction rose 66→91 ms. Serious thermal state still occurred, with 84 source
drops in the final clip and touch-notification median growing about 0.56→0.67 s.
All six audits passed. Continue with this as a possible **shared** RF-DETR export,
not a device-specific detector: tune RF cadence/heat and active-ball reacquisition,
then validate current-counter live camera/writer behavior and small/distant balls.
No production promotion is justified yet; the original GPU-loading issue persists.
See the [paired sustained reports](../../benchmarks/touch-counting/rf-sustained-comparison-20261017.json).

The subsequent 30-replay cadence comparison found no reliable cadence-only fix.
Across six repeats each, fixed12 matched 54/60 reviewed contact opportunities;
fixed8, fixed6 and thermal 12/8/6 each matched 50/60. A supplemental identical
fixed8 block matched 47/60 and reached serious thermal state, unlike its first
cooler block. Nominal OS state does not equal matched internal temperatures.
No unmatched counts occurred on this development clip, and all 30 trace, source,
geometry, queue and cadence audits passed. Forty of 49 misses had a nearby
`missingBall` body rejection. Keep fixed12 as the diagnostic control and test a
bounded, genuine contact-frame RF recheck with shared scheduling; generic retries
remain rejected. Validate against the current time-aware counter, then live camera/
writer load and fresh positive/negative footage. No cadence variant was promoted;
the iPhone 17 was untouched and the original GPU-loading failure remains open.
See the [cadence study](../../benchmarks/touch-counting/rf-contact-cadence-20261017.json).

The targeted contact recheck is now implemented in an isolated iPhone 11 diagnostic.
It uses the same RF288 CPU model and serial worker to measure a retained missing
contact frame, with strict source/identity/age limits and unchanged counting rules.
Two short recheck runs matched 20/20 reviewed opportunities versus control 18/20.
Six sustained recheck clips matched **54/60**, versus fresh control **49/60** plus
one visually confirmed false count on the stationary spare ball. A separate
16-pass, fresh-Vision ablation held tracking inputs fixed: saved recheck evidence
raised matched counts **68→74/80**, with no lost or unmatched contacts and exact
reproduction of original decisions when enabled. This isolates six recovered
contacts on repeated development footage, not independent or live-camera accuracy.

Keep it diagnostic. Both sustained blocks reached serious thermal state; recheck
clip six dropped **three counter inputs** at its 32-frame queue limit, and maximum
notification delay reached **0.95 s**. The control had no counter queue drops.
The remaining recheck misses were four ground-bounce rejections and two tracking
losses. The follow-up below tests backlog-aware admission with the current time-aware
counter; continue investigating active-ball selection and ground-versus-foot decisions, followed
by live camera/writer load and fresh positive/negative footage. The original GPU
failure is unchanged; no production source/model promotion occurred. All owned
diagnostic processes stopped; iPhone 17 was untouched. See the
[reviewed targeted-recheck report](../../benchmarks/touch-counting/rf-contact-targeted-20261017.json).

The current-counter follow-up completed **32 paced replays and 24 fixed-input
evidence passes**. At 60 fps, the strict backlog/idle-worker guard matched 47/60
reviewed contacts, waiting rechecks 51/60, and the disabled control 48/60 plus one
spare-ball false count. All three had zero counter queue drops. The strict guard
allowed only one recheck and is not the preferred policy.

At **30 fps analysis**, waiting rechecks matched **60/60** versus control **51/60**,
with no unmatched counts or counter queue drops in either block. Peak queue depth
was 14/32 with rechecks. Fresh-Vision fixed-input checks isolated **44→60/60** from
the saved recheck evidence; the equivalent 60 fps check was **46→51/60**, with no
lost or unmatched contacts and exact reproduction of every evidence-on decision.
These are repeated development clips, not independent or full live-app accuracy.
Both 30 fps blocks reached serious thermal state; recheck notification medians
remained 583–688 ms and peaked at 846 ms. Diagnostic memory peaked at 146 MiB.

Prefer the 30 fps targeted-recheck path for the next **diagnostic integration**.
The app already caps live analysis at 30 fps; the new work is adding bounded
contact-frame evidence recovery to that pipeline. The harness still uses the
older frozen detector/bridge/tracker and nil active-player selections. Validate
the actual current live pipeline, thermal cadence, camera/writer/rendering load,
active-ball/player handling and independent positives/negatives and small balls
before any shared RF288 export promotion. The GPU export failure is unchanged.
All nine owned processes stopped; iPhone 17 was untouched. The
[backlog report](../../benchmarks/touch-counting/rf-contact-backlog-20261017.json)
and [30 fps comparison](../../benchmarks/touch-counting/rf-contact-backlog30-20261017.json)
include source snapshots, separate intentional-sampling/late/queue-drop totals,
audits, ablations and cleanup evidence, and are mirrored in the lab.

The subsequent **manual RF Live Test** recording completed three minutes on the
iPhone 11 with camera/writer load: 5,400 processed frames at 29.99 fps, 130 app
counts, three capture drops and zero writer/copy/analysis/counter-queue drops.
Emission latency remained 613 ms median / 751 ms maximum; serious thermal state
began at 102.7 s. Selected visual review confirmed at least two missed foot
contacts at 5.2/5.6 s, rejected for missing pose evidence despite tracked ball
observations before heating. The full session is not exhaustively labelled;
130 is not an accuracy label. See the [manual recording review](../../benchmarks/touch-counting/rf-live-camera-review-20261017.json).
The next diagnostic target is pose/foot evidence and decision delay. Production
active-player integration and independent accuracy remain unvalidated.

- [x] Promote the selected, versioned counting policy from Touch Counting Debug into
  the normal app configuration. Keep the debug paywall bypass, diagnostic pages and
  replay tools confined to their debug build; do not enable debug flags in Release.
- [ ] Compare the production candidate against the frozen replay baseline, including
  the long juggling recording, genuine contact cases and ground/hand negatives.
  Record remaining errors rather than treating the benchmark as 100% accuracy.
- [ ] Establish the detection and tracking baseline described above and identify the
  highest-impact missed-ball, far-ball and dropout cases. Broader model improvements
  do not block this counter update unless they are required for reliable sessions.
- [ ] Assemble labelled recordings of one-hand taps near the face/chest, catches,
  throws, ground bounces, genuine chest/head touches and normal foot juggling.
  Include different lighting, camera angles and partial occlusion; hold back some
  recordings for validation rather than tuning against every example.
- [ ] Fix contact decisions using movement before and after the contact. A nearby
  hand alone must not invalidate a genuine chest/head touch.
- [ ] Measure false accepted touches and missed legitimate touches separately.
- [ ] Profile sustained live sessions on physical iPhone 11 and 12 devices, plus a
  newer reference device: processing time, dropped frames, memory and thermal state.
  Use the normal optimized release candidate on supported iOS versions, including
  repeated recordings after the phone has warmed up. Simulator and modern-phone
  replay results do not establish older-device performance.
- [ ] Reduce optional rendering work before sacrificing counting accuracy. When live
  analysis cannot keep up, preserve the recording and finish analysis afterward with
  clear progress and completion feedback.
- [ ] Verify recording, interruption recovery, saved-session replay and export in the
  release candidate, and confirm existing purchases still gate paid features.

**Release gate:** known hand-contact failures improve without regression on valid
touches in held-out recordings. Older devices consistently complete and retain a
usable session, with a clear fallback wherever live counting remains unreliable.
Record device-specific results and remaining limitations before shipping.

## Week 2: Sign-in and a fair leaderboard beta

**Sign-in source update, 18 October:** Google/email entry points and their existing
UI checks are restored. The authentication services were already implemented; pending
email recovery after Google cancellation or failed resend is corrected. Read-only
checks confirm all three providers enabled and the email association valid at the
website and Apple CDN. Syntax checks pass; no project build, Swift test run,
provider-configuration change or upload was performed in this pass. Keep the rollout
checks below open until candidate verification is complete;
see the [account rollout status](../auth-setup.md).

- [ ] Complete outstanding Google/email production setup and recheck provider status
  independently of the counter release.
- [ ] Enable Google/email after production setup and end-to-end verification of new
  sign-in, cancellation, expired links, retries, sign-out and restored sessions.
- [ ] Verify guest history survives sign-in and that account changes do not
  unexpectedly split or overwrite player progress.
- [x] Implement the ranked streak rules below, distinct from total session touches (source).
- [x] Add explicit submission, pending, approved and rejected states with useful
  explanations and a review route.
- [x] Support deliberate submission of original recordings for private review (source).
  Explain who can access the recording and how long it is retained.
- [x] Make approval a trusted backend operation; clients cannot approve their own scores (local SQL verified).
- [ ] Start with a small opt-in beta where every published score has been reviewed.
  Bound participation to the review capacity available.
- [ ] Test that known hand/ground exploit recordings cannot appear as valid streaks,
  retries cannot create duplicate entries, and unapproved submissions remain private.

**Release gate:** authentication works for ordinary users and approved leaderboard
scores are supported by their recordings. If counting or review is not ready, ship
authentication separately and keep the leaderboard beta private.

### Reviewed leaderboard implementation — 18 October

Implemented in source on `codex/post-launch-signin-leaderboard-ball-edges`:
the Stadium lights Home card, trophy shortcut, pennant board and player details,
rules, deliberate submission from replay/history, My submissions, visibility,
appeals and reports. The board calls the reviewed-streak endpoint. The migration
also routes the legacy endpoint to reviewed scores so old clients cannot expose
unreviewed training totals after deployment. Ordinary session counting is unchanged.

**Not deployed or built:** no Xcode build, simulator/device run, install or upload
was performed for this implementation, as requested. The remote backend must be
deployed before this source can load the reviewed board or accept an upload.

The local proposal splits accepted touch timestamps at rejected candidates or a
gap over two seconds, then suggests the longest segment. This is a conservative,
editable starting point for review, not automatic proof of continuity. A reviewer
must watch the original, correct missed/extra contacts and approve one supported
segment. Session totals and device `bestCombo` never become reviewed scores.
Backspin and height icons are present; values remain **Unavailable** until a
validated measurement pipeline supplies them. Duration and average rhythm use
the approved segment. Around the World has no classification, badge or bonus.

Implementation is split across [leaderboard views/services](../../kicklab/Leaderboard/),
the [review migration](../../supabase/migrations/202610180001_reviewed_leaderboard.sql),
[private-video cleanup](../../supabase/functions/cleanup-leaderboard-videos/index.ts)
and the [operator review tool](../../scripts/review-leaderboard.py).
Uploads hash the original on disk and use resumable 6 MiB chunks with account-scoped
checkpoints; publication happens only after the original has arrived and a trusted
reviewer has approved it. The implementation follows the
[Storage resumable-upload protocol](https://supabase.com/docs/guides/storage/uploads/resumable-uploads)
and explicitly requests a [single PostgREST object](https://postgrest.org/en/latest/references/api/resource_representation.html)
for the begin/finalize receipts.

Local validation: the disposable PostgreSQL suite passes (including old API
compatibility, owner isolation, unapproved-score exclusion, immutable evidence,
duplicate approval, UTC periods/ties, reports, appeals, withdrawal, expiration and
deletion). The targeted deletion/retention Edge Function suite and offline reviewer
tool tests pass. Swift syntax parsing passes. Added Swift proposal/API/upload tests
and adjusted the pennant navigation UI test; these await an app test build.

Before beta rollout:

1. Apply the reviewed-leaderboard migration after the existing account migrations.
   Confirm the private bucket and project-wide Storage limit support the 2 GiB
   beta cap; smaller plan limits must be reflected in the app before release.
2. Deploy `delete-account`, `reconcile-account-deletions` and
   `cleanup-leaderboard-videos` together. Configure a dedicated
   `LEADERBOARD_CLEANUP_SECRET` and matching Vault secret, then run
   [the cleanup schedule](../../supabase/ops/schedule-leaderboard-cleanup.sql).
   Keep [deletion recovery](../../supabase/ops/schedule-deletion-recovery.sql) enabled.
   Monitor failures/backlogs; withdrawal promises deletion within 24 hours.
3. Allocate review capacity before opening the board. Each account has at most
   three submission intents per rolling 24 hours and three uploads/pending reviews.
   This limits spam, but is not a global capacity or upload-bandwidth limit.
4. Build and run the Swift tests when authorized, then validate a real upload,
   paused/interrupted upload, app relaunch/resume, sign-out/account switch, approval,
   correction, rejection, report, appeal, visibility change, withdrawal and account
   deletion against a staging project. Check Photos copies remain untouched.
5. Check Home, pennants and forms on a small device, large text and Reduce Motion.
   Use known hand/ground clips and a clean missed-touch clip for human-review checks.

Operator workflow (server credentials in the operator's environment only):

```sh
python3 scripts/review-leaderboard.py queue
python3 scripts/review-leaderboard.py queue --appeals
python3 scripts/review-leaderboard.py download ATTEMPT_UUID --output /private/reviews/attempt.mov
python3 scripts/review-leaderboard.py review ATTEMPT_UUID approve --file /private/reviews/attempt.mov \
  --reviewer REVIEWER_NAME --count 52 --start-ms 1000 --end-ms 49000 \
  --reason '52 continuous contacts; corrected two missed detections.' --confirm-watched
python3 scripts/review-leaderboard.py reports
python3 scripts/review-leaderboard.py resolve-report REPORT_UUID --reason 'Original reviewed; decision explained.'
```

Set `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` using the operator's secret
manager; never put the service key in the app, a command argument or this repository.
Approval requires `ffprobe`, a matching downloaded SHA-256/byte count, a plausible
video duration and a manual-watch attestation. To reject, use `reject` with the
original, reviewer and reason; include `--reason-time-ms` where relevant. A report
resolution alone does not change a score; use a separate review decision.
Delete operator-downloaded copies after review. Server retention cannot remove
files downloaded to an operator's computer.

Pending/rejected originals expire 30 days after submission, the latest decision
or appeal; unfinished uploads expire after seven days. Approved evidence remains
until withdrawal/account deletion. Cleanup claims lock out late approval before
deleting bytes through Storage, and record completion only after deletion succeeds.
SHA-256 detects identical approved originals; it does not detect re-encodes or prove
capture provenance. `source=recording` is client-reported metadata, so manual review
is still required; cryptographic capture attestation and automated fraud detection
are outside this beta.

### Home, entry points and leaderboard design

The owner selected **01 — Stadium lights** from the
[background comparison sheet](../../design/leaderboard-pennants-20261018/leaderboard-background-sheet-v1.png).
The [selected home and rules mockup](../../design/leaderboard-pennants-20261018/home-and-rules-stadium-v4.png)
applies a dark stadium photograph, soft floodlights, white text and lime accents to
the Home leaderboard card. The heavy sewn-fabric and sage/lime pitch-line backgrounds
were rejected. Rules use grouped native surfaces and shorter copy.
The leaderboard itself retains the selected fabric-pennant design. The
[leaderboard and player mockup](../../design/leaderboard-pennants-20261018/leaderboard-and-player-icons-v2.png)
shows the list's spin/height icons. All scores and measurements in these images
are illustrative; review and measurement capabilities must be implemented and validated.

| Location | Entry and destination |
| --- | --- |
| Home | Add the selected Stadium lights leaderboard card with a small pennant accent immediately below the two existing training modes. Use white text over a dark stadium photograph, soft floodlights and lime accents. Add a trophy shortcut beside Profile. Both open the weekly board. Keep training the primary action. |
| Home card | Show your reviewed weekly score/rank and the score needed for the next place. Link to the board and Rules. Keep the existing training personal best separately labelled. |
| Leaderboard header | This week / All time, visible Rules link, period dates and reset time translated into the viewer's time zone. |
| Leaderboard footer | Your place, nearby players, Submit an attempt and My submissions. |
| Replay / session history | Offer Submit to leaderboard for retained original in-app recordings; show the proposed best streak and its start/end, not the full session total. |
| Submission | Show score, original video, rules summary and private-review explanation before deliberate submission. Sign-in is needed to submit; viewing the board need not require it. |
| Profile | My submissions, public profile/visibility controls and removal of a published entry. |
| Attempt details | Reviewed streak, duration, review status and Report / Request re-review. Video playback for other people requires separate publication permission. |

Home card states must be real: no submission → “Your first place starts here”;
pending → “In review” with status link; reviewed → rank and score; unavailable →
retry/saved-state label. Never show a sample rank, turn a training PB into a reviewed
score, or clear a previous approved score while a better attempt waits for review.
Use real leaderboard order for the next-place target, including its tie rule.

Pennants may respond gently to touch; a normal tap must always open the same detail
view. Pull-to-refresh remains a scroll gesture, not a required fabric interaction.
Respect Reduce Motion and provide labelled, accessible controls.

### Leaderboard rules — beta-1

The approved implementation request uses this beta policy in source. Valid contacts
are verified by human review, including clean leg, knee and thigh contacts.
Ordinary training counts are not retroactively changed.

| Topic | Rule |
| --- | --- |
| Score | Longest uninterrupted valid streak, not accumulated session touches. |
| Valid contacts | Feet (including inside and outside), lower legs, knees/thighs, chest and head. One distinct contact earns one point; no extra points for height, speed, spin or difficulty. |
| Hands, arms, ground and outside help | End the current streak. A wall, another player or another supporting object also ends it. Subsequent juggling starts a new streak; do not merely omit the invalid contact and keep adding. |
| Initial hand release | A normal setup release earns no points; the streak begins at the first valid contact. |
| Stalls | A catch or deliberate held/balanced stall ends this continuous-juggling streak and earns no points. Trick/stall scoring is outside this beta. |
| Uncertain contact or tracking gap | A missed model detection is not itself a foul. Review the original video and correct missed/extra touches when the evidence is clear. If continuity cannot be established, publish only a fully supported segment or explain why no score can be approved. Never guess across a gap or label an unseen hand as a confirmed foul. |
| Source | Original, unedited in-app recordings initially. Gallery imports remain available for personal analysis. |
| Framing | One active player and one active ball; keep the player, contact areas, ball and nearby ground visible. A passerby is not automatically a foul. Ambiguous player/ball identity requires review. |
| Equipment | Start the single beta board with one size-5 football, declared at submission and checked where possible in review. Resolve the policy for smaller/youth balls before opening their scores to this board; this restriction is not a training restriction. |
| Older devices | In-app recordings analysed afterward use the same scoring and review rules. Live processing speed does not determine eligibility. |
| Board | One best approved score per account per period, weekly and all-time views, your rank and nearby players. Do not sum attempts. |
| Week / ties | Monday 00:00 UTC resets. Server receipt of a complete submission assigns its week and breaks equal-score ties; review completion time does not change it. A late review retains the original submission week; the app shows the current week and all-time views. Client completion timestamps do not decide rankings. |
| Suspicious results | Review implausible touch rates, unusually high scores and duplicate recordings. A legitimate 1,000-touch run can still qualify. |
| Disputes | Provide reporting and re-review, with a timestamp and specific reason when a streak is shortened or does not qualify. Preserve the submitted estimate and reviewed result separately for an audit trail. |
| Participation | Opt-in; ordinary training remains available without entering the leaderboard. |
| Privacy | Original recordings are private for score review by default. Public video sharing and model-training consent are separate choices. Publish retention/deletion behavior before enabling uploads; account deletion must remove public entries and related retained data according to that policy. |
| Excluded initially | Prizes, paid score advantages, Around the World recognition/badges/bonuses, trick multipliers, multiple divisions and numerous separate boards. Merely attempting a trick adds no points; visible valid contacts still follow the ordinary rule. |

**More useful than trick scores for this beta:** reviewed streak and duration first;
personal improvement and distance to the next place second. Rhythm (touches/minute),
left/right balance, contact mix, estimated backspin and relative ball height can
describe the attempt once validated. They must not affect rank. Use “Unavailable”
for insufficient evidence; do not invent exact RPM or body-part percentages. Inside
and outside foot technique must not depend on a reliable subtype classifier to count.

Before public beta, complete the deployment and device checks above and ensure the
team can review every published score. Submission limits catch some obvious abuse,
but plausible numbers do not prove legitimate contacts. Automatic verification beyond
the reviewed beta requires separate validation; reviewing only top scores would
leave lower positions less protected.

## Week 3: Detection continuity, replay quality, effects and UI

- [ ] Address the highest-impact detection and short-gap tracking failures from the
  baseline; compare held-out results before and after each candidate change.
- [ ] Remove visible original-ball edges during replacement, especially in fast
  movement and partial occlusion; do not hide leakage by indiscriminately enlarging
  the replacement over the player's body.
- [ ] Check replacement shape, size and timing across consecutive frames.
- [ ] Align preview and saved-video ball coverage and placement. Verify both paths.
- [ ] Fix essential fire/rainbow performance problems using profiling. Broader resource
  reuse, lighter quality options and visual enhancements follow if the detection work
  leaves capacity.
- [ ] Set performance targets using Week 1's baseline and record before/after results.
  Improved rendering must not worsen counting accuracy or session completion.
- [ ] Fix loading feedback, cancellation, retries, back navigation, save confirmation
  and interrupted flows. Polish transitions after the functional issues.

**Release gate:** visible-ball tracking improves without unsupported gap filling;
representative clips show cleaner ball coverage in preview and export, effects stay
within the measured device budgets, and saving still succeeds.
Additional effects are optional only after these checks pass.

## Week 4: Shot camera and measurement validation

- [ ] Prioritize far-ball detection/recovery on the supported shot setup. Validate
  visible small-ball recall and false positives before extending measurement range.
- [ ] Improve camera placement guidance, framing, ball visibility, setup readiness
  and tracking-loss feedback.
- [ ] Define each result precisely: distance from the starting point, total distance
  travelled, average speed and peak speed are different quantities.
- [ ] Start with a narrow supported capture setup. The existing experimental
  ground-ball geometry and speed estimator do not establish accurate airborne-shot
  measurement; document the supported surface, camera setup and motion range.
- [ ] Compare against measured distances and independent timing/reference measurements.
  Define the acceptable error before the final evaluation and record the observed range.
- [ ] Withhold measurements when calibration, visibility or tracking is insufficient.
- [ ] Release a limited measurement beta only if its accuracy is supported; otherwise
  keep measurement experimental and ship the completed camera improvements.

**Release gate:** camera guidance works on the target devices. Any released speed or
distance result has an explicit definition, supported conditions and measured accuracy.

## Around the World: deferred beyond this beta

The trick is **Around the World (ATW)**: the foot circles the airborne ball before
the player continues juggling. See the [Online Soccer Academy demonstration](https://www.onlinesocceracademy.com/soccer-training-videos/tricks-skills/how-to-do-around-the-world-john-farnworth).

A constrained replay prototype is medium–hard. Reliable live recognition across
camera angles and older devices is hard: it must follow the foot around the ball,
handle occlusion and confirm a successful continuation.

The owner's 18 October direction removes this from the current game scope. Do not
add an ATW entry, recognition claim, badge, difficulty tier or scoring bonus to this
beta. Keep any later feasibility work separate from ranked scoring until independently
validated. There is no active ATW implementation allocation in this release.

## Delivery rules and follow-up

- Ship completed improvements early; do not wait for the end of four weeks.
- Review actual failure rates, device results and user feedback after each update.
  Existing opt-in analytics can track session, import, sign-in and export outcomes;
  those events do not establish counting accuracy and do not represent every user.
- If ahead of schedule, improve beta review, submission recovery and accessibility.
- If behind schedule, cut new effects, cosmetic transitions and measurement expansion
  first. Preserve detection/counting accuracy, older-device verification and leaderboard fairness.
- Keep TikTok sign-in, broad automatic anti-cheat, unrestricted airborne measurements
  and production trick recognition in the follow-up backlog.
- Mark checkboxes only after verification. Record each shipped version, evidence and
  any deferred scope in this document as implementation progresses.

## Existing implementation references

These describe the checkout inspected on 2026-10-11, not newly verified production status.

- [Account rollout and provider setup](../auth-setup.md): Google/email flows exist;
  their production readiness must be rechecked before enabling the hidden controls.
- [Sign-in controls](../../kicklab/Account/SignInView.swift): launch exposes Apple and guest.
- [Contact rules](../../kicklab/Counting/JugglingContactRules.swift): existing practice
  counting accepts broader body contacts; the ranked feet/head/chest rule needs its own validation.
- [Current leaderboard schema](../../supabase/migrations/202610090001_profiles_and_juggling.sql)
  and [submission limits](../../supabase/migrations/202610100001_submission_limits.sql).
- [Device performance instrumentation](../../kicklab/Detection/DetectorPerformance.swift).
- [Experimental ground-ball geometry](../../kicklab/Detection/ShotRollDistance.swift).
- [Existing product analytics and consent](../product-analytics.md).

This roadmap documents future work only. It does not enable features, change scoring,
change analytics collection or alter the release configuration.
