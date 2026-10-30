# Juggle Dude iOS

The [four-week post-launch plan](docs/post-launch/README.md) records the agreed
priority order, weekly shipping scope, leaderboard rules and release checks.

[Looks, change moments, replay sounds and timer looks](docs/ball-swaps-and-sounds.md) describes the
Looks tool (runs of ball and effect, with recipes), the eleven change moments, the synthesized touch and change cues, and the
seven timer looks with counter-style placement,
milestone celebrations, My style and the iPhone 11 phone check.

Open `kicklab.xcodeproj` and use the `JuggleDude` scheme. The current target is iOS 26.5;
use Xcode with that SDK. Core ML packages in `kicklab/Models` and local account/analytics
configuration are excluded from Git. Obtain the approved
shared-function `RFDETRSmallRecovery040FP16.mlpackage` before building;
configuration templates are in `config/`. Never put server credentials in the app bundle.

## Main-app integration — 18 October 2026

Juggle Dude **1.0.1 (22)** (`com.juggledude`) combines the buffered RF live pipeline,
current juggling rules, selective fire/neon preparation, replacement-ball preparation,
and the current Power Shot camera timeline, moves, slow motion and exports. This is a
local testing checkpoint. On 18 October, the user authorized a TestFlight upload;
**1.0.1 (23)** was archived and uploaded successfully at 17:29 CEST. App Store Connect
currently lists it as Processing. This build also includes the source-frame timing
fix below and the latest Slow Motion/Frozen Arc changes. All 45 selected Simulator
checks passed (recording/export reliability, timing, camera timelines and two rendered
camera moves). The archive contains only the pinned shared RF detector and the required
production configuration/privacy resources. Source hashes were unchanged throughout
the build. The archive, source manifest/diff, test result and upload log are preserved
in `artifacts/releases/20261018-build23/`. No public App Store review was submitted.

`kicklab/Detection/RFDeviceProfile.swift` is the single local resolution policy:
the listed iPhone 14-and-newer hardware identifiers use `rf384`; older, SE and unknown
identifiers use `rf288`. The system hardware identifier comes from `uname`, independent
of the user-editable phone name. Live, imported and effects analysis use the same policy.
The shared RF package stores both functions with shared weights, about 62.6 MB compiled.
Normal Debug and Release include only this model. iPhone 11 uses the tested CPU fallback
when Core ML cannot load this RF graph with CPU + GPU. The camera recording retains its
original pixels; analysis owns separate, bounded buffers.

Install the pinned local payload with `python3 scripts/install-rf-model.py SOURCE.mlpackage`
or verify it with `python3 scripts/install-rf-model.py --check`. The script checks the
manifest hashes and preserves a previous payload in ignored `resource-backups/`.
`config/RFDETRSmall-model.json` records the shared-model provenance. Analysis cache keys
include the selected function and the current ground/contact-rule signatures.

The merge preserves the newer main-app camera and contact-rule sources rather than
overwriting them with the older standalone RF test snapshot. Ordinary sessions do not
write the RF diagnostic report folders; those require an explicit Debug validation launch.
Local evidence is in `artifacts/main-integration-20261018/`.

The [main-app validation report](benchmarks/touch-counting/main-integration-20261018.json)
records successful Debug/Release builds, complete 30-second paced replays and fire exports
on both phones. iPhone 17 covered all 272 selected regression tests after correcting one
bundled test-fixture path. iPhone 11 passed 271/272; one custom freeze-export colour
comparison still exceeds its tolerance (3/255 versus 2), although the same check passes
on Simulator. Main camera/editor UI automation remains incomplete because of navigation,
StoreKit fixture setup and device-state failures. These are local-test results, not a
release qualification or proof of equal counting accuracy at 288 and 384.

The iPhone 14 cutoff is a configurable product default, not a claim that every listed
phone has passed physical-device qualification. Previous distant/fast-ball misses at
288 and the earlier isolated iPhone 17 GPU stall remain part of release validation.

**Source-frame timing follow-up, 18 October:** an indoor live recording contained a
7.703-second opening gap followed by approximately 60 fps footage. Its nominal average
was only 46 fps, which the old composition used to reduce 1,519 source frames to 1,166.
The shared decoder now uses the source track's timestamps unless a caller explicitly
requests retiming. Both exporters retain the appropriate high-frame-rate MOV format,
and analysis cache version 14 invalidates artifacts prepared on the old clock.

The [timing validation report](benchmarks/touch-counting/source-frame-timing-20261018.json)
records exact source/composition timestamp agreement for all 1,519 earlier indoor,
2,193 fresh indoor and 1,877 outdoor 120 fps frames. Fifteen checks passed on iPhone 11,
including RF replay, masks and customized exports; fourteen passed on Simulator,
including Power Shot retiming and audio. The additional RF replay check could not
complete on Simulator because pose-model weights were missing, but passed on the phone.
Evidence is in `artifacts/ball-replacement-review-20261018/`.

This fixes export cadence, not the original recording startup stall or incomplete
replacement-ball coverage. The startup issue still needs repeated cold-start capture
validation before a launch decision. Indoor ball-edge/blur refinement is a candidate
for post-launch quality work. Keeping previously skipped frames can increase processing
time for affected clips. The fix is included in TestFlight build 1.0.1 (23).

The juggling pipeline separates camera coordination from analysis:

- `CameraSession` owns camera permissions/configuration, capture and recording lifecycle,
  queue scheduling, and published UI state. `Recorder` writes the original camera frames.
- `LiveJugglingAnalysis` owns live model preparation, detection, motion compensation,
  counting and the numeric results of a take. A single RF worker feeds a bounded delayed
  tracker and an ordered counter queue; capture admission returns snapshots for UI publication.
- `ContactObservationStore` owns bounded pixel buffers and lazy Vision body/hand requests.
  `JugglingContactVerifier` selects nearby evidence and applies the contact rules.
- `ContactCounterFactory` wires the counter once for live capture, imports and debug
  comparisons. `CountingPolicy` names the active body, ground and handling versions shared
  by live and imported counting.
- `ContactPose` defines typed joints, sides and shared numeric samples. Raw Codable keys
  stay compatible with existing saved traces and regression fixtures. Contact rules
  operate on these values without camera access; debug labels live in `TouchDebugEvent`.

Keep capture time, source-frame identity and analysis-frame index distinct. Refactoring
these components must preserve decision order, lazy inference, bounded retention and
recording cancellation. Verify both individual touch events and rejected candidates
against saved traces; matching only the final count can hide regressions.
The `TouchCountingDebug` scheme also runs unit/device tests in the separate debug app;
camera lifecycle tests require an unlocked physical iPhone. Use `JuggleDude` for tests
of the normal production-policy configuration.

For the standalone ball-presence camera page, run the **BallDetectionDebug** scheme.
It uses the **BallDetectionDebug** configuration and installs **Ball Detection Debug**
with bundle ID `com.juggledude.balldetection.debug`. It shows the rear-camera preview
and “Ball is detected” / “No ball detected” from each analysed frame using the bundled
model's confidence threshold. It does not record, count touches, recover tracks, or
start account, subscription or analytics services. This page is compiled only into
the separate debug configuration.

For the touch-counting experiment, run the **TouchCountingDebug** scheme.
It installs **Touch Counting Debug** (`com.juggledude.touchcounting.debug`) with
the normal recording and import flow, entering as a local guest. Direct head,
knee and foot proximity can qualify a candidate. Other contacts, including
clear chest contacts and feet projected over the torso, use one shared rule:
both wrists and elbows must be confidently visible and clear of the ball in
three consecutive views before, at and after contact. Wrist clearance includes
room for the hand; arms crossing the ball fail this test. Missing hands do not
mean clear hands. Existing positive knee/foot motion evidence remains available
when an arm projects near a legitimate kick; clear-hands eligibility adds a
shared path that does not require distinguishing chest from raised foot.
Low-foot eligibility uses a region around the ankle sized from the visible shin,
including toes pointing sideways. It requires lower-leg geometry below both
knees, but does not require shoulders or wrists to be visible. Raised feet and
torso overlap still use their separate evidence checks.
A turned, raised foot can also qualify from three real observations: a confident
ankle rises relative to its hip, the ball approaches that same foot and reverses,
then separates. A nearby observed contact up to 100 ms after the smoothed candidate
can supply this evidence. This path does not require a visible wrist; the hand veto
still runs at the original candidate and any later matched foot-contact frame.
It does not infer off-camera touches or relax the ground checks.
A continuity fallback uses a stable standing-knee height supported by at least
three observed extended-leg poses. A weak but actually observed ankle can also
qualify when two confident observations bracket it within 150 ms and agree with
its hip-relative position. Missing ankles and contradictory weak observations do
not qualify; the foot-motion, ball reversal and hand checks still apply.
A further continuity pass can corroborate weak but observed wrists,
knees and ankles (confidence 0.1–0.3) using the immediately adjacent observations.
Both neighbours need confidence at least 0.4 and must span at most 100 ms. The
actual weak position must agree within 0.2 ball diameters with the body-relative
track, and the shoulder/hip anchor must stay stable. It keeps the raw position
and confidence; a separate evidence flag lets the foot rule use a corroborated
ankle while still requiring two genuinely strong ankle observations. Missing
landmarks, whole-pose gaps, side swaps and contradictory observations stay
unresolved. Existing hand, handling, ground and foot-motion rules still apply.
This is the `clear-hands-v5` policy, promoted to normal Debug/Release for the 1.0.1 follow-up candidate; older replay policies stay unchanged.
On recording F316B075-E2EF-4B12-81A3-42FD0964A8BD, paired frozen replay recovers the
foot contact at 104.385 s and chest contact at 193.134 s. The chest contact at
183.766 s remains rejected because Vision loses the pose and nearby wrists.
The three labelled windows are in `observed-joint-device-contacts.json`.

