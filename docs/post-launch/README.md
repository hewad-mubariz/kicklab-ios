# Four-week post-launch plan

Documented: 2026-10-11. Release priorities updated: 2026-10-12.
Status: planned; no implementation is completed by this document.
Week 1 starts after the first public release, rather than on the documentation date.

The first month's priorities are trustworthy counting, better ball detection and
tracking, dependable sessions on older devices, and a fair leaderboard. Replay quality
and shot-camera improvements follow.
The first post-launch update is limited to the improved counter and older-device
session reliability. Leaderboard submissions and voluntary video sharing follow in
a separate release. Google/email rollout must not delay the counter update. TikTok
sign-in, additional effects and production trick recognition can follow later.

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
| 11 | 7 | Around the World recognition | Later | High | Optional feasibility prototype; no production commitment this month. |
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

- [ ] Complete outstanding Google/email production setup and recheck provider status
  independently of the counter release.
- [ ] Enable Google/email after production setup and end-to-end verification of new
  sign-in, cancellation, expired links, retries, sign-out and restored sessions.
- [ ] Verify guest history survives sign-in and that account changes do not
  unexpectedly split or overwrite player progress.
- [ ] Implement the ranked streak rules below, distinct from total session touches.
- [ ] Add explicit submission, pending, approved and rejected states with useful
  explanations and a review route.
- [ ] Support deliberate submission of original recordings for private review.
  Explain who can access the recording and how long it is retained.
- [ ] Make approval a trusted backend operation; clients cannot approve their own scores.
- [ ] Start with a small opt-in beta where every published score has been reviewed.
  Bound participation to the review capacity available.
- [ ] Test that known hand/ground exploit recordings cannot appear as valid streaks,
  retries cannot create duplicate entries, and unapproved submissions remain private.

**Release gate:** authentication works for ordinary users and approved leaderboard
scores are supported by their recordings. If counting or review is not ready, ship
authentication separately and keep the leaderboard beta private.

### Initial leaderboard rules

| Topic | Rule |
| --- | --- |
| Score | Longest uninterrupted valid streak, not accumulated session touches. |
| Valid contacts | Feet, head and chest. Thighs/knees are excluded unless the ranked rules are deliberately expanded. |
| Hands, arms and ground | End the current streak. Subsequent juggling starts a new streak; do not merely omit the invalid contact and keep adding. |
| Initial hand release | A normal setup release earns no points; the streak begins at the first valid contact. |
| Uncertain contact or tracking gap | Keep the attempt pending review. Never silently bridge uncertainty into a verified streak. |
| Source | Original, unedited in-app recordings initially. Gallery imports remain available for personal analysis. |
| Older devices | In-app recordings analysed afterward use the same scoring and review rules. Live processing speed does not determine eligibility. |
| Board | One best approved score per account, a weekly board, your rank, nearby players and a personal best. |
| Week / ties | Retain the existing Monday 00:00 UTC boundary and earlier-result tie break, and explain them in the rules. |
| Suspicious results | Review implausible touch rates, unusually high scores and duplicate recordings. A legitimate 1,000-touch run can still qualify. |
| Disputes | Provide reporting and re-review, with a clear reason when an attempt does not qualify. |
| Participation | Opt-in; ordinary training remains available without entering the leaderboard. |
| Excluded initially | Prizes, paid score advantages, trick multipliers, multiple divisions and numerous separate boards. |

The current backend calls scores device-reported. Submission limits catch some
obvious abuse, but plausible numbers do not prove legitimate contacts. Automatic
verification beyond the reviewed beta requires separate validation; reviewing only
top scores would leave lower positions less protected.

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

## Around the World: optional investigation

The trick is **Around the World (ATW)**: the foot circles the airborne ball before
the player continues juggling. See the [Online Soccer Academy demonstration](https://www.onlinesocceracademy.com/soccer-training-videos/tricks-skills/how-to-do-around-the-world-john-farnworth).

A constrained replay prototype is medium–hard. Reliable live recognition across
camera angles and older devices is hard: it must follow the foot around the ball,
handle occlusion and confirm a successful continuation.

If the committed work finishes early, spend at most 1–2 days on a feasibility
experiment using one camera angle, one variation and analysis after recording.
This is an investigation budget, not a production-delivery estimate. Keep any trick
recognition separate from ranked scoring until independently validated.

## Delivery rules and follow-up

- Ship completed improvements early; do not wait for the end of four weeks.
- Review actual failure rates, device results and user feedback after each update.
  Existing opt-in analytics can track session, import, sign-in and export outcomes;
  those events do not establish counting accuracy and do not represent every user.
- If ahead of schedule, pull forward one lightweight effect or the ATW experiment.
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
