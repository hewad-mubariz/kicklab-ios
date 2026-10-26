# Four-week post-launch plan

Documented: 2026-10-11. Product priorities updated: 2026-10-19.
Status: in progress; implementation and verification status must be read separately.
Week 1 starts after the first public release, rather than on the documentation date.

**Leaderboard scope, updated 26 October:** the first beta uses automatic best
continuous streaks only. Touch checks, uploads and human review are postponed.
The [current beta rules and testing checklist](#leaderboard-rules--automatic-beta)
supersede the reviewed-leaderboard rollout requirements recorded below.

The first month's priorities are trustworthy counting, better ball detection and
tracking, dependable sessions on older devices, and a fair leaderboard. Ball
replacement quality in recordings made inside the app is the current highest
priority (owner update, 19 October). Leaderboard work is deferred until this core
feature is ready; additional effects and shot-camera enhancements follow.
The first post-launch update is limited to the improved counter and older-device
session reliability. Leaderboard submissions and voluntary video sharing follow in
a separate release. Google/email rollout must not delay the counter update. TikTok
sign-in, additional effects and production trick recognition can follow later.

## Next three product targets — 18 October 2026

The owner selected these three targets on 18 October. On 19 October the owner
moved ball replacement ahead of the remaining leaderboard work. This update
supersedes the ordering below; the current candidate's release checks continue.

1. **Google and email sign-in.** Enable the existing flows after verifying provider
   readiness, cancellation/retry, expired links, restored sessions and preservation
   of guest history and account/subscription access. The controls are enabled in
   source as of 18 October. **22 October update:** Google is removed from the
   welcome/Profile choices until a branded Supabase auth domain is configured;
   Apple, email and guest remain available. Existing guest history stays in its
   separate local library.
   The [account setup notes](../auth-setup.md) record completed Google branding and
   SES production setup; email sending limits and delivery monitoring still need
   an explicit rollout decision.
2. **Automatic leaderboard beta (scope updated 24 October).** Rank each player's
   best device-counted continuous streak from signed-in, in-app recordings. Keep
   joining optional. Submissions, video uploads and reviewed corrections are deferred;
   their earlier implementation and deployment notes are retained below as history.
3. **Ball replacement — current highest priority (updated 19 October).**
   Treat this as a core-feature quality milestone. Prioritize recordings made inside
   Juggle Dude: recover missing ball regions, preserve hands/feet, remove original-ball
   fringes and stabilize the replacement across replay and saved exports, with
   acceptable preparation cost on older phones. Imported outdoor 4K/120 fps footage
   is a comparison and regression control, not the acceptance target. Keep appearance
   repairs separate from touch evidence and preserve existing counts. New cosmetic
   effects, trick recognition and shot-camera enhancements must not displace this work.

### Current ball replacement implementation — 19 October

The current branch now contains a local candidate; it has not been uploaded or
approved for release. [Validation evidence](../../benchmarks/rf-ball-replacement/20261019-consensus-integration/report.json)
tracks checks and limitations separately from implementation.

- Retain the established modest-addition crop repair. Require agreement between
  current-frame crop contexts for larger repairs, removing false hand ownership,
  and temporal fragment nominations. Cap actual extra model calls at 240 and
  reserve enough calls for each remaining planned frame, including both required
  contexts for mandatory agreement.
- Detect fragments even when the detector box shrinks alongside the mask. Nearby
  original observations only select a retry; current pixels determine the repair.
- Preserve decoder sampling through mask fusion, compression and disk caches.
  Regridding must not silently change the renderer's estimate of edge dilation.
- Reject image-edge fits that abandon supported ball interiors. Real in-app
  panel/finger examples are included in regression fixtures at multiple scales.
- Reconstruct soft-edge background contribution only where neighboring current-frame
  samples agree. Textured/uncertain backgrounds and foreground cutouts keep the
  source-over fallback. Replay, still previews and export use the same service.

The counter and live capture pipeline are unchanged. These changes improve the
replacement in replay/export of footage recorded inside the app. Long blur streaks,
full silhouette accuracy and phone performance still require qualification; this
is not a claim of complete matting or release readiness.

20 October memory follow-up: fixed an RF input-buffer ownership leak when mask
repair changes crop dimensions. `CVPixelBufferCreate` now writes into a fresh local
reference before assigning the owned buffer. On the latest 22.94-second phone
recording, isolated crop-repair peak fell from 315 to 126 MiB and settled replay
from 279 to 80 MiB. All 939 frame/mask records and 1,373 spin entries remained
identical; the original 16 touches and markers were preserved. Eleven RF bridge
tests pass, including a weak-reference check that resized buffers are released.
These isolated measurements do not reproduce the full app session's reported
600 MB peak; long-session/older-device qualification remains open.
[Memory evidence](../../benchmarks/rf-ball-replacement/20261020-preparation-memory/report.json)

20 October visual follow-up: replacement quality on in-app footage remains open.
The latest original and saved export both contain 1,373 frames with identical
timestamps. Reviewed contacts retain old-ball fringes and render a sharper,
rounder replacement than the photographed ball. Close-up model inference alone
did not resolve this. A trial retaining more mask interior made little visible
improvement and failed an outdoor contour regression; it was removed. The
current renderer and camera settings remain unchanged.

Debug capture reports now include periodic shutter duration, ISO and exposure
target offset, so the next short Final tests recording can establish actual
capture conditions. These readings are diagnostic, not frame-exact exposure
metadata and not rendering inputs. The next visual work needs source-consistent
blur and soft-edge source removal, with foreground/older sharp-video controls.
[Visual investigation and examples](../../benchmarks/rf-ball-replacement/20261020-live-quality/report.json)

20 October edge candidate, verified on the next 25.99-second in-app recording:
the existing source-spin preparation now estimates photographic blur from
consistent opposite-side image edges. When supported, replacement coverage keeps
that soft opacity instead of making it opaque again from semantic ball ownership.
Foreground hand/foot cuts remain applied. Ambiguous evidence retains the existing
estimate; the earlier 22.94-second clip abstains and is not improved by this change.
This is a partial visual improvement, not a complete solution to original-ball
fringes or trail-ring alignment.

The local iPhone 17 Pro Max export completed in 27.06 seconds, peaking at 127.89 MiB
in the isolated owned-track harness (mask preparation and the warm regular UI were
not measured). All 1,556 source/export timestamps and prior source-spin entries
match. The sharp outdoor 4K/120 fps control abstains; all 77 comparison PNGs are
byte-identical. The final focused simulator suite passed 25 tests. Normal debug
recordings now also save periodic optics readings to `Documents/CaptureDiagnostics`,
without requiring Final tests or changing camera exposure settings. Build 26 was
installed locally; there was no upload.
[Candidate evidence and limits](../../benchmarks/rf-ball-replacement/20261020-edge-fix/report.json)

### Ball replacement implementation sequence

1. **Evidence-based mask recovery.** Compare current image edges and nearby original
   observations to detect incomplete masks, including fragments whose detection box
   has also shrunk. Test agreement between different current-frame crop contexts
   before accepting added or removed coverage. A high detection score or agreement
   between model calls is supporting evidence, not proof that an outline is correct.
   Prioritize suspicious frames within an inference-call budget; do not run several
   retries on every frame. Preserve the original counter observations.
   Compare a tracked-crop-first appearance pass against the current full-frame pass
   plus retries. It must use sparse original capture observations and reacquire when
   tracking is uncertain; a study guided by dense full-frame inference cannot prove
   the proposed cost saving. Keep this separate from live counting.
2. **Visibility and blur compositing.** Keep the physical ball outline, visible
   surface and motion-blurred edge opacity distinct. Preserve fingers and feet in
   front. Removing the photographed ball's colour from a blurred boundary also
   requires a trustworthy estimate of the underlying scene; a soft overlay alone
   cannot do this. Prototype a bounded local/temporal reconstruction and verify it
   against known-background controls before allowing it near moving limbs. Retain
   source pixels when the evidence is insufficient.
3. **Temporal consistency and shared geometry.** Stabilize uncertain size/shape
   changes using nearby evidence while preserving real contact reversals and scale
   changes. Replay, export and attached effects should use the same appearance
   geometry and visibility. Verify source-spin independently of mask coverage.
4. **Capture quality and release qualification.** Measure exposure/ISO/focus alongside
   delivered/written frames, inference cost, memory and thermal state. Compare app
   720p60, a diagnostic 1080p60 capture and a native-camera reference under matching
   light/framing before changing defaults. Judge the result on fresh in-app recordings
   and older-device performance, plus the existing hand/foot/distant-ball controls.

The 19 October research direction is a bounded refinement of the existing pipeline,
not a commitment to a new model or an unconditional increase in capture quality.
RF-DETR provides [instance segmentation](https://rfdetr.roboflow.com/latest/learn/run/segmentation/);
recovering edge opacity and foreground/background colour is a separate compositing
problem. [Background Matting V2](https://arxiv.org/abs/2012.07810) illustrates the need
for background evidence, but its person-matting implementation is not being adopted
or treated as an on-device football solution.

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
- **19 October fresh recording audit:** the local branch build **1.0.0 (26)** on
  iPhone 17 Pro Max produced an 18.625-second, 720 × 1280 recording and export.
  Both contain 1,113 frames with identical timestamp sequences. All 516 frames
  in the 5.7–14.3-second juggling interval have a stored mask; mask availability
  does not establish outline accuracy. White/blue original-ball edges remain at
  fast contacts around 6.25, 7.95, 9.55 and 10.85 seconds. A held-ball hand boundary
  is also imperfect around 4.80 seconds. Current Swift appearance functions were
  inspected on 79 extracted frames, with replacement-only Pearl/Gold/Stealth
  comparisons on five frames; these Mac diagnostics are not a new device export
  or a pixel-parity claim. The saved iPhone export remains the visual baseline.
  Evidence and the reproducible audit are under
  `artifacts/ball-replacement-review/20261019-latest/review-summary.json`.
  The causes to separate are RF-mask undercoverage, circular reconstruction of
  blurred contacts, shallow occlusion boundaries, and per-frame geometry changes.
  Glow Trail additionally draws a separate ring from the detector radius rather
  than the refined material outline, which can exaggerate the apparent mismatch.
  Prioritize a replacement-only baseline, exposure/visibility coverage separate
  from texture geometry, then coordinated effects and temporal consistency. Do
  not use a global size increase or alter counting to address appearance. This
  audit changed no production code and installed no further build.
- **19 October deeper in-app recording investigation:** [report and reproduction
  commands](../../benchmarks/rf-ball-replacement/20261019-live-capture-audit/report.json),
  [source/current/crop comparison](../../benchmarks/rf-ball-replacement/20261019-live-capture-audit/live-recording-evidence.jpg)
  and [compositing control](../../benchmarks/rf-ball-replacement/20261019-live-capture-audit/compositing-evidence.jpg).
  The primary failures are recordings made inside Juggle Dude. The imported
  outdoor 4K/120 fps clip is a reference, not a substitute for capture acceptance.
  Native AVFoundation geometry audits covered 6,827 frames across three videos;
  selected frames were inspected visually, not exhaustively labelled.
  Fresh inference on the latest saved in-app video reproduces the incomplete
  lower-ball mask at 6.018 seconds. A diagnostic crop recovers it, but the current
  45% maximum area-growth rule rejects the 62% recovery. Nearby fragments can
  escape retry because their detection boxes shrink too. A separate held-ball
  crop preserves a thumb pixel that is currently painted over, yet fails the
  minimum-growth rule. Fifteen sparse ball/person/background witnesses pass in
  the experimental crops versus twelve in the baseline; this is not broad
  regression acceptance or a deployable unconditional-crop policy.
  A synthetic exact-matte control through the production renderer also confirms
  old-ball colour remains at partially transparent edges when replacement is
  drawn over the original image. Mask recovery and edge compositing therefore
  need separate fixes. Prioritize quality-aware crop selection/acceptance and
  explicit visibility handling, then source-colour removal and stable shared
  material/effect geometry. Capture currently prefers 720p60; measured exposure,
  ISO and focus are not retained, so matched capture tests must precede changes
  to recording defaults. This investigation changed no production logic, touch
  rules or app build. The reproducible harness and evidence are local files;
  no commit, push, new device installation or release qualification is implied.
- **19 October recovery-design follow-up:** [experiment and next decisions](../../benchmarks/rf-ball-replacement/20261019-recovery-design/report.json).
  An isolated prototype queries different crop contexts from the same source frame
  and changes a pixel's ball membership only when two geometrically consistent masks
  agree on the direction of that change. On 91 selected frames of the latest in-app
  recording it retains 73 proposals, passes all 15 sparse labelled points (baseline:
  12), and removes three large radius jumps in the 5.9–6.1-second failure sequence.
  An earlier in-app recording supplies 22 inspected frames and 12 additional labelled
  control points; those controls remain correct. This does not establish full-outline
  accuracy or prove that two model calls cannot share the same mistake.
  Adaptive stopping reduces the latest experiment from 273 to 203 model calls while
  retaining the 15 passing points. This is a call-count result, not an iPhone speed or
  thermal measurement; production scheduling and its global call budget are not yet
  implemented. Blur fringes remain. Before integration, resolve retry prioritization,
  shared model errors, and the way resampled masks preserve physical sampling/feather
  information. The experiment and roadmap are saved locally; app behavior is unchanged.
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

### Flagged-moment review — 22 October

The owner returned focus to leaderboard fairness after deferring Google sign-in.
This dated update supersedes the proposal-splitting and build status in the original
18 October implementation notes below.

- New in-app recordings retain compact production contact observations separately
  from the bounded debug trace. No new inference, frame copies or clip exports are
  added. The buffer is bounded at 4,096 observations; the saved review at 2,000
  grouped moments. Reaching either limit is shown as incomplete evidence.
- Only positive hand/hold detections and corroborated ground-contact detections
  split the suggested streak. Low contacts without corroborating ground evidence,
  uncertain hands/body/player visibility and missing ball tracking are review
  flags. Cooldown, tiny-motion and weak-impulse candidates are omitted as routine
  counter noise. A gap over two seconds is flagged, not treated as proof of a drop.
  These are provisional proposals; all published beta scores still need human review.
  The actual counter acceptance rules and personal training totals are unchanged.
- Replay has a quiet leaderboard review card. The submission screen lists grouped
  timestamps and plain-language reasons. Each moment plays the existing original
  from one second before to 1.2 seconds after the incident (clamped to the video),
  with a separate full-recording player. No per-moment media files are produced.
- “Still doesn’t look right?” leads to deliberate full-original submission. The
  consent text includes flagged timestamps/reasons. A corrected score can change
  rank only after approval; the UI promises no higher rank. My submissions and the
  leaderboard’s latest-submission card expose the review summary/status.
- Local history retains flags through server refresh and app restart. Older
  recordings without evidence say so and can still be reviewed from the original.
  Stopping recording never queues an original or flags for review automatically.
- [The additional migration](../../supabase/migrations/202610220001_leaderboard_touch_review.sql)
  stores validated, bounded JSON on the existing owner-private attempt. It leaves
  approval permissions unchanged, supports old clients, and prevents replacing
  evidence after submission. Reviewers can inspect it with
  `python3 scripts/review-leaderboard.py moments ATTEMPT_UUID`.

Local validation: 52 focused Swift unit tests pass, covering evidence classification,
trace-limit independence, grouping, proposals, persistence, uploads and account isolation.
The disposable PostgreSQL suite passes, including private evidence,
malformed/out-of-range payload rejection, immutable retry behavior and no automatic
ranking. The simulator UI check passes for moment selection, reason text, clip playback
and full-original navigation. The debug UI fixture uses **example flags**, not a
new analysis verdict for its supplied video. Evidence lives in
`artifacts/leaderboard-moments/20261022/`.

**Deployment update — 22 October:** Following the owner's deployment request,
the reviewed-leaderboard and touch-review migrations are now live on
`shbdsjvpjdtqbiaevrxy`. The hosting-limit migration also caps intents and the private
bucket at 50 MiB, matching the existing Free project's actual global Storage limit.
The app validates the same limit and explains it before submission. No paid plan
was enabled. Longer original recordings require a higher hosting limit or a
separate storage integration; the owner raised AWS S3 as an option during deployment.

`delete-account`, `reconcile-account-deletions` and `cleanup-leaderboard-videos`
were deployed together. Cleanup has a dedicated matching Function/Vault secret;
both retention and deletion-recovery schedules are active every ten minutes.
Live checks confirm an empty reviewed board, a private bucket, row security,
no anonymous submissions and no client approval permission. All three privileged
function endpoints reject anonymous calls; a scoped cleanup run completed with
zero failures (no videos were due). The full local SQL suite, including the exact
50 MiB boundary and failed-intent rollback, and 21 function tests pass.

**Live upload check — 22 October:** A 9.6 MB synthetic video uploaded through the
same resumable endpoint and 6 MiB chunk sizes as the app. A fresh HEAD request
confirmed the server offset before each chunk, and a signed download matched the
original SHA-256. A second temporary account could neither read the attempt nor
open the video. Finalization retained the flags and entered pending review; the
public board excluded it, and client approval was denied. Withdrawal succeeded.
Deleting the temporary owner through the deployed app endpoint removed its
submission, video bytes and Auth account. Both temporary accounts and all fixture
files were removed; no test score was approved or published.

**Still to validate:** a fresh physical-device recording, app relaunch/network-loss
upload recovery, reviewer approval/correction and scheduled withdrawal retention
with actual user footage. The synthetic check does not prove counter accuracy or
replace the user's phone walkthrough. Artifacts,
source hashes and the prior leaderboard/function definitions are retained under
`artifacts/leaderboard-moments/20261022/`. No App Store upload or review submission
was made. AWS credits have not been checked and S3 has not been configured.

**Hosting decision — 22 October:** The owner chose to remain on Supabase Free
while demand is unknown. Keep the 50 MiB per-original limit and existing storage
quota for the beta; evaluate a plan upgrade or a separate video store later using
actual storage and download usage. No paid plan, AWS storage or new provider is
authorized by this decision. Scores and review evidence stay separate from video
storage so a future storage change need not replace the ranking model.

### Reviewed leaderboard implementation — 18 October

Implemented in source on `codex/post-launch-signin-leaderboard-ball-edges`:
the Stadium lights Home card, trophy shortcut, pennant board and player details,
rules, deliberate submission from replay/history, My submissions, visibility,
appeals and reports. The board calls the reviewed-streak endpoint. The migration
also routes the legacy endpoint to reviewed scores so old clients cannot expose
unreviewed training totals after deployment. Ordinary session counting is unchanged.

**At the 18 October checkpoint, not deployed or built:** no Xcode build, simulator/device run, install or upload
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

**Pennant polish — 21 October:** The board read as too plain. A podium of blocks was
tried and rejected; the pennants stay, polished. They are lime, silver and bronze felt
with a woven trim and stitching, hang from wooden rods with brass ends, and carry the
Juggle Dude ball as a charm at the tip. On the screen's first reveal they drop open
from their rods one after another and swing, the charms trailing a beat behind; the
winner's floodlight flickers on, one confetti burst plays and scores count up. Tab
changes and refreshes never replay the entrance; a changed pennant flaps in place.
Missing places hang as dashed outlines. Each row shows its streak as a track against
the leader's, with the ball rolling out when the row appears; your row flags the next
player to pass. While your row is off screen, a You pill scrolls back to it. Under
Reduce Motion everything appears in place without movement or count-up.

**Local design preview — 21 October, made launch-only 22 October:** Every build,
Debug included, shows live rankings. For design review, launch with
`--leaderboard-preview mixed` (or `first`, `podium`, `nearby`, `unranked`, `single`,
`empty`) to see a fictional board for that launch only; nothing is saved, and a
choice saved by older builds is cleared at launch. The in-app Preview menu was
removed. Weekly and all-time boards have different scores; player details exercise
country, duration, rhythm, backspin and height, including missing values. These
fictional records exist only in memory, carry preview labels, cannot be reported or
submitted, and are excluded from Release.

**Offline submissions — 22 October:** Submitting no longer needs a connection or a
synced session. A confirmed submission is saved on the phone (per account, beside its
replays) and sends itself once its session has synced and the phone is online; it is
retried when the connection returns, when the app opens and after a growing pause.
An interrupted upload resumes from its checkpoint. A refusal (daily limit, changed
original, missing original) removes it and shows the reason. Pausing an upload takes
it out of the queue until Resume upload. Session results already worked this way.

**Moment clips instead of the whole recording — 22 October:** Until full originals move
to separate storage, a submission uploads one short video: each flagged moment's
window (one second before to 1.2 seconds after), cut without re-encoding and joined in
recording order, with overlapping windows merged. With no flags, the streak's first and
last seconds are sent. Clips over the 50 MB storage limit are trimmed to the moments that
matter most (inside the proposed streak, then streak splits) and the submitted moment
list is marked incomplete. The clip file is kept beside the session until it is sent, so
a resumed upload matches the attempt's hash. `scripts/review-leaderboard.py moments <id>`
maps each clip back to recording time; give the reviewed streak in recording time.
To test from zero, `scripts/wipe-juggling-records.py` removes one account's sessions,
submissions and uploaded clips (dry run first, `--confirm` to delete).

### Automatic streak leaderboard — 22 October

This section records the original automatic-plus-corrections implementation. The
24/26 October beta decisions below supersede its touch-check and correction behavior.

This replaces reviewed-only ranking. Every session recorded in the app while signed in
ranks by its best continuous streak as the device counted it, as soon as it syncs;
nothing is submitted. A hand, hold or ground call ends a streak and touches after it
start a new one. Touches the counter was unsure of are left out without ending the
streak. The session total never ranks: 30 touches with 3 unsure, a hand stop, then 20
more scores 27.

- **Server:** `202610230001_streak_leaderboard.sql` adds the streak to
  `juggling_sessions`, `submit_juggling_session_with_streak` (immutable, like the
  session) and a new `reviewed_juggling_leaderboard` that ranks each player's best
  session by an approved correction's count, else the device streak. A rejected or
  withdrawn correction leaves the device streak. The week follows the session's
  completion time. Results from older builds have no streak and do not rank. Deploy it
  before installing this build: until then, results wait in the outbox (404, retried).
- **Visibility:** the leaderboard asks once (Join / Not now). Profile can change it later.
- **Touch checks:** a streak starts at the first counted touch (a hand release before it
  never counts) and ends at a hand, hold or ground call; those calls are final and are
  never offered for a check. The leaderboard shows the last session's best streak and
  the unsure touches inside it (Looks right / Check touches). The player picks the ones
  they think were valid; the app shows the streak they would make and uploads clips of
  only those moments. While a check is open, the player's row keeps the device streak
  and says how many touches are in review. Approving with `scripts/review-leaderboard.py review <id> approve`
  confirms the count asked for by default; pass a lower `--count` to confirm only some.
- **Not yet built:** full-recording review (planned on AWS) and reporting an automatic
  score; the report button exists only for scores that went through a check. Automatic
  streaks are device-reported, not verified.

**First beta scope — 24 October:** the beta ranks the automatic count only.
`LeaderboardRules.touchChecks` is off: no touch checks, clip uploads, video review or
full-recording upload, and the review service isn't connected, so nothing is fetched
or sent (including a check queued by an earlier build). The rules page, leaderboard,
Profile, history and post-session strip show no review or upload wording. Turning the
switch on restores app entry points; restoring reviewed ranking also requires an
explicit server migration. The server functions and bucket stay deployed
but unused. To take a score off the board, `scripts/remove-leaderboard-score.py`
lists the sessions that rank and marks one `rejected` (dry run first, `--confirm` to
apply, `restore` to undo; every change goes to a private log in `config/local`).

`supabase/tests/streak_leaderboard.sql` covers ranking, immutability, corrections,
periods, moderation and visibility (`scripts/test-account-backend.sh`).

**Automatic-only consistency — 26 October:**
`202610260001_automatic_leaderboard_beta.sql` removes approved-review overrides
from ranking, including the winning session and duration. The existing RPC name,
permissions and response shape are kept for installed clients; `attempt_id` is
always null. Review records/functions are retained, and no sessions are deleted.
The app also suppresses review badges, accessibility claims and reporting when
touch checks are off, even if an older server response still contains an attempt ID.
The UI cannot undo an old server's score override. The migration was deployed to
the Juggle Dude Supabase project on 26 October and its function body was compared
with the local migration. Both endpoints agree; before/after checksums confirm all
11 stored sessions and existing access grants are unchanged (no review records
were present). No fictional scores were added. The full disposable backend suite passes, including a new
regression suite proving that approved counts above or below the device count do
not affect ranking. **Simulator verification passed:** 21 account/cache/streak unit
tests and all 6 leaderboard UI tests. The UI suite caught a preview-only pending
review label; its guard was fixed and all 6 UI tests then passed on a fresh build.
Evidence is under `artifacts/leaderboard-beta-20261026/`; private deployment snapshots
and the previous function are in `config/local/automatic-leaderboard-beta-20261026/`.
At that stage no phone build or TestFlight upload was made. The subsequent
interrupted-run fix below was installed locally on the iPhone 17 Pro Max; the
fresh-recording/sync walkthrough and TestFlight upload are still pending.

**Interrupted-run fix — 26 October:** the saved 29-second test contained 14
accepted touches in runs of 5, 4, 2 and 3, but only the setup hand release was
stored as a definite interruption. Early floor rejections were uncertain and
holds between contact candidates were not inspected. `StreakHoldVerifier` now
checks the existing image/pose cache at most four times per second during an open
run, stopping after a positive boundary until the next accepted touch. It requires
a sustained two-wrist grip; missing hands do not become fouls. Early floor
rejections can supply a boundary only with the existing positive ground proofs.
This evidence never feeds back into touch acceptance. Initial hand releases and
finishing catches do not invalidate a completed run. No timeout-only reset was added.

Physical-device regression passed: with the original accepted contacts frozen,
real-pixel interruption detection gives **14 total / 5 best**, and the clean clip
gives **6 / 6**. A separate full pixel replay with checks disabled/enabled preserves
every counter decision and touch: the interrupted clip is 12 in both arms (the
encoded replay independently loses two contacts accepted live), and the clean
clip is 6 in both arms. Peak retained frames are unchanged (18 and 16). The new
checks add 65 and 3 pose requests respectively; the short replay timing difference
is about 0.30 s and 0.04 s. This is not a long-session thermal benchmark.
The unit tests also cover 10+50+30 => 90 total / 50 best, setup/final hand contacts,
uncertain wrists, the probe budget and positive versus uncertain floor evidence.
Private recordings/results are under `artifacts/leaderboard-streak-audit-20261026/`.
New results identify this behavior as `juggling-v1-streak-v2`; previously synced
scores, including the faulty 14, are not silently recalculated or overwritten.

### Leaderboard rules — automatic beta

The beta publishes device-counted streaks, not independently verified scores.
These rules describe intended play; automatic detection cannot guarantee every
invalid contact is caught. There are no score submissions or human touch checks
in this release, and ordinary training counting is unchanged by this cleanup.

| Topic | Rule |
| --- | --- |
| Score | Best continuous streak counted by the device, not accumulated session touches. Old approved reviews do not alter the beta score or duration. |
| Valid contacts | Feet (including inside and outside), lower legs, knees/thighs, chest and head. One distinct contact earns one point; no extra points for height, speed, spin or difficulty. |
| Hands, arms, ground and outside help | End the current streak. A wall, another player or another supporting object also ends it. Subsequent juggling starts a new streak; do not merely omit the invalid contact and keep adding. |
| Initial hand release | A normal setup release earns no points; the streak begins at the first valid contact. |
| Stalls | A catch or deliberate held/balanced stall ends this continuous-juggling streak and earns no points. Trick/stall scoring is outside this beta. |
| Uncertain contact or tracking gap | An unsure touch is omitted without ending the streak; a tracking gap alone does not end it either. There is no review/correction request in this beta. Never label an unseen hand as a confirmed foul. |
| Source | Sessions recorded in the app while signed in, with saved streak metadata. Gallery imports, guest sessions and old results without streak metadata do not rank. |
| Framing | One active player and one active ball; keep the player, contact areas, ball and nearby ground visible. A passerby is not automatically a foul. |
| Equipment | Ask players to use one size-5 football. The beta does not verify equipment or provide separate ball-size divisions. |
| Older devices | The same streak rules apply. A lower live processing rate is not itself a disqualification. |
| Board | One best streak per account per period, weekly and all-time views, your rank and nearby players. Do not sum sessions. |
| Week / ties | Monday 00:00 UTC resets. Completion time assigns the week and breaks equal-score ties; user ID is the final deterministic tie-breaker. |
| Suspicious results | An operator can remove/restore a session's score with `scripts/remove-leaderboard-score.py`; the tool logs the reason locally. This is not automatic fraud verification. |
| Disputes | In-app reports, appeals and corrected touch counts are deferred. Do not advertise them in this beta. |
| Participation | Opt-in, asked once on the leaderboard; ordinary training remains available without entering it. |
| Privacy | Videos stay on the phone; session metadata syncs to the account. Public entries show opted-in profile information and the ranked streak. Hiding/deleting an account removes it from ranking. Retained legacy review data still follows the deployed deletion/retention cleanup. |
| Excluded initially | Prizes, paid score advantages, Around the World recognition/badges/bonuses, trick multipliers, multiple divisions and numerous separate boards. Merely attempting a trick adds no points; visible valid contacts still follow the ordinary rule. |

**Included statistics:** device-counted streak, its duration and average counted
touches/minute. These describe the run and do not add ranking points. Backspin,
height categories, contact mix and left/right balance are deferred; sample design
values are not measurements from real accounts.

### Automatic beta testing checklist — 26 October

Use the leaderboard branch, two dedicated test accounts and the current Supabase
project. Keep fictional UI fixtures in the simulator; do not seed fake public
scores. Record device/build, account, session ID, visible total, saved streak,
expected rank and actual rank for each device case. Inspect the session rows using
the owner/session query before diagnosing a ranking mismatch as a counter failure.

| Order | Check | Expected result | Status |
| --- | --- | --- | --- |
| 1 | Disposable database suite, including retained approved reviews | Automatic score, duration and winning session ignore reviews; legacy RPC, periods/ties, privacy, opt-out and moderation remain correct. | Passed locally |
| 2 | Simulator regression suite with pending and legacy approved review fixtures | No review prompts, checked badges or report action; ordinary board loading, refresh, period switching and details work. | Passed: 21 unit + 6 UI tests |
| 3 | Deploy forward migration and inspect both public ranking endpoints | Automatic-only function is live, response shape stays compatible, review IDs are null, stored records remain intact. | Deployed and verified; board was empty at deployment, populated cases covered in disposable tests |
| 4 | Account A joins and records a short clean run, then two runs separated by a clear hand stop/ground bounce | The saved longest counted streak ranks, not the session total. A shorter subsequent result does not replace the best; a longer result does. No submission prompt or video upload. | First recording exposed 14 accumulated as one streak; fix passed saved-pixel comparisons. Fresh recording → local history → server → board validation pending |
| 5 | Account B records; compare each account and a signed-out viewer | Correct owner, one best entry per person, correct relative ranks; gallery imports and guest recordings never rank. | Device walkthrough pending |
| 6 | Record offline; reconnect; restart; switch accounts during sync | Session persists, retries once without duplicates, belongs to its original account and cannot leak into the second account's history. | Device walkthrough pending |
| 7 | Hide/show profile; delete a disposable test account; remove/restore one test score | Public row disappears/reappears correctly; account deletion removes owned data; score removal falls back to another eligible streak. Use disposable recordings for deletion. | Device walkthrough pending |
| 8 | iPhone 11 and iPhone 17, light/dark, large text, Reduce Motion, empty/one/many players | Rank, avatar, duration, rhythm and navigation remain readable; debug overlays are hidden for the final user-facing check. | Device walkthrough pending |

The updated branch is installed locally. Start the fresh device walkthrough with
case 4: a 30–60 second recording, one recording at a time, and compare the result
before continuing. Include a one-handed catch and a ground bounce followed by
immediate juggling without picking up the ball; the saved regression established
two-handed holds, not every type of interruption. Check a clean run with high
flights, brief occlusion and low foot contacts for false streak breaks.

On iPhone 11, check the same cases at the normal and thermally reduced analysis
cadences. Start with a 2–3 minute live session and compare extra pose work, memory,
thermal state and missed contacts against the existing baseline. The new bounded
streak probes can add Vision requests, so the short replay timing is not enough
to clear the long-session thermal risk. Extend the run if the short check exposes
a concern. The separate live-versus-encoded-replay difference of two contacts
also remains open. Correct or remove the known bad historical 14-point test entry
as a separate explicit data operation; new code does not overwrite synced scores.
Prepare a TestFlight build only after these gates pass and the owner is ready to
review it.

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