A ball at or below the lowest visible ankle still needs foot-contact evidence;
clear hands alone cannot qualify a low bounce. Trajectory, player-region, ground
and hand checks still apply. The experiment
does not infer the precise contacting body part and can still miss contacts
with uncertain pose. Counter traces include the body eligibility verdict.
The current policy also checks a short handling window after the existing gates pass.
`BallHandlingEvidence` classifies it as held, in play or uncertain. A held verdict
requires two confident wrists bracketing the ball and staying coupled to it for
at least 150 ms in four or more observed views, including 50 ms on each side of
contact. Geometry is scaled to ball size and image aspect. Gaps over 100 ms,
weak/missing wrists or separation cannot establish a grip. Only held rejects;
uncertainty leaves the existing contact rules in charge. State is local to this
contact window, so a catch cannot suppress later legitimate kicks. This is a
conservative two-hand grip check, not full-session possession or single-hand
recognition. It reuses the bounded frame cache and runs no preview/every-frame
pose worker. The HUD shows a red **Ball held** marker for these rejections.
Numeric handling evidence is saved for exact replay; `|handling-v1` keeps the
analysis cache versioned. Normal Debug/Release use this check too.

Normal Debug/Release use observed-joint continuity (`clear-hands-v5`), sustained-grip
checks (`handling-v1`) and corroborated-feet ground rejection (`counter-v9`).
Frame-rate simulation, contact diagnostics and the subscription bypass remain
exclusive to Touch Counting Debug.
Account and analytics configuration files are excluded from this separate app.
All features are free in Touch Counting Debug: live metrics, effects, ball skins,
overlays, shot tools and exports. Subscription prompts and the profile upgrade
entry are disabled; no purchase is needed. In the main app, the live counter and
timer are free. Replay and export include a free Normal counter and optional timer;
decorative counter styles, ball skins, effects and graphs still require Pro.

**Frame-rate experiments:** the recording screen in Touch Counting Debug has a
**Frame test** menu. Choose Normal (existing 30 fps analysis ceiling), 20, 15 or
10 fps, or 30/15 fps with a 200 ms analysis gap every three seconds. Select before
Record; the selection stays fixed until the take ends and defaults to Normal
when reopening the screen. The writer and preview retain their normal cadence.
Sampling happens after writing, preserves source timestamps/frame identities,
and never sleeps on the capture queue or adds a frame backlog. Imports are unaffected.

The HUD separates intentional sampling skips from actual camera drops, writer
drops and replaced pending analysis frames. Camera FPS is measured from delivered
source timestamps; analysis FPS measures completed processing. Reports under the
debug app's `Documents/FrameRateTests` retain the profile, counts, source filename,
capture statistics and largest gap between submitted analysis timestamps.
Start with Normal, then 15 fps, then 15 fps + gaps; review original video against
live touch markers for missed contacts and false ground/hand counts. This tests
input sparsity, not slower inference, memory pressure, heat or iPhone 11 hardware.
It cannot replace sustained testing on an older physical device or identify the
original iPhone 11 failure by itself. Sampling helpers have unit tests; the
`DebugFrameSamplingTests` physical-camera check verifies unchanged recording
cadence, take-level selection locking and reset between modes.

**iPhone 11 Pro Max investigation — 16 October 2026:** the connected device is
`iPhone12,5`, running iOS 26.6.2. The reported symptom is missed or delayed live
counts; its installed normal app was 1.0 (11). The current RF-DETR FP16 model
initially failed to load with CPU + GPU execution (`inner_product_kernel` type
mismatch, Core ML execution-plan error -5). It does execute on CPU. RF model
loading now falls back to CPU when accelerated loading fails, retaining that
backend for the worker instead of retrying the failing load each frame. The
model weights, confidence thresholds and contact rules remain unchanged.

On this phone, an optimized Touch Counting Debug 30-second automated camera
check saved 1,813 frames at approximately 60 fps with zero camera/writer drops.
It analysed 222 frames (about 7.3 fps), with median sampled inference of 128 ms,
94.4 MiB peak sampled app footprint and nominal thermal state. Thirteen focused
device tests passed, including startup/reopen, recording retention and backend
fallback/cancellation. This was a camera smoke check with no verified juggling
contacts or pose requests, not touch-accuracy or sustained thermal validation.
The main unsigned Release build also passes. A subsequent front-camera juggling
test retained 1,816 frames over 30.3 seconds (four capture drops, zero writer
drops), but processed only 204 frames live and reported three touches. Its
sampled footprint peaked at 155.4 MiB with nominal thermal state. The original
and live evidence are retained under report `52F520CD-2704-47C1-8C26-96071EED9B92`.
An uncached full-frame pass decoded 1,813 frames and counted eight touches in
489.5 seconds, including 210.5 seconds of thermal pacing; thermal state reached
serious. It had zero detector errors. Preliminary frame review suggests ten
genuine kicks: the full-frame counter rejected candidates at 23.547 and 24.565
seconds as ground bounces. The apparent live floor-bounce count near 25.52
seconds was correctly rejected by the full-frame pass. These are development
observations from one clip, with user confirmation of ground truth still pending.
The startup failure is handled by CPU fallback; live throughput and contact-rule
accuracy remain open. CPU record-then-analyse improves this clip but is too slow
and still misses contacts, so it is not yet a qualified reliability fallback.
An additional 24-image, two-round backend comparison measured median prediction
times of 121 ms with CPU and 980 ms with CPU + Neural Engine; `.all` failed the
same execution-plan load. This is an execution-option comparison, not a hardware
placement trace or sustained live benchmark. No alternative backend was promoted.
The debug HUD and detector CSV identify `CPU (compatibility)` when selected.
Local build/test logs, the original failed run, four model/backend comparisons
and retained camera evidence are in ignored `artifacts/iphone11-20261016/`.

**GPU follow-up, same phone:** an isolated model export now loads and executes
with CPU + GPU after replacing four deformable-attention value projections with
equivalent 1×1 convolutions. The learned weights file is byte-for-byte unchanged;
this is an export rewrite, with no training or confidence-threshold change.
The reproducible exporter and four passing rewrite tests are in the sibling
`kicklab-lab` repository (`scripts/export_rfdetr_gpu_compat.py`). On 24 saved
development images, the original CPU model measured 121 ms median prediction,
the four-layer GPU candidate 879 ms, and a newer fused-attention GPU candidate
421 ms. All measured frames in this sequential comparison were at serious thermal
state; these are diagnostic timings, not sustained live FPS. Neither GPU candidate
changed whether the selected ball passed the 0.40 threshold. The four-layer
candidate's maximum ball-probability difference was 0.0324 and minimum selected
ball-mask IoU was 0.9846; this does not establish touch-count accuracy. An actual
A13 Metal trace of the earlier eight-layer compatibility variant confirms GPU
execution; selecting GPU does not itself make this model faster. The compatibility
candidate is retained separately and has not replaced the app model, because its
GPU throughput would worsen live counting. Live performance and contact accuracy
remain release blockers. See the [compact GPU report](benchmarks/touch-counting/iphone11-gpu-20261016.json)
and ignored `artifacts/iphone11-gpu-20261016/` for the full phone results and trace.

**17 October overnight study, completed 02:51 Berlin:** the isolated Model Audit
app attempted 64 trials on the same phone, recording 58,143 measured predictions:
58 trials completed, four original RF16 GPU/automatic loads failed, and two
YOLO26 Small CPU + GPU loads timed out unresolved. All six ten-minute endurance
trials completed. Sustained median prediction/cycle times were 152/158 ms for
RF16 CPU, 30/34 ms for YOLO26 Small automatic, and 37/43 ms for YOLOX Tiny
CPU + GPU. Whole-run cycle rates were 6.4, 28.3 and 22.9 per second respectively;
these exclude camera, pose and contact counting and are not live app FPS.
All endurance trials reached serious thermal state, with none reaching critical.
Brightness and starting thermal conditions varied, so this is not a controlled
energy or thermal comparison. Whole-process memory includes retained sample logs
and repeated JSON serialization; a bounded-logging repeat is needed before
attributing growth to a model. Visual inspection also confirmed that faster
models sometimes select the stationary spare ball instead of the juggling ball.
The top-scoring-box harness does not run production association/tracking, so full
sequence selection and contact accuracy still require validation. No production
model was replaced. See the [reviewed overnight report](benchmarks/touch-counting/iphone11-endurance-20261017.json)
and original evidence in `artifacts/iphone11-endurance-20261017/`.

**Licensing constraint, 17 October:** the owner excludes a paid Ultralytics
enterprise licence from the launch plan. YOLO26 benchmark speed is comparison
evidence, not a recommendation to ship that model. Prioritize the Apache-licensed
RF-DETR path. YOLOX-Tiny is a
separate Megvii Apache-2.0 project; local records trace its parent weights to
Megvii and its fine-tuned checkpoint to our separate training/export scripts.
Its exact distribution provenance and feature/accuracy requirements still need
validation; it is not part of the current implementation plan. See the
[licensing constraint and revised options](benchmarks/touch-counting/iphone11-license-constraint-20261017.json).

**Owner direction, 17 October: one shared RF-DETR model across devices.**
Continue with the current trained RF-DETR Seg Small checkpoint. Do not introduce
an iPhone-specific detector or pursue YOLO/YOLOX as the solution. The active work
is export/runtime optimization with the same learned weights, detection thresholds
and counting behavior, followed by full live-pipeline validation. CPU/GPU execution
may be selected for measured performance without selecting a different trained model.
Any input-resolution or tracking change must be evaluated separately and qualify as
part of the shared pipeline; neither is an established fix. The October 17 follow-up
tests and rejected candidates are recorded in the
[shared RF-DETR study](benchmarks/touch-counting/iphone11-rf-shared-20261017.json).
That bounded study completed 30 physical-device trials (504 measured predictions;
repeated development stills, not live counting) and ten query-batching regression
tests. Flattening linear-layer inputs to rank two preserved weight bytes and the
output contract, reducing GPU median prediction time from 426 to 353 ms (~17%).
The original CPU export remained faster at 117 ms. A diagnostic prefix ending
before the final backbone feed-forward sub-block measured 183 ms on GPU versus
80 ms on CPU; prefix compilation can change execution,
so this is a bottleneck clue rather than additive operator timing. The rank-two GPU
candidate had no ball/person threshold flips on these images, but maximum ball-score
drift of 0.0401 exceeds the prior strict 0.03 guard. It is not release-qualified.
Query batching was rejected: the fused form failed Mac CPU agreement, and the
explicit form ran slower on A13 GPU (~602 ms). Production inference and counting
are unchanged; sustained live performance and contact accuracy remain unresolved.

**Identical GPU controls on both phones — 17 October 2026:** the same signed
diagnostic ran on the iPhone 11 Pro Max and iPhone 17 Pro Max. All 21 Metal/MPS
trials per phone passed their numerical checks (630 measured GPU timings each),
including FP16. A13 therefore supports these FP16 GPU workloads; the original
RF-DETR execution-plan error is a specific graph/runtime compatibility problem.
The measured speed gap depends on the work: approximately 2× for buffer copying,
3–6× for scalar arithmetic and 12–52× for the tested transformer-shaped matrix
operations. This does not isolate hardware from OS/driver effects: the phones run
iOS 26.6.2 and 27.0.1, respectively, with recorded but uncontrolled charging and
thermal conditions. These short tests are not sustained live-camera FPS.

| RF-DETR prediction, median ms | iPhone 11 Pro Max | iPhone 17 Pro Max |
| --- | ---: | ---: |
| Original shared weights/export, CPU | 117 | 41 |
| Original export, CPU + GPU | Execution-plan failure | 16.4 |
| Rank-two compatibility export, CPU + GPU | 353 | 19.0 |

The next explicit-matmul rewrite retained identical weight bytes but aborted
inside Apple's MPSGraph optimizer on A13 during load/warmup, before measured
predictions. It offered no GPU speed improvement on the newer phone and is
rejected as a shared deployment candidate. Core ML `fastPrediction`/`infrequent`
hints and low-precision GPU accumulation settings also provided no useful A13
speed improvement (351–354 ms). Their checked outputs matched the rank-two GPU
reference; this does not waive that export's existing numerical guard failure.
Full evidence, source hashes, conditions, crash details and follow-up measurements
are in the [cross-device GPU/RF-DETR study](benchmarks/touch-counting/metal-rf-cross-device-20261017.json).
No production model or live-counting fix was promoted. The targeted backbone and
tracking follow-ups below continue this investigation. Both approaches still need
labelled live-session and replay/mask validation on both phones.

**Targeted backbone follow-up — 17 October 2026:** Core ML's A13 plan assigns all
72 backbone dense layers to GPU, while 39 later dense operations are assigned to
CPU. A13 supplies no per-operation cost estimates; absent metadata is not zero
cost. A launch-based trace measured 9.59 seconds of GPU compute overlapping 13.23
seconds across 37 prediction intervals, so CPU fallback alone cannot explain the
latency. The Neural Engine prefix plan assigns its 70 dense layers to CPU.
Rewriting only the 24 backbone feed-forward dense operations to matrix products
executes on both phones and preserves checked outputs, but gives no useful speed
improvement: A13 GPU 355 → 353 ms and newer-phone GPU 19.11 → 19.13 ms. Six focused
rewrite tests passed. See the [backbone study](benchmarks/touch-counting/iphone11-rf-backbone-20261017.json).

**Tracking feasibility follow-up — 17 October 2026:** new inference on both phones
compared the original shared RF-DETR 384 export on CPU with the existing Vision
pixel tracker between RF detections. At 30 sampled frames/s, RF every sixth frame
reduced the iPhone 11's processing time for an eight-second development segment
from 29.68 to 6.64 seconds, but supplied observations on only 162/240 frames versus
214/240 for all-frame RF. Immediate re-detection improved availability to 220/240
but took 11.61 seconds; limiting recovery to at most six RF calls per source second
took 7.23 seconds with only 172/240 observations. See the
[initial and immediate-recovery study](benchmarks/touch-counting/rf-tracking-feasibility-20261017.json)
and [bounded recovery study](benchmarks/touch-counting/rf-tracking-budget-20261017.json).

Reducing analysis sampling to 20 frames/s did not resolve that tradeoff. These are
sequential replay times for the same **eight-second clip**, not live-camera FPS:

| 20 fps diagnostic policy | iPhone 11 elapsed | iPhone 17 elapsed | iPhone 11 observations |
| --- | ---: | ---: | ---: |
| RF on every sampled frame | 19.83 s | 7.74 s | 144/160 |
| RF every fourth frame plus pixel tracking | 5.94 s | 2.55 s | 105/160 |
| Immediate RF recovery after tracker loss | 10.32 s | 4.18 s | 149/160 |
| Recovery, retaining normal cadence after an empty RF result | 9.31 s | 3.73 s | 144/160 |

The iPhone 11 stayed thermally nominal; the newer phone was at fair thermal state
in this final comparison. CPU-only on both phones isolates the tracking experiment;
it is not a proposed newer-phone deployment policy. See the
[20 fps study](benchmarks/touch-counting/rf-tracking-20fps-20261017.json).
Observation availability is not accuracy: visual review found the highest-scoring
RF reference sometimes selected a second floor ball while tracking retained the
held ball. The harness omits production association, camera, pose, counting, masks
and asynchronous scheduling. A13 RF frames still take roughly 120 ms individually.
No tested policy yet demonstrates reliable live counting, and no production code
or model was changed by these follow-ups. The asynchronous prototype below
continues the investigation. It must pass labelled contact/negative cases,
mask/replay checks and sustained full-camera tests before promotion; average
replay speed alone cannot qualify it.

**iPhone 11 asynchronous prototype — 17 October 2026:** the owner excluded the
iPhone 17 while another test was running. The diagnostic now runs one CPU RF job
independently of native tracking, retaining the original shared 384 model. A
current-frame catch-up variant processed 237/240 paced frame opportunities versus
65/240 for synchronous RF, with p95 publication delay 35.2 versus 150.4 ms. However,
it supplied only 110/240 observations; catching up an old detection often failed.
See the [catch-up report](benchmarks/touch-counting/rf-async-tracking-20261017.json).

A second implementation delays analysis by 200 ms and consumes observations in
original timestamp order. It caps the retained video at 16 frames and RF work at
one job or unread reply, discarding late results. Three rotated rounds completed
without scheduled frame drops, buffer overflows or late RF replies; sampled
thermal state stayed nominal and memory remained below 91 MiB. The 60 fps / 6 Hz
acquisition variant had p95 publication delay 211.5–213.2 ms. These are paced replay
results with no camera/pose/counter workload, not proven live-counting throughput.

Review rejected the initially impressive coverage: an ungated 60 fps trial mostly
followed the spare floor ball. A fixed-camera acquisition experiment excludes
objects remaining near their initial RF positions; it avoided the reviewed spare
ball region in all three rounds, but can fail with camera movement or an intended
ball crossing those positions. During the four-second fast-motion section,
60 fps / 6 Hz supplied 107–118/240 observations and still had gaps of 167–333 ms.
Coverage is not labelled accuracy. See the [buffered replay](benchmarks/touch-counting/rf-async-buffered-20261017.json)
and [acquisition study](benchmarks/touch-counting/rf-async-identity-20261017.json).

An instrumented copy of the unchanged tracker gates found 42 first failures from
Vision confidence below 0.5, 12 from texture correlation and five from bounds
across three repeats. Size gating was not the dominant failure. The
[failure audit](benchmarks/touch-counting/rf-async-failure-20261017.json) includes
confidence and candidate geometry; a failed gate does not establish that accepting
that candidate would be correct. The prototype and deterministic checks are in
[the diagnostic source directory](benchmarks/rf-async-control/README.md).

The final guarded-confidence experiment kept the original checks, additionally
allowing Vision confidence 0.4–0.5 only with texture correlation ≥0.65 and an RF
seed no older than 150 ms. In three rotated repeats it supplied 127–131/240
observations in the fast section versus 97–114/240 for the strict control, with
no scheduled drops and p95 delay 212.2–212.8 ms. Gaps still reached 267–283 ms.
All 35 delivered soft-confidence observations met those guards; 19 aligned with
the older all-frame RF reference and had median box IoU 0.766, which is agreement,
not accuracy. No tracker or counting change was promoted. See the
[confidence comparison](benchmarks/touch-counting/rf-async-confidence-20261017.json)
and [complete asynchronous investigation](benchmarks/touch-counting/rf-async-iphone11-20261017.json).
The bounded scheduling approach is viable in this isolated replay; correct active
ball tracking through rapid motion and full camera/pose/contact/mask validation
remain unresolved.

**Full counter comparison, 17 October:** ten wall-clock-paced replays of the full
30.3-second development recording include frozen copies of the counter and
contact/pose verifier from the start of this investigation, motion compensation,
RF plausibility, and direct RF mask decoding. The isolated diagnostic ran only on
iPhone 11. Source timestamps,
observation geometry, queue bounds, model/build hashes, and all ten exact counter
trace replays passed the audit. Camera capture, writing and UI rendering are still
excluded. The reviewed ten visible foot contacts have approximate assistant labels;
user confirmation and independent footage remain pending.

| CPU RF-DETR pipeline | First / second count | Processed frames per second |
| --- | --- | --- |
| Direct 384 | 4 / 0 | 7.6 / 6.5 |
| Direct 288 | 7 / 6 | 12.2 / 11.9 |
| Async 384, RF at most 6 Hz | 4 / 1 | 50.2 / 50.1 |
| Async 288, RF at most 6 Hz | 4 / 4 | 50.6 / 52.0 |
| Async 288, RF at most 12 Hz | 5 / 4 | 49.6 / 48.3 |

Every emitted touch matched a reviewed contact within 200 ms. The second rotated
round coincided with fair/serious thermal states; this does not isolate heat as the
cause of the count change. Direct 288 is the strongest provisional result here,
but still misses contacts. It is a resolution export of the same trained checkpoint,
with changed resolution-dependent constants, and has not replaced the shared model.
High tracking throughput alone did not fix counting: contact verification can block
input for hundreds of milliseconds, sometimes omitting an entire contact window.
Other misses retain input but fail trajectory/contact checks. See the
[counter comparison and audit](benchmarks/touch-counting/rf-async-counter-20261017.json)
and [diagnostic source](benchmarks/rf-async-control/CounterProbe.swift).

A subsequent four-trial comparison isolates the contact worker at 288/12 Hz.
Both variants start after the phone reaches nominal thermal state. Inline contact
verification counts 4/4 and drops 229/230 source frames; an independent serial
contact queue counts 8/9 and drops 2/1. All counted timestamps match the reviewed
contacts. The queue peaks at 18/19 of its 32-frame capacity, with no overflow or
late RF replies; sampled memory peaks at 179/189 MiB. Median touch notification
delay is 590/582 ms from the source contact timestamp, including confirmation,
the fixed 200 ms analysis delay and pose work. It is not instantaneous counting.
All four counter traces replay exactly. The first queued run misses 22.88 s and
23.53 s; the second still misses 23.53 s. See the
[contact-queue comparison](benchmarks/touch-counting/rf-contact-queue-20261017.json).

The resumed four-trial shared-export comparison completed in a separate diagnostic
app after the GPU test released the iPhone 11. With the independent contact worker,
the **original 384 export counted 9 of 10 in each repeat**, while 288 counted 7 and
9 of 10. Each count matched
the reviewed contacts with no unmatched emissions. Original 384 processed
59.2/59.6 frames per second, with 20/7 late source drops and RF prediction medians
of 123/125 ms. All four traces and source/build/geometry/queue audits passed.
Resolution and RF cadence differ (384 at most 6 Hz; 288 at most 12 Hz), so this
compares complete strategies rather than isolating resolution. This shows the
original shared export can benefit from scheduling changes; it does not establish
live accuracy.
See the [resumed comparison](benchmarks/touch-counting/rf-contact-queue384-resume-20261017.json).
The interrupted attempt remains separate: only two recovered traces are valid;
a stale third trace is explicitly excluded from its
[recovery record](benchmarks/touch-counting/rf-contact-queue384-interrupted-20261017.json).

At the recurring miss, the actual source frame at 23.550 s has no tracked ball
(Vision confidence 0.314), while its immediate neighbors do. The body verifier
rejects the contact as `missingBall`. Fresh **Mac CPU** inference on that exact
frame detects the active ball at 0.978 with RF384 and 0.940 with RF288, using the
unchanged 0.40 threshold and Swift input normalization. This suggests a bounded
RF recheck of a retained impact frame as a possible technique; the Mac result
alone is not a recovered phone count. See the
[exact-frame detectability check](benchmarks/touch-counting/rf-impact-detectability-20261017.json).

**Generic gap-retry result:** eight additional iPhone 11 trials tested a second
CPU RF worker on missing tracker frames, with a recent identity hint, unchanged
confidence/identity/contact rules, and bounded rate/age/queue limits. The second
round reversed trial order. At 384, controls counted 7 and 6 versus retries at
5 and 7. At 288, controls counted 10 and 10 versus retries at 9 and 9. All emitted
contacts matched the approximate review; all eight trace/provenance audits passed.
Retries increased median touch-notification delay (384: about 0.70 s versus
0.54 s) and memory (384 peaks 257/279 MiB versus control 181/239 MiB). One 384 retry
run filled the 32-frame queue and dropped nine counter inputs. **Do not promote
this retry variant.** A targeted recheck at a real contact candidate, with RF work
scheduled on the existing worker, is evaluated in the follow-up below. The original
384 controls also varied from the earlier 9/9 to 7/6 here; the scheduling change
does not yet establish reliable counts. See the
[paired retry comparison](benchmarks/touch-counting/rf-contact-retry-20261017.json).

**Sustained original-384 result:** six consecutive full replays, with no deliberate
cooling between clips, counted **8, 7, 7, 5, 4, 4**. The first starts nominal;
later clips reach serious thermal state. Median RF prediction grows from 123 to
170 ms; late RF replies rise **0, 0, 3, 12, 44, 49**. Input processing stays near
58–60 fps and the contact queue never overflows, showing that frame throughput
alone is misleading. Clip five includes a visually reviewed false contact on the
stationary spare ball at 19.850 s, so only three of its four counts match the
reviewed contacts. All six provenance/trace audits passed, including duration checks
that exclude an extended app suspension. This fresh run supersedes an interrupted
attempt; the model/counter still reset and warm up between clips. **The original
384 CPU strategy is not a reliable sustained solution yet.** See the
[sustained report and spare-ball review](benchmarks/touch-counting/rf-contact-sustained384-20261017.json).

**Sustained 288 comparison:** the same six-clip design with 288 at most 12 Hz
matched **10, 9, 9, 9, 9, 8** reviewed contacts, with no unmatched counts. Prediction
median rose 66→91 ms and late RF replies were 0, 0, 0, 2, 3, 5, substantially
below the original-384 strategy's late-result counts. The counter queue remained
bounded (peak 25/32, no overflow), but the phone still reached serious thermal
state: the last clip dropped 84 source frames and median notification delay grew
from about 0.56 to 0.67 seconds. All six audits passed. This is the most promising
tested export/scheduling candidate, **not a production promotion or a per-device
model split**. Both resolutions derive from the same checkpoint; any proposed
shared 288 export still needs small/distant-ball and independent negative checks.
The two sustained studies were sequential and differ in both resolution and RF
cadence, so they are not a resolution-only ablation. See the
[sustained comparison](benchmarks/touch-counting/rf-sustained-comparison-20261017.json)
and [288 detail](benchmarks/touch-counting/rf-contact-sustained288-20261017.json).
The lower/adaptive cadence comparison below now completes that next experiment.
The original RF384 GPU-loading failure remains unresolved.
The queue remains diagnostic: live camera/writer load, independent negatives,
active-ball reacquisition and reliable sustained counting remain unresolved.

**Cadence follow-up, 17 October:** 30 new full iPhone 11 replays held the RF288
export, frozen counter, tracking and bounded contact worker constant while changing
only RF submission scheduling. Four six-clip blocks tested fixed targets and
thermal adaptation; a supplemental fixed8 repeat checked the initial thermal result.
Each block started a fresh process and required nominal thermal state, then ran
six clips without deliberate cooling. Model/counter/tracker still reset and warm
up between clips. These are repeated development replays, with approximately ten
assistant-reviewed contacts per clip, rather than independent or live-camera trials.

| RF target | Matched contacts in each of six clips | Total / 60 repeated opportunities |
| --- | --- | ---: |
| Fixed 12/second | 10, 10, 8, 8, 9, 9 | 54 |
| Fixed 8/second | 8, 8, 8, 8, 10, 8 | 50 |
| Fixed 6/second | 8, 8, 9, 7, 9, 9 | 50 |
| Thermal 12 → 8 → 6/second | 10, 9, 9, 8, 7, 7 | 50 |
| Fixed 8/second, supplemental repeat | 8, 8, 8, 8, 8, 7 | 47 |

There were no unmatched counts against this clip's approximate labels. All 30
source/provenance, chronological geometry, bounded queue, cadence and exact trace
audits passed; no contact queue overflowed. Lower targets reduced RF jobs, but did
not establish reliable counting. The first fixed8 block peaked at fair thermal
state; the identical repeat reached serious during clip three, with median RF time
rising 65→86 ms. Nominal OS state does not guarantee equal internal temperatures,
so the first cooler run is not a repeatable thermal advantage or energy measurement.
Fixed12 remains the diagnostic control; no cadence-only variant is promoted.

Forty of 49 missed contact opportunities had a nearby `missingBall` body rejection.
That motivated the bounded contact-frame recheck evaluated below, using the same RF
model and worker while preserving source timestamps, ball identity/confidence and
hand/ground rules. Current-counter validation is still required: `TouchCounter` and
`StreamingCounter` have since gained time-aware trajectory handling outside this
frozen comparison. Active-ball selection, live capture/writing, independent
negatives and small/distant balls remain gates. No production model or app source
was changed by this cadence study; the iPhone 17 was untouched and all five
study-launched iPhone 11 diagnostic processes were stopped. See the
[cadence comparison and follow-up decision](benchmarks/touch-counting/rf-contact-cadence-20261017.json)
and [reproduction helpers](benchmarks/rf-async-control/README.md).

**Targeted contact recheck, 17 October:** implemented and tested an isolated
prototype on iPhone 11. An actual contact candidate can request RF on its missing,
retained source frame. Both approach and release identity observations must already
exist within 100 ms. At most eight original frames are retained; age, confidence,
identity and rate limits apply. The existing serial RF worker handles the request
with one CPU model instance. Measured evidence is inserted before the contact gates;
the frozen counter rules and chronological tracking inputs are unchanged.

Sixteen new paced replays used the same RF288 export and fixed12 scheduling:

| Comparison | Control: matched contacts | Recheck: matched contacts |
| --- | --- | --- |
| Two single-clip runs each | 10, 8 — **18/20** | 10, 10 — **20/20** |
| Six consecutive clips each | 9, 10, 8, 8, 8, 6 — **49/60** | 10, 10, 9, 8, 8, 9 — **54/60** |

The first sustained control emitted ten counts but only nine matched real reviewed
contacts. Source-pixel review confirms its extra count at 26.017 s was on the
stationary spare ball. Recheck trials had no unmatched counts. These are repeated
development clips with approximate assistant-reviewed labels, not independent
accuracy trials. Block order and nominal thermal starts do not equalize internal
temperatures; both sustained blocks reached serious thermal state.

A separate **16-pass on-phone evidence ablation** held the eight recheck runs'
recorded tracking inputs fixed and recomputed all Vision contact gates from the
actual source pixels. Toggling the saved measured contact evidence changed matched
counts from **68 to 74 out of 80 repeated opportunities**: six recovered contacts,
zero lost or unmatched contacts. All evidence-on decisions exactly reproduced the
original runs. Eight observations had been inserted; two made no count difference.
This establishes a limited evidence benefit, excluding scheduler effects. It used
saved RF observations and fresh Vision inference, not new detector inference.

**Do not promote yet.** The hot recheck block dropped **three counter inputs** at
its 32-frame queue capacity (control: zero), reached about **0.95 s** maximum count
notification delay, and peaked at **256 MiB** including diagnostic logs/traces
(control: 241 MiB). Its six remaining misses were four ground-bounce rejections
and two tracking losses. All provenance, source, identity, serial-inference and
trace audits passed; bounded-queue integrity does not mean zero dropped inputs.
The provisional “no overflow” interpretation was corrected in the reviewed report.

The follow-up below tests backlog-aware admission with a frozen snapshot of
the current time-aware counter. Continue diagnosing ground-versus-foot decisions and active-
ball reacquisition without relaxing negative safeguards; the recheck does not solve
spare-ball selection. Live camera/writer/rendering, hot sessions, fresh positives/
negatives and small/distant balls remain required before any shared export change.
The GPU-loading failure remains open. This experiment changed no production app or
model files; iPhone 17 was untouched. All eight owned diagnostic processes,
including the excluded configuration-transfer attempt, were stopped and verified
absent. The corrected [results and follow-up decision](benchmarks/touch-counting/rf-contact-targeted-20261017.json)
are mirrored byte-for-byte in the lab. Raw timing evidence is in
`artifacts/rf-contact-targeted-20261017/`; ablations are in
`artifacts/rf-contact-ablation-20261017/`.

**Current-counter backlog and 30 fps follow-up, 17 October:** completed 32 new
paced replays and 24 fixed-input evidence passes on iPhone 11. All comparisons use
the same frozen current counting/contact sources, RF288 CPU export and reviewed
30.33-second development recording. The detector/bridge/tracker remain frozen from
the earlier harness; active-player selections are nil. Later workspace edits are
listed in the reports. This is not validation of the complete current app.

| Six-clip treatment | Matched reviewed contacts | Unmatched counts | Counter queue drops | Peak queue |
| --- | --- | --- | --- | --- |
| 60 fps, strict backlog/idle-worker guard | 47/60 | 0 | 0 | 22/32 |
| 60 fps, waiting contact recheck | 51/60 | 0 | 0 | 26/32 |
| 60 fps, rechecks disabled | 48/60 | 1 | 0 | 30/32 |
| 30 fps, waiting contact recheck | **60/60** | **0** | **0** | **14/32** |
| 30 fps, rechecks disabled | 51/60 | 0 | 0 | 10/32 |

The strict guard admitted only one recheck across six clips and provides no
demonstrated queue-drop advantage here; do not carry it forward unchanged. The
60 fps control's extra count at 26.017 s again falls on the stationary spare ball,
verified against the same source pixels and measured ball position.

The **30 fps contact-recheck path is the preferred next diagnostic integration
candidate**. It matched ten contacts in every clip, including those at serious
thermal state, with 19 measured observations inserted. Fixed-input on-phone checks
recomputed Vision with saved RF evidence off/on: **44→60/60** at 30 fps and
**46→51/60** at 60 fps. No contacts were lost or unmatched, and every evidence-on
decision reproduced the original. These checks isolate the contribution of saved
contact evidence, not its scheduling effects or independent accuracy.

At 30 fps, recheck diagnostic memory peaked at **146 MiB** (60 fps: 237 MiB),
with nine late source drops versus 183 in the 60 fps recheck block. Each 30 fps
clip intentionally skips 907 of 1,816 source samples; those omissions are audited
separately from late-source and counter-queue drops, and the original video stays
unchanged. Actual regular RF cadence was about 9.3–9.9 Hz under the fixed12 cap.
Heat and visible delay remain: both 30 fps blocks reached serious thermal state,
hot RF prediction medians were about 85 ms, and recheck notification medians were
583–688 ms, with an 846 ms maximum. Nominal starts and sequential block order do
not establish equal internal temperatures or an energy improvement.

The live app **already caps analysis at 30 fps**. The next implementation step is
to integrate the targeted recheck into an explicitly enabled diagnostic of its
actual live pipeline, preserving one RF worker, bounded source retention,
deadlines and the original identity/hand/ground gates. Then validate active-player
integration, thermal cadence, camera/writer/rendering load, notification latency,
and independent fast-contact, negative and small/distant-ball footage. The repeated
development result is not a release accuracy claim. No production app/model was
promoted and the GPU export failure remains open. All nine study-owned processes
were stopped and verified absent; iPhone 17 was untouched.
See the [60 fps backlog report](benchmarks/touch-counting/rf-contact-backlog-20261017.json),
[30 fps comparison](benchmarks/touch-counting/rf-contact-backlog30-20261017.json)
and [reproduction helpers](benchmarks/rf-async-control/README.md). Both compact
reports are mirrored byte-for-byte in the lab; raw evidence and both ablations
are retained in the corresponding `artifacts/rf-contact-backlog*20261017/` folders.

**Manual live camera, 17 October:** the separate **RF Live Test** app
(`com.juggledude.rflivetest`) is installed on iPhone 11 for the owner's hands-on
check. Camera permission and model preparation succeeded, and a manual recording
was observed starting. It reuses the fixed30 RF288 CPU/recheck candidate with a
live front/rear portrait preview and raw video writing. **Record test** starts a
fresh count; **Stop & save** keeps `video.mov`, `counter.plist` and `report.json`
in a unique local folder. Tests stop after three minutes or on interruption/
critical heat. No microphone or video annotations are used. Camera-owned buffers
are copied into a bounded pool, and capture, writer, analysis and counter drops
are reported separately with source-frame mapping.

This is a manual diagnostic of the frozen candidate, with nil active-player
selections, rather than a promotion into the normal live app. The owner's first
recording completed its three-minute limit and saved **130 counts**. All 5,400
delivered frames were written and processed (29.99 fps); there were three capture
drops, zero writer/copy/analysis/counter-queue drops, and peak counter queue depth
12/32. RF inference ran at 8.19 Hz on average. Counter notification latency was
613 ms median and 751 ms maximum; these timings end at emission, not display
presentation. Thermal state became serious at 102.7 s, without critical heat or
queue overflow; diagnostic memory peaked at 156 MiB. Twelve of 14 targeted RF
rechecks inserted ball evidence, which is not a count of recovered touches.

The initial visual review confirmed **at least two missed foot contacts**, around
5.2 and 5.6 s, both rejected with `disallowedBodyContact / missingPose`. All 27
inputs across 4.9–5.8 s had accepted ball observations and person boxes, with no
shaky frames and nominal thermal state. These particular misses concern contact
verification after tracking; the exact missing-pose mechanism still needs replay
diagnosis. Selected counted kicks, floor-bounce rejections and a held-ball interval
were also checked. **130 is the app's count, not ground truth**: the full session
has not been exhaustively labelled, and no overall accuracy rate is claimed.

See the [manual recording review](benchmarks/touch-counting/rf-live-camera-review-20261017.json),
mirrored byte-for-byte in the lab. Raw video, trace, report, hashes and review
stills are preserved in `artifacts/rf-live-review-20261017/`. Build/provenance/
deployment records remain in `artifacts/rf-live-camera-20261017/`; reproduce with
`benchmarks/rf-async-control/stage_live_camera.py`. Next isolate pose/foot evidence
failures and reduce notification delay while preserving floor/hand rejection.
This does not establish a GPU fix or production readiness. The app was left
available for the user; iPhone 17 was not involved.

**Full-app integration, 17 October:** the buffered RF288 pipeline is now wired
into a frozen snapshot of the complete app, installed as **Juggle RF Small**
(`com.juggledude.rfsmall.debug`, build `2026101702`) on both phones. This includes
the current counter rules, active-player selection, normal recording/replay,
and effects preparation/export. The shared app source remains independently
dirty; implementation and build inputs are preserved under
`artifacts/rf-full-app-20261017/source/`, with staging/integration/validation
helpers in `benchmarks/rf-full-app/`. This is a development candidate.

Both installations contain the same RF288 FP16 model and no YOLO model. The
iPhone 11 uses CPU after GPU model loading fails; the iPhone 17 uses CPU+GPU.
The policy has one RF worker, a 12 Hz RF cap, 30 fps tracking/counter analysis,
and a 200 ms buffer. It does not yet choose a profile from measured device speed
or reduce analysis cadence in response to heat. Live masks keep exact exposure
identity; replay rebuilds dense masks from saved pixels without changing counts.

On the same 30-second development clip, both phones emitted **22 touches**,
with matched contact timestamps at most 34 ms apart and no tracking overflow.
RF prediction medians were **65.2 ms on iPhone 11** and **23.0 ms on iPhone 17**;
counter-emission latency medians were 594 ms and 476 ms respectively. These are
processing/emission measurements, not display-latency or accuracy measurements.
The three-minute iPhone 11 replay processed all 5,372 admitted frames, emitted
132 touches, peaked at 12/32 queued counter frames, and completed without queue
overflow or critical heat. It reached serious thermal state after about 69 s.
The iPhone 17 three-minute run processed all 5,374 admitted frames, also emitted
132 touches, peaked at 7/32 queued counter frames, and stayed at nominal thermal
state. However, only 125 events match across phones within 150 ms: each phone
has seven unmatched emissions. Matching totals do not establish equivalent
counting. The iPhone 17 counts the contact near 103.51 s missed by iPhone 11;
compare their saved observations and tracking continuity next.

Actual short camera recordings on both phones averaged about 59.9 fps with no
writer drops or replaced analysis frames. UI checks passed camera opening,
front/rear switching, recording, replay, reopening, effect selection and saving
to Photos. Counter-only, fire, neon and gold exports completed on both phones;
selected output stills were checked for alignment and counts stayed unchanged.
One existing one-second video-only test failed its 60 +/-1 fps assertion on
iPhone 11 (51.43/57.19 fps). A separate ten-second front/rear test passed at
59.7/59.6 fps with no writer drops; the original startup test remains a failure.

This is not release qualification or an accuracy improvement claim. Compared
with the earlier 130-count manual prototype, 125 emissions match within 150 ms,
five earlier emissions are missing and seven new emissions appear. A previously
reviewed real contact near 103.48 s is now rejected as `trackLost`; tracking and
contact continuity remain the next accuracy work. The earlier 5.2/5.6 s misses
are counted in this candidate, but the entire clip has not been labelled.
Long replay does not exercise simultaneous camera/writer load; fresh live
juggling, distant/outdoor scenes and multi-person trials remain necessary.

The [full-app integration report](benchmarks/touch-counting/rf-full-app-integration-20261017.json)
records phone results, source/model hashes, build lineage, failed attempts and
test scope; it is mirrored byte-for-byte in the lab. Raw traces, videos, exports,
screenshots, XCTest bundles and immutable final provenance are retained in
`artifacts/rf-full-app-20261017/`. The initial diagnostic JSON crash was fixed
and covered by regression tests. iPhone 17 UI tests required attaching to an
already launched app because Xcode's target-relaunch operation failed.

**Owner's effects follow-up, 17 October:** two new iPhone 17 recordings (23.6 s,
8 app-counted touches; 29.6 s, 29 touches) and the saved fire export reveal a
real effects regression. Video delivery remains near 60 fps with zero writer
drops and no sustained source-frame gaps after startup. The live ball track
does lose visible moving balls, including about 5.55–5.78 s in the first clip
and 15.31–15.54 s in the second. These exceed the effect sampler's 120 ms
interpolation limit, making fire disappear and return when tracking recovers.
Source identity and archived track timestamps differ by less than 1 ms.

Normal fire preview and export only request fresh visual preparation when a
replacement ball skin is selected. Fire with the original ball therefore uses
the incomplete live track. The earlier integration harness explicitly prepared
every export and used a prepared UI fixture, so its passing checks missed this
route. Fresh saved-video analysis with the **same RF288 model** recovers both
reviewed intervals; counts/touch timestamps remain unchanged. The prepared rear
session is available in the existing review entry point on iPhone 17. This is a
diagnostic comparison, not an installed normal-workflow fix or a complete visual
accuracy audit. The next change is to prepare one shared visual track for every
enabled ball-following effect, handle progress/errors in preview and export,
and exercise actual fire-only selection after recording. This adds preparation
work after recording; the live counter should remain unchanged.

See the [effects investigation](benchmarks/touch-counting/rf-effects-user-review-20261017.json),
mirrored byte-for-byte in the lab. Sources, traces, the original export, prepared
comparisons and review stills are preserved in
`artifacts/rf-effects-user-review-20261017/`.

**Effects routing fix, later on 17 October:** Juggle RF Small build
**2026101703** was installed on both phones. Every enabled ball-following effect
now requests the shared visual track, including fire with the original ball.
Replay shows preparation progress and retry errors; it keeps the source video
and counter playable while the effects prepare. Preview, download, Save & Share
and the overlay editor use the same preparation decision. RF288, all counting
and detection code, and the touch timeline are unchanged.

The real post-session editor was tested with the owner's original 29.6-second
video and sparse live track, without a supplied visual track or cached analysis.
iPhone 17 passed fire selection, preparation and saving to Photos. iPhone 11
exceeded the **240-second preparation limit**, reaching 93% before the test
timed out; it completed shortly afterward. An attached continuation of that
same app process then exported successfully without preparing again. The failed
timeout remains recorded. Both exports retain all 29 original touch events and
use exactly their preview's prepared track; selected stills at 15.27–15.54 s
keep fire around the visible ball. Four preparation regression checks and both
phones' record/replay/close/reopen checks passed.

First-time effects preparation on iPhone 11 remains too slow for a smooth editing
experience. Its prepared-preview screenshot reported serious thermal state
after repeated tests; the timing includes UI automation overhead and is not a
controlled cool-device benchmark. Reducing this post-recording cost is the next
performance task. This is a bounded effects fix, not a claim that every tracking
miss or release requirement is resolved.

See the [effects routing verification](benchmarks/touch-counting/rf-effects-routing-fix-20261017.json),
mirrored byte-for-byte in the lab. The exact source snapshot, signed build,
patch, failed attempts, audits and review stills are retained in
`artifacts/rf-effects-fix-20261017/`; reproducible helpers are under
`benchmarks/rf-effects-fix/`. The changes are isolated from the concurrently
modified root app source and have not been merged into that working tree.

**Selective effects preparation, final test on 17 October:** Juggle RF Small
build **2026101707** is installed on both phones. Original-ball effects now reuse
compatible recorded positions and ask the same RF288 model for fresh positions
in gaps, weak detections, drifting tracker runs and likely sharp turns. An empty
repair can retry two nearby frames. This avoids generating replacement masks
for fire/trails; replacement skins and incompatible source evidence retain the
full preparation path. The rendering gap limit, live counter, model weights,
input resolution and touch timestamps are unchanged.

Fresh comparisons used the same 23.6 s, 29.6 s and **87.8 s** recordings on both
phones, preserving their original 8, 29 and 79 touch events. For the long clip:

| Device | Effects preparation | Additional fire export |
| --- | ---: | ---: |
| iPhone 11 Pro Max | 62.4 s | 75.5 s |
| iPhone 17 Pro Max | 10.8 s | 10.3 s |

The iPhone 11 warmed from nominal to serious thermal pressure during preparation.
A fresh repeat starting at serious pressure took **79.0 s**, cooled to fair,
and produced an identical position track. The iPhone 17 runs stayed nominal;
its full-preparation reference took 100.3 s. These are observed device runs,
not a controlled performance study. The older phone still has a substantial
export wait, and replacement-ball preparation remains slower.

Both normal fire-only editor/Save-to-Photos checks passed. Preview and export
used the same prepared track with unchanged touch events. Eleven preparation
regression checks passed on iPhone 11. The reviewed front/rear dropout intervals
and long-clip tracker-drift examples are repaired. Some brief edge/blur/contact
misses and offsets remain; these development clips do not establish release
accuracy. A fresh owner recording comparison is still needed.

See the [selective effects results](benchmarks/touch-counting/rf-selective-effects-20261017.json),
mirrored byte-for-byte in the lab. Signed candidate builds, rejected iterations,
source provenance, timings, UI audits and review stills are preserved under
`artifacts/rf-selective-effects-20261017/`; reproducible helpers are under
`benchmarks/rf-selective-effects/`. This remains an isolated full-app test build;
the concurrently modified root app runtime source has not been merged.

**Shared 288/384 package experiment, 17–18 October:** a separate **RF Shape Test**
app (`com.juggledude.rfshape.debug`) was installed on both phones. It combines
the existing same-checkpoint FP16 exports as `rf288` and `rf384` functions in one
Core ML package, deduplicating identical weights. The compiled asset is
**62,628,857 bytes**, versus **61,490,258 bytes** for the existing 288 asset:
only **1.14 MB extra**, not another complete model. These are model asset bytes;
App Store compression and OS compilation caches are separate. Multifunction
models require iOS 18 or later. No retraining or YOLO model was involved.

All **32 Mac original-versus-merged checks** (eight source frames, both sizes,
CPU and CPU+GPU) produced exactly equal boxes, logits and masks. On each phone,
72 paired source frames per resolution produced identical decoded candidates
between the original and merged versions. All **1,694 sampled source frames**
across the existing front, rear and long recordings were then inferred at both
sizes on both phones, with verified matching frame identities. Median isolated
inference was 69.2/131.1 ms at 288/384 on iPhone 11, and 14.7/18.5 ms on iPhone 17.
These sequential tests do not measure live camera FPS. iPhone 11 still uses the
CPU compatibility fallback; iPhone 17 uses CPU+GPU.

During the span between the original recorded first/last touches, iPhone 17 had
1/10/22 frames detected only at 384 across front/rear/long, versus 1/1/5 only at
288. Qualitative source-frame review confirms real recoveries and some tighter
boxes at 384, as well as real regressions. Much of the rear clip's whole-video
coverage increase is the resting/held ball before juggling. These are development
examples and detection-availability counts, not labelled precision/recall.

Two wall-clock-paced rear-clip replays per mode used the frozen full-app tracker
and counter at 30 fps analysis / RF cap 12 Hz. On the warm iPhone 11, 288 returned
28/27 counts with 1/1 late RF replies; 384 returned 17/20 with 14/9 late replies
and substantially fewer available tracked positions. The last 288 run skipped
two late analysis input frames; the other runs skipped none. iPhone 17 returned
31/30 counts at 288 and 29/30 at 384, with no late replies or skipped inputs.
All traces replayed exactly and no counter queue overflowed. These observed
totals are not independently labelled counting accuracy.

Additional iPhone 17 controls using the **original single-288 package** returned
32/28 counts. Repeats admitted identical source-frame times but selected different
RF inference timestamps, consistent with upstream scheduling sensitivity. This
repeatability issue is not unique to the merged package and needs attention
before automatic profile rollout. The 384 mode is a candidate for faster phones;
keep 288 for iPhone 11 live recording. Automatic calibration, profile-aware
caches and offline-effects resolution selection remain unimplemented.

The existing **Juggle RF Small 2026101707** installations were preserved and
reopened after testing. Root runtime sources were not changed. See the
[shared-resolution results](benchmarks/touch-counting/rf-shared-resolution-20261017.json)
(mirrored in the lab), [paired frame examples](artifacts/rf-shared-resolution-20261017/review/key-frames.jpg),
and full evidence under `artifacts/rf-shared-resolution-20261017/`. Helpers live
under `benchmarks/rf-shared-resolution/`; the new model package and export
provenance are in the lab's `runs/v2/20261017-rfdetr-shared-resolution-001/`.

**Power Shot / Ball Distance resolution validation, 18 October:** 36 valid native
phone runs compared the same RF-DETR FP16 checkpoint at 288 and 384 on nine
previously reviewed recordings: seven outdoor shots, a fast airborne shot, and
a conditional two-metre rolling-marker control. Each phone/resolution evaluated
the same 3,031 source frames (12,124 evaluations total), at up to 30 Hz and the
unchanged 0.40 threshold. This is a sequential detector comparison, not a live
camera, final renderer, or end-to-end measurement qualification. No training,
threshold tuning, production model replacement, or automatic routing was added.

The result **does not support a blanket replacement of 384 with 288**. On the
25 previously reviewed fast-flight frames, 288 matched the approximate ball
centre on 7 frames on iPhone 11 and 6 on iPhone 17; 384 matched 11 on each.
The counts are unchanged under either a 7- or 14-pixel centre tolerance.
Both sizes detected the ball on all 15 sampled marker frames with reviewed
silhouettes. Later, after 11 seconds in that recording, 288 produced detections
on only 11/107 frames, versus 107/107 on iPhone 11 and 106/107 on iPhone 17 at 384.
Selected original-frame review confirms real losses of the visible ball near
the wall. Outdoor availability was mostly similar, but 384-only observations
outnumbered 288-only observations 55:6 on iPhone 11 and 58:7 on iPhone 17 across
2,384 paired outdoor frames. These availability totals are not labelled accuracy.
Forty selected source stills were reviewed, including real recoveries at 384 and
a real 288-only recovery: outdoor `cf8c6779`, frame 604. Neither size solves all
fast-flight misses.

Pooled median model inference was 80.9/151.0 ms at 288/384 on iPhone 11 (CPU
fallback) and 10.4/16.6 ms on iPhone 17 (CPU+GPU). Median preprocessing + model +
decoding was 88.6/160.0 ms and 13.2/19.8 ms respectively. These exclude camera,
rendering, and effects export; diagnostic run elapsed times additionally include
saving a first-input PNG. The outdoor iPhone 11 runs included serious heat and
completed without a critical-thermal abort. Retain the separate live-juggling
288 candidate; 384 is the preferred candidate for saved-shot analysis, with its
processing-time cost. Full effects routing/composition validation remains next.

The outdoor originals store sideways sensor pixels. Two preliminary diagnostic
attempts (raw orientation and a directly applied display transform) were excluded.
The separate **RF Shot Test** app uses the production `CIImage.oriented(.right)`
operation, verified against a saved native input image and actual detected box.
Correctly oriented fast-shot/marker runs from **RF Shape Test** were retained;
the model assets match byte-for-byte. The earlier juggling inputs have identity
orientation and are unaffected. Original videos and the main runtime sources
were preserved; **Juggle RF Small 2026101707** was reopened on both phones.

The outdoor clips have no independent measured endpoints. The marker analysis
remains conditional on reviewed silhouettes and camera/ground assumptions; it
does not validate airborne shot distance or launch speed. A fresh independent
field session remains necessary for measurement claims. See the compact
[shot-resolution report](benchmarks/power-shot/rf-shot-resolution-20261018.json)
(mirrored in the lab), [reviewed examples](artifacts/rf-shot-native-20261018/review/key-frames.jpg),
and evidence under `artifacts/rf-shot-native-20261018/`. Reproduction helpers are
under `benchmarks/rf-shot-resolution/`; excluded attempts remain in their
separate artifact directories, named in the report.

**Ball replacement comparison, 18 October:** the installed **Juggle RF Small
2026101707** was tested with the same 29.6-second rear recording and its unchanged
29 touch events. Four fresh full-mask preparations used explicit standalone
RF288/RF384 debug overrides, followed by native gold replacement exports. The
application, installed default model, thresholds and main runtime were unchanged.

384 improves replacement continuity on this clip, but does not eliminate flicker.
During 6.0–25.5 s, current-frame outlines were available on **1,090/1,166** export
frames at 288 versus **1,149/1,166** at 384 on iPhone 11; iPhone 17 produced
**1,092** versus **1,150**. These are outline-availability counts, not labelled
accuracy. Forty selected comparisons confirm the original ball reappearing at
288 while 384 keeps the replacement at 7.098, 10.070 and 15.397–15.414 s. There
are also 288-only recoveries, both-size misses, and remaining outline/blur errors
around kicks. All four exports share 1,770 identical composition timestamps;
their difference from the source's 1,773 variable-timestamp frames is common
resampling, not a resolution-dependent frame-drop result.

Approximate full-outline preparation times were **141 s / 496 s** at 288/384
on iPhone 11 and **27 s / 42 s** on iPhone 17. The iPhone 11 384 run started at
fair thermal pressure and reached serious; these are observed runs, not a
controlled cool-device speed ratio. Its later rendering also overlapped failed
profiling attempts, so that export timer is not a clean benchmark.

Prepared-track selection and Save-to-Photos checks exported replacement on both
phones with the same source, prepared track and 29 original touch events.
The iPhone 17 normal export is gold-only. The iPhone 11 exported **gold + Galaxy**
despite the automation tapping `effect-picker-none`; that selection mismatch
remains unresolved and is not counted as a clean gold-only UI pass. Initial
overlapping iPhone 11 test-runner attempts were excluded and retried sequentially.
The separate native comparison exports are gold-only on both phones.

The existing debug size override shares its old cache signature/display label.
Model metadata and launch arguments establish the tested resolution. Fresh 288
cache data was restored and verified on iPhone 11 after its 384 run; iPhone 17
finished on 288. Any production resolution routing still needs profile-aware
caches. The next candidate is selective 384 repair of missing/weak 288 replacement
outlines on slower phones; it has not been implemented or validated. One indoor
clip and one skin do not establish release accuracy or spin quality.

See the [ball replacement report](benchmarks/touch-counting/rf-ball-replacement-20261018.json)
(mirrored in the lab), [balanced review examples](artifacts/rf-ball-replacement-20261018/review/key-frames.jpg),
and native exports/audits under `artifacts/rf-ball-replacement-20261018/`.
Reproduction helpers are under `benchmarks/rf-ball-replacement/`.

**Local device-resolution checkpoint, 18 October:** **RF Device Profile
2026101801** (`com.juggledude.rfprofile.debug`) now selects the shared RF-DETR
function entirely on-device. Exact known iPhone 14-and-newer model identifiers
use **384**, while older, SE and unrecognized models use **288**. The central
table is [RFDeviceProfile.swift](benchmarks/rf-local-profile/RFDeviceProfile.swift).
Live counting and saved-video/effects analysis use the same fixed local choice;
there is no onboarding preference or remote controller. Function/size/graph-aware
cache identities prevent cross-resolution reuse, and external study caches are
isolated. Camera recording dimensions and counter rules are unchanged.

Physical-device tests confirmed automatic **288 / CPU fallback** on iPhone 11
Pro Max and **384 / CPU+GPU** on iPhone 17 Pro Max. **52 targeted tests passed
on each phone**, with zero skips/failures. Complete 29.6-second paced replays
finished with exact counter-trace replay, zero late RF replies, zero input skips
and no queue overflow. Observed counts were 31/29, not labelled accuracy. An
initial iPhone 17 run stalled for about 43 seconds in inference and stopped at
20.842 seconds of source; it is retained as incomplete, with cause unresolved.
Its full retry passed, and the runner now rejects incomplete source intervals.

Debug and unsigned Release builds passed; both contain the same verified shared
model. The original RF Small 1707 installations remain intact. This is a separate
checkpoint based on the tested 1707 pipeline: main-app consolidation and TestFlight
upload are still pending. The iPhone 14 threshold needs sustained device validation
before release qualification. See the [checkpoint guide and source patch](benchmarks/rf-local-profile/README.md)
and [results](benchmarks/touch-counting/rf-local-profile-20261018.json).

The touch experiment shows contact decisions live and in the in-app replay:
red **Hand touch** when the hand verifier confirms handling, amber rejection
reasons (including the body filter), and green accepted touches. Circles mark
the candidate contact position. The body gate may reject before the hand gate;
debug diagnostics inspect those candidates too, retaining the actual rejecting
gate. These optional numeric annotations are saved with counter traces and do
not change counting decisions. They are not burned into exported videos.
The debug app uses candidate-contact pose checks for counting. Live preview and
replay do not run a separate skeleton-visualization worker.

For a physical-device comparison with frozen detections, the touch debug build
also accepts `--touch-contact-replay <Documents-folder>`. Stage `config.json`
with `clips: [{id, video, trace}]` (all basenames), original portrait recordings
and their `CounterTraceArchive` files there. The harness validates source hashes
and frame timestamps, then writes `id-before.plist` / `id-after.plist` and a
`status.txt`, comparing the previous head/knee/foot policy against the clear-hands policy
without editing session history. Numeric pose evidence is saved alongside each run. Use `comparison: "handling"`
to compare the same body/ground policy with sustained-grip checks off/on.
`comparison: "poseConfidence"` compares v4/v5 with handling enabled in both.
Optional `poseAuditFrames: [analysisFrameIndex, ...]` exports raw normal/mirrored
Vision landmarks for explicit diagnosis only; these alternate poses never enter
the counting rules or the live camera path.
`kicklabTests/Fixtures/handling-device-contacts.json` contains a small manually
reviewed development benchmark, including pickup/held events and genuine feet,
head and chest contacts. The ground-bounce label is a known remaining false
count and is deliberately not relabelled as handling. The companion
`handling-benchmark-labels.json` also includes three genuine misses rejected by
other gates. Run `scripts/score-touch-benchmark.py LABELS SOURCE_ARCHIVE
BEFORE_TRACE AFTER_TRACE` to score only those labelled events and list every
changed count; it requires identical frozen detections and source timing.
On the 2026-10-12 recording, the 24 labelled events retain 18/21 genuine contacts
and reduce false counts from 3 to 1 (pickup at 144.558 s and held movement at
163.395 s removed). Three genuine misses and the ground bounce at 157.694 s
remain. Across ten frozen-device replays, these are the only changed events;
the long regression remains 171 and repeated ground bounces remain zero.
This is regression data from the tuning recording, not independent accuracy
validation. Sustained live FPS and performance on older phones remain unmeasured.

The shared counter checks possible floor contact before any body-part approval.
The bottom of a person box is a rough floor proxy, not a detected ground plane.
The original centre-based ground gate remains. The additional observed-ball-edge
gate uses a margin scaled to the ball, capped at the original tolerance. It
rejects only with supporting evidence: the impact reaches the bottom image
boundary, or both confidently observed feet stay stationary across the contact
window. A box overlap with uncertain foot evidence alone cannot reject a touch.
Observed foot motion and ball approach/separation can still recover a genuine
low kick; the hand veto follows. This applies to live capture and counted imports
in every app configuration. These 2D estimates do not guarantee ground detection
for every perspective, occlusion or moving-foot bounce.
A separate planted-feet check covers fully visible bounces above the box's
estimated floor. It requires a clear ball approach and confident observations of
both feet spanning at least 200 ms before contact and a view afterward. Both feet
must remain stable in image and pelvis-relative coordinates. A short median
filter tolerates isolated pose jitter, while a raw-motion limit preserves real
movement. Missing views, uncertain joints and a ball staying close to the feet
do not establish a floor bounce. This check is independent of the strict ball-size
consistency needed to prove a kick, so motion blur cannot silently skip it.
It uses only buffered candidate-contact images (at most 29 small images total),
without adding lookahead or running pose inference on every preview frame.
The continuity check can also use a moderately confident, actually observed ankle
when its immediately adjacent confident views agree with that position. It never
fills missing frames or missing joints, and still requires seven confident views.
Older observations before a gap do not invalidate a later complete, continuous
200 ms approach. The foot-motion and ground thresholds remain unchanged.
New traces use `counter-v9`; saved `counter-v5` through `counter-v8` traces replay their original rules.
Analysis caches are invalidated for the new counter. The device replay harness
accepts `comparison: "ground"` in its config to compare v7/v8 ground checks
while holding the current body policy constant.
Use `comparison: "groundContinuity"` to compare v8/v9 continuity checks with
the same body policy and frozen detections.
Use `comparison: "footMotion"` to compare the moving-foot recovery with the same
v9 ground policy. Every replay still verifies its trace and bounded image cache.
Use `comparison: "poseContinuity"` to compare the strict moving-foot path with its
continuity fallback. `afterOnly: true` resumes an after pass when a completed
baseline already exists; always check `status.txt` for `DONE` before reading results.
Imported traces replay through the same 720-pixel video composition and clock as
import analysis; captured traces replay their original source frames.

Release ships only that tracking model. Optional person-cutout refinement, unused images,
and offline ball-print sources are backed up outside the app target in
`resource-backups/20261010-shipping-cleanup/` (see its manifest and README.txt).
The model backup is local and remains ignored by Git. All 14 runtime ball materials
remain bundled; material-generation instructions are in
`design/ball-collection-01/material-sources/README.md`.

Local release media, recording investigations, offline material reference images
and resource backups are preserved on this Mac and excluded from Git. Their exact
paths are listed in `.gitignore`; they are not included in a fresh clone. The
material-generation README and bundled runtime materials remain tracked.

Launch validation:

```sh
scripts/validate-launch.sh backend
scripts/validate-launch.sh release
TEST_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_ID' scripts/validate-launch.sh logic
```

The backend lane requires PostgreSQL command-line tools and Deno (`DENO_BIN` can specify
its path). It creates a disposable local database. Results and logs default to
`/tmp/juggledude-launch-validation`; set `VALIDATION_DIR` to override. Failed checks and
skipped required tests are not a pass. Run the relevant lane after each change.

The automated checks do not replace recording, phone-lock/background, Photos playback,
low-storage, purchase/restore and account-deletion checks on the actual release candidate.
See `docs/code-audit-20261010.md` for findings, implemented safeguards and remaining gates.

The 10 October backend changes were applied through the Supabase Management API. The
existing project has no CLI migration-history table: establish its migration baseline
before using `supabase db push` against that project. Do not replay the initial migrations
against live tables. Deletion reconciliation is deployed separately; its scheduled job
is defined in `supabase/ops/schedule-deletion-recovery.sql`, with a scoped secret in Vault
and Edge Function secrets. Never embed a service-role key in that scheduled HTTP request.
