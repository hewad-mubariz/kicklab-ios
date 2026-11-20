# Virtual Penalties projector trial

Virtual Penalties is available in the **BallDetectionDebug** app's wall-games
selector alongside all nine wall games: Clear the Wall, Brick Blast, Memory
Strike, Meteor Defence, Cross & Circle, Goal Duel, Four in a Row, Territory
Duel and Copy My Shot. Open **Wall targets → Virtual Penalties**. Goal Duel is
still the two-player robot game; Virtual Penalties is the realistic goalkeeper.

## Shared build baseline

The wall-games and goalkeeper branches were combined on 20 October 2026.
Both `codex/brick-blast` and `codex/keeper-wall-games` include this merge. Build
future changes from this combined history so installing either chat's build
retains the shared menu entries. Both use the same debug bundle identifier,
`com.juggledude.balldetection.debug`; installing an older branch replaces the
whole app binary and can make newer menu entries disappear.

The nine wall games retain their one-hold setup. Virtual Penalties retains its
separate guided goal setup and existing live-save policy. Recalibrate when
switching between these modes. The integrated keeper assets and ball skins are
unchanged by this menu merge.

## Goal challenges · 21 October 2026

**Wall targets → Top Bins / Find the Space** opens two real-ball games in the
same debug app. They use the existing goal, single-centre-hold calibration and confirmed
wall-contact detector. They bypass keeper prediction, virtual footballs and
replays. The goalkeeper's existing live-save behaviour remains unchanged.
No new two-player penalty mode was added.

- **Top Bins:** five confirmed shots; upper circles score 100, lower circles 50.
  The measured ball centre must be inside the circle. Other measured wall hits
  consume a shot for zero points. Circle rendering and hit tests share the same
  goal geometry, including Goal height and the external display aspect ratio.
- **Find the Space:** five shots; the robot's full-height amber shield moves
  slowly from side to side. A ball footprint wholly inside a green opening
  scores 100. The robot has only translation and a small idle bob.
- One score acknowledgement per contact, with 1.6 seconds after confirmation
  for the rebound to leave. A fifth contact shows the score; **New five-shot
  round** reuses calibration while the phone and projector remain fixed.
  Pause preserves the score; moving the phone or changing the display clears
  calibration and the round. A lost/unconfirmed ball does not consume a shot.
- Find the Space evaluates the shield at `contactTime − displayDelay`, not at
  rebound confirmation. The default for these wireless trials is 250 ms.
  This remains an estimate of the projector delay, not a measured guarantee.
  Pause before adjusting it. The deterministic eight-second path is shared by
  rendering and scoring.

The robot is Quaternius' [Animated Robot](https://quaternius.com/packs/animatedrobot.html),
CC0-1.0. Source, licence and converted static USDZ are documented in
`GoalChallengeAssets.bundle`; no purchase, sign-in or subscription is needed.
The bundled prop is approximately 119 KiB. Conversion source lives in
`experiments/GoalChallenges/Tools/build_robot.py`.

Round contact times, display times, coordinates and results are saved to
`Documents/GoalChallenges/latest-round.json` and the beginning/end metadata of
**Record 20-second test**. Device launch shortcuts are `--top-bins` and
`--find-space`; both start uncalibrated. Simulator-only visual QA can add
`--penalty-setup-preview=challenge` or `--penalty-setup-preview=0` (hold progress).

Validation: simulator and signed iPhone builds; 59 goal-rule checks; 88 physical
calibration/keeper regression checks (including recorded approaches). Simulator
menu navigation, 100/50 point scores, the five-shot result and reset were also
exercised. Real projected ring detection and contact scoring still require the
next physical-ball recording.

### Simpler goal calibration

Goal setup now keeps the four-marker automatic corner search and asks for only
one ball hold in the centre. The former four edge holds did not refine the
corner mapping or supply the final wall-depth measurement, so removing them
avoids the low-corner reach without changing the mapping or depth calculation.
The 900 ms marker-clear interval, evidence-based hold duration and size gate
remain. Progress stays around the held ball.
This applies to Top Bins, Find the Space and Virtual Penalties, including the
manual corner fallback.

Goal calibration now uses the wall games' detailed board crop and 15 fps
reference cadence during focus/hold, without running hand/body pose for a
stationary held ball. Full-frame physical-shot tracking resumes afterwards.
Previously the goal corners never reached the camera crop, leaving the hold
on full-frame detection. The shared `WallBallHold` now supplies both paths'
confidence/aspect checks, median-based stability, 25% size tolerance and
500 ms loss grace. One bad or missing box retains progress. Goal setup still
requires 1.4 seconds of consecutive measured-frame evidence (18 samples
minimum); missing/outlier frames cannot add time. Its ring-size/location gate
filters candidates before selection, so the projected halo cannot displace a
valid real-ball candidate. Telemetry reports `goal-corners-shared-wall-hold-v3`.

The latest saved clip inspected was `2026-10-21_14-14-19`, a 132.5-second
Cross & Circle recording. Its single centre hold completes; it does not contain
the reported bottom-corner goal difficulty. A later saved goal camera snapshot
at 14:23 was on hold 2 of 5. Evidence is under
`experiments/GoalChallenges/Review/setup-test-2026-10-21_14-14-19` and
`single-hold-inspection.json`. All 88 physical regression checks and the signed
iPhone/simulator builds pass. The simplified goal flow needs a new wall trial.

The later saved goal snapshot completed its centre hold at diameter 0.03246,
but still used the old full-frame path. New recordings at 15:06:25 (Brick Blast)
and 15:09:25 (Cross & Circle) use the ordinary wall-game setup. The latter's
centre hold completes at 29.04469 seconds; replaying its measured observations
through the shared collector reproduces that time and diameter (0.03250).
The new goal path passes 94 physical regression checks, three existing wall
reference scenarios run standalone, and device/simulator builds. It is
installed and launched in Top Bins. Improved physical responsiveness still
needs a new centre-hold trial; offline tests cannot establish projector latency.

### iPhone 11 hit-detection review

The connected iPhone 11 Pro Max selects the existing 288-square RF function
and CPU compatibility backend, as in the prior juggling device profile. Its
`2026-10-21_15-33-25` Cross & Circle recording runs at median 6.48 analysis fps
during gameplay (158 ms inference), with normal temperature. In the measured
play interval, 640 frames invoke 640 board passes plus 555 full-frame passes.
Four contacts reach the rules and two score. One other contact is borderline;
another arrives during the turn handover, whose active clock paused for marker
loss. Other attempts lack enough accepted trajectory evidence.

A paired offline test uses the exact bundled RF functions and normalization
on the same 50 compressed recorded board crops. At the wall detector's 0.20
threshold, 288 reports a ball on 27 frames and 384 on 30: seven gains and four
losses. This is a raw-detection comparison, not labelled accuracy or an iPhone
throughput benchmark; it does not justify switching this phone to 384.

`cpu-one-model-pass-v1` keeps the 288 profile and schedules room/person recovery
on the next fresh frame when using the CPU backend, instead of running two
models on one old frame. The GPU path retains immediate fallback. No contact,
release, calibration or scoring thresholds change. Model input size, compute
backend and search policy are saved with recordings; startup diagnostics also
include the accelerated-load error. The scheduler passes 62 checks, and signed
device and simulator builds pass. New physical hit-rate/timing validation is
still required. Evidence and the paired comparison are under
`experiments/GoalChallenges/Review/iphone11-responsiveness`.

#### CPU ball-follow trial after the two zero-hit recordings

The 16:03:46 and 16:06:17 recordings confirm zero physical contacts and scores,
despite analysis improving to medians of 12.71 and 12.95 fps. Board mapping
checks are below one source pixel, scoring is allowed on over 96% of gameplay
frames, all measured balls have clear hands, and temperature remains normal.
The moving ball is frequently lost at contact or rebound in the dark image.

`measured-cpu-follow-crop-v2` keeps the 288 input and one model pass per frame.
During ordinary CPU wall gameplay it inspects a bounded region around the
recent measured ball, with room for a reversal. A crop miss retains this view
for at most 200 ms, then returns to board/room acquisition. Predicted crop
locations never become observations. Centre calibration, GPU gameplay and
physical keeper inspection keep their existing camera views. Recording source
3 identifies a CPU follow crop.

`v11-sparse-depth-consistency` extends measured approach history to 400 ms only
on the CPU path below 20 fps. It rejects an early apparent size minimum when a
later almost-equal depth measurement (within 6%, over 220 ms) contradicts its
target. A later minimum must satisfy all contact rules itself. Meaningful
rebound growth, held-ball rejection, alignment gating, boundary uncertainty
and game turn rules are retained. An older fast-rebound fixture caught an
over-broad initial check; that regression now passes in both paths.

Full gameplay reprocessing uses 1,547 saved frames, causal production crops,
the recorded alignment gates/geometry, fresh Vision pose, and current contact
rules. It recovers four contacts inside targets and four neutral contacts
(three borderline, one outside). The earlier clip hits the same cell twice,
so those are not two distinct Cross & Circle claims. Frame review supports
the recovered target locations. Held/unknown-hand negative controls produce
no contacts. This is compressed-video replay on Mac, not a phone benchmark;
many attempts still lack sufficient measured evidence. No claim of reliable
live hit rate or lower projector latency is made.

All 105 selected XCTest checks pass (87 tracking/alignment/contact tests and
18 party-game rules/model tests), and the signed iPhone 11 build passes.
Evidence, candidate experiments and final contact checks are in
`experiments/GoalChallenges/Review/iphone11-missed-shots`. Reproduce model
replay with `Tools/replay_wall_follow.swift`; recheck cached model measurements
and negative controls with `Tools/recheck_wall_contacts.swift`. The six focused
regressions and their recorded fixture live in `WallFollowTrackingTests.swift`
and `Fixtures/wall-cpu-follow-shots.json`.

For the live trial, recalibrate and record five gentle shots at **different
empty squares**, waiting for the displayed turn. Repeated centre shots cannot
all score in Cross & Circle because an occupied cell is deliberately rejected.
The signed update is installed on the connected iPhone 11 Pro Max. iOS rejected
the launch because the device is locked; unlocking was requested. Installation
and launch diagnostics are saved with `implementation-validation.json` in the
review folder. A new physical recording is still required.

#### October 22: incoming-ball acquisition and measured bounce selection

Pulled the three newest sessions, `10-29-05`, `10-30-10` and `10-32-10`,
plus the preceding `10-26-51` reference. All use the intended 288 CPU model
and follow crops. The newest three have 4/3/7 physical contacts and 2/2/4
game claims. Median analysis cadence is 12.53/10.85/11.18 fps. Mapping checks
are within 1.12/0.91/0.93 camera pixels. The last clip reaches serious thermal
state, but substantial misses also occur in the nominal-temperature clips.

Frame review shows several visible incoming balls receiving their first model
measurement only at or after the rebound. Other trajectories break because
the contact stage permits less movement between sparse frames than the ball
association stage. Finally, a flat depth minimum with a few pixels of box-size
noise can select an outgoing frame in a different square. These are separate
from intentional grid-boundary, occupied-cell and turn-handover rejections.

`measured-cpu-motion-acquisition-v3` uses two previous low-resolution luminance
frames to propose a model crop around current motion. The model still runs
once per analysed frame; motion never supplies a ball observation. A new model
box must overlap the moving region and meet the calibrated minimum size.
Scene-wide changes and frame discontinuities discard the hint. Existing ball
following, calibration and accelerated-device paths remain in place. Source
4 identifies motion-guided model boxes and `motionSearch` records its cost.

`v12-sparse-measured-reversal` resolves near-equal depth measurements using an
observed direction reversal, keeping the contact at a real sampled position.
The CPU sparse path allows two ball diameters of travel per observed frame,
consistent with association. It also refuses to create a new contact more
than 800 ms old when a cadence change joins previously split tracks. Release,
approach, wall-depth, rebound and boundary requirements remain enforced.

Causal Mac replay on the same compressed frames changes physical contact
counts from 3/5/4 to 6/13/17, including neutral boundary/outside contacts; the
candidate has 2/9/9 target contacts, with repeated cells included. These are
neither game scores nor measured live hit-rate percentages. The final latest
clip replay using the production search scheduling confirms 17 contacts.
Nine recovered target examples were checked against neighbouring video frames.
Held/unknown-hand controls produce zero contacts. The brightness-gain experiment
was rejected and is not enabled.

All 111 selected XCTest checks pass, including new recorded-contact and motion
search regressions. The signed build is installed and launched in Cross & Circle
on the iPhone 11 Pro Max; startup confirms successful 288 CPU warm-up. The
iPhone 17 was not updated. Evidence and installation logs are in
`experiments/GoalChallenges/Review/iphone11-misses-oct22`, especially
`investigation.json`, `final-replay-latest.json` and the recovered-contact strips.
Reproduce with `Tools/replay_wall_motion.swift` and
`Tools/recheck_wall_contacts.swift`. This improves the tested evidence paths,
but some recorded shots still miss and live reliability remains unverified.


#### October 22: late-session and outer-square misses

The newest recording, `11-32-28` (223 seconds), still runs the intended 288 CPU
model. Analysis falls from about 13.8 to 10.4 fps while reported thermal state
remains nominal. Model time rises from roughly 68 to 88 ms; motion search costs
about 1.4–1.9 ms. The recording does not establish the cause of the model-time
increase. Mapping error is 1.47 camera pixels. Four target contacts were
accepted live, in cells 2, 5, 8 and 6.

Two implementation problems amplify the slower cadence. Track links were
recomputed using the latest global fps, so later cadence changes could break
previously connected approach/return evidence. A fixed minimum of three
approach samples also discards shots with only one measured incoming frame
plus contact. Finally, calibration used a 620×481 board crop while gameplay
usually used a 384×384 follow crop. Paired inference on the same steady held
ball estimates a median of 38.1 pixels in the wide view versus 42.2 in the
closer view. The saved live reference was 38.24 pixels. This scale mismatch
puts several real wall contacts above the wall-depth gate.

`v13-stable-cadence-confirmed-return` retains the cadence at each observed
track edge, accounts for the larger measured diameter on a growing return,
and bounds sparse gaps so a disappeared ball cannot acquire rebound evidence
from a later floor bounce. A previously rejected reversal no longer hides a
later depth minimum. A short approach needs >=20% measured shrink and three
released return samples, including two with >=20% regrowth. No predicted
position or inferred missing sample is used as contact evidence. Existing
held-ball, boundary, stale-contact and calibration protections remain.

CPU centre calibration now uses the same source-pixel scale as wall-depth
following (`single-centre-detail-v2`), retaining the single ring and hold
interaction. The model input remains 288 pixels. Recalibration is required
for the new measured reference; existing saved diameters are not multiplied.

Rechecking the original live detections with the newly measured reference
finds 11 physical contacts, including 9 target contacts (one in each square)
and 2 neutral boundary contacts, versus 4 original target contacts. The target
locations were reviewed in video. This is a counterfactual offline comparison,
not live accuracy or a replay of turn-dependent game scores. It still misses
other attempts. Held and unknown-hand controls give zero contacts. The full
old calibration clip ends as the old collector completes, just before the
new crop's collector would have enough stable elapsed time; the 42.2-pixel
comparison is a median of actual held frames, not an asserted live calibration.

All 115 selected tracking, alignment, contact and game-rule tests pass, including
nine recorded square examples and a check that a short approach cannot score
without three actual return measurements. The signed device build succeeds and is installed and launched in Cross & Circle
on the iPhone 11 Pro Max. Re-run the single centre hold before testing.
Evidence is in `experiments/GoalChallenges/Review/iphone11-edge-review`; the
new fixture is `kicklabTests/Fixtures/wall-sparse-cadence.json`.


#### October 22, 12:46 live trial: side shots remain unresolved

Pulled and reviewed `12-46-04` (214.45 seconds). The phone confirms v13,
`single-centre-detail-v2`, and the 288 CPU model. It records nine physical
contacts, five non-neutral target contacts, and only three game awards:
cells 5, 8 and 2, all in the centre column. The previous offline nine-square
comparison did **not** generalize to this live trial.

The saved centre diameter is 37.66 pixels, giving a 47.07-pixel wall-size
limit. There are 22 `wall_size` decisions, including side trajectories with
52–56-pixel measured minima. This does not by itself prove the true wall
reference is wrong: sparse measurements can miss the instant of maximum
depth, and hand occlusion/model box bias are additional uncertainties.
Simply multiplying the saved reference is not a validated fix.

Right-side acquisition is a separate problem. Around 124.286 and 124.386 s
the real ball is visible on approach and at the top-right square; live
inference reports no ball. Its first live box is at 124.470 s on the return.
Several other right shots also begin their measured track at/after contact.
Compressed-video Mac replay additionally exposes first-pair association
rejections: without a velocity estimate, real movement can exceed the fixed
two-diameter or one-diameter weak-box bounds. That replay is not an exact
replica of on-phone candidates.

Mapping verification passes with 2.17-pixel maximum error. Analysis medians
are 13.13 fps (42–90 s), 10.85 (90–140 s), and 10.46 (140–214 s), with nominal
reported thermal state throughout. Alignment permits scoring on ~93–94%
of gameplay frames; pauses and boundary decisions contribute to individual
misses but do not account for the overall side-column failure.

A diagnostic-only 45.2-pixel reference produces nine target contacts instead
of five, but still no right-column contacts. This arbitrary reference was
not deployed. No product code or installed build changed in this review.
A complete fix needs earlier ball acquisition and measured motion between
slow model passes, with contact timing/position uncertainty handled across
the bounce. Validate it against the missed-side sequences before another
live success claim. Evidence is in
`experiments/GoalChallenges/Review/iphone11-side-review/investigation.json`
and `right-shot-missed-contact.jpg`.

#### October 22: v14 — retain and corroborate frames between CPU detections

Applied after the 12:46 side-shot investigation, in the keeper-lab worktree.
Ordinary CPU wall games now keep up to six chronological camera frames while
RF inference runs. The last frame of each batch runs RF; preceding frames use
short-lived, multiscale image correlation. Owned camera copies are limited to
14 buffers so capture does not retain an unbounded queue or exhaust the camera
surface pool. The baseline newest-frame path remains for setup and other modes.

Pixel tracking uses actual image matches, not interpolated positions. It expires
on a >75 ms frame gap or >180 ms since a model seed, rejects weak/ambiguous
texture matches (correlation <0.80), and accepts intermediate contact evidence
only when the next independent RF box agrees within 0.30 ball diameters and
0.85–1.18 size ratio. Missing/weak model confirmation discards that batch's
pixel evidence. A measured current match also places the next detailed model
crop and helps associate a weak model box without manufacturing an observation.
Motion acquisition sees intervening frames before the first model seed.

Scoring still uses the calibrated wall-depth, release, rebound and border rules.
The CPU track-gap allowance now has a 250 ms absolute ceiling so lower model
cadence cannot join a missed wall contact to a later floor bounce. Historical
alignment gates are retained for buffered observations. Pixel-only frames never
award immediately; confirmed evidence is consumed in timestamp order.

Recordings include the intermediate frames. Source 5 is a provisional pixel
match and its score is image correlation, **not** RF confidence. `pixelBridges`
in session.json identifies which ranges were admitted after model confirmation.
`inference_ran=0` distinguishes intermediate frames; runtime stage
`pixelTracking` measures their work. Policy: `cpu-buffered-pixel-bridges-v4`;
impact rules: `v14-model-confirmed-pixel-bridges`. The model remains rf288 CPU.

Validation: 123 simulator checks pass, including measured scale/position,
ambiguous twins, expiry, bounded ordering, held/unknown/no-return negatives,
previous recorded contacts and a slow-CPU floor-bounce regression. Device build
succeeds. A replay of 553 actual higher-rate frames on the connected iPhone 11
Pro Max measured active pixel work at 2.96 ms median, 8.06 ms p95 (9.26 ms max).
Fourteen admitted intermediate positions had independent saved model boxes;
maximum centre disagreement was 0.082 ball diameters. This is a tracker-cost
and agreement check, **not** live RF throughput or a new side-shot success rate.
The sparse 12:46 video cannot supply the discarded intermediate frames; the
installed build needs one real left/centre/right round to establish that result.

Evidence: `experiments/GoalChallenges/Review/iphone11-pixel-tracking-v14/`.
The explicit `--wall-pixel-benchmark` developer flag replays only files under
Documents/WallPixelBenchmark and writes a report; ordinary launches do not run it.

#### October 22: v15 — fast acquisition and lower work between shots

The 18:41 recording shows model cadence falling from about 10.9 to 8.2 fps
through the round while thermal state remains nominal. This does not establish
thermal throttling. At 164.61 s, a fresh RF candidate on the right moves 142 px
from the first 68 px ball observation over 133 ms. The fixed two-diameter
association gate discards that real candidate. Initial association now scales
its bounded travel allowance with elapsed time, within the existing 200 ms
identity lifetime. Weak candidates retain the stricter residual/size gates.
A nearby measured motion region can centre the initial follow search before
velocity is available; it never creates a ball measurement or contact.
The contact history also keeps a minimum travel allowance equivalent to two
ball diameters per 100 ms when model cadence drops below 10 fps. Otherwise the
same measured 161.44 s side shot passes at 8.37 fps but splits at 8.07 fps.
The 250 ms disappearance limit, wall depth, release and rebound checks remain.

CPU wall games now check motion on every processed camera frame, run periodic
4 fps model searches while waiting, and wake immediately on a motion hint or
pixel match. A measured model ball keeps continuous model processing eligible
for 650 ms, covering approach, rebound and decision. Reference sampling and
the paused keeper experiment retain their existing policies. Unseeded pixel
tracking no longer builds an unused 640 px grayscale image every frame.
Recordings identify `v15-time-aware-ball-association` and
`cpu-motion-wake-idle-4fps-v1`; resource intervals report intentional idle
model skips separately. Analysis FPS means active model cadence; stage call
counts remain the source for actual inference throughput including waiting.

Validation: 136 distinct selected XCTest checks pass (135 together, then the
11-test follow suite including the added capture-clock boundary regression).
The waiting-policy audit identifies one early peripheral ball observation at
99.74 s being skipped; motion wakes the policy roughly 33 ms later, and the
subsequent approach/contact window remains active. Offline call counts are
work estimates, not measured phone power or sustained speed.

The final combined causal RF replay uses 5,391 real compressed video frames,
original CSV capture timestamps, fresh pose observations, recorded alignment
gates and production contact rules, including the waiting policy. It runs
671 model calls versus 949 (29.3% fewer). All 17 baseline contact results remain,
with one additional boundary candidate at 164.726 s; both held and unknown-hand controls yield zero
contacts. Decoded-video model outputs differ from the original live outputs,
so these counts are an A/B regression comparison, not a live success rate.
The exact capture clock is necessary: MOV timestamp rounding can otherwise
turn the missing 250.14 ms before 151.70 s into a permitted 250 ms bridge and
misclassify its return as a middle-row hit. That case is a regression test.
A temporary image-smoothing experiment did not rescue spinning-ball matches
and was not included. Wall-contact evidence and image-match confidence requirements
remain unchanged. A fresh 2–3 minute physical left/centre/right round is required to
measure missed shots, active cadence and end-of-round behaviour on iPhone 11.
The signed build is installed and launched in Cross & Circle on the connected
iPhone 11 Pro Max. Startup for the new process confirms successful 288 CPU
model warm-up. Live physical shot accuracy and sustained speed remain to test.

Evidence and reproducible replay tools:
`experiments/GoalChallenges/Review/iphone11-fast-tracking-v15/`,
`Tools/replay_wall_fast_shots.swift`, `Tools/replay_wall_idle_budget.swift`.
The CLI equivalent is `experiments/GoalChallenges/Tools/replay_wall_pixels.swift`.

## Power diagnostics

The debug app saves battery percentage, charging state, Low Power Mode,
temperature state, process memory, brightness and app lifecycle events in
`Documents/PowerDiagnostics/power-*.jsonl`. A snapshot is written every five
seconds while the app is running, including menus and both keeper modes;
charging, temperature and lifecycle changes also create entries. The history
retains up to eight 256 KiB files across launches. Run IDs, wall-clock time and
device uptime help distinguish an app relaunch from a device reboot. This
logger does not keep the app running in the background, and sudden power loss
may lose the final write; a missing termination event alone proves no cause.

Recording resource logs also contain battery and wall-clock fields. The phone's
runtime report, including the real-penalty camera panel, displays battery and
charging status. Gameplay and detection rates are unchanged by this reporting.

## Trying it on a wall

1. Connect the iPhone to the projector using HDMI/USB-C or AirPlay Screen
   Mirroring. The app uses its dedicated external scene when iOS provides one.
2. Select Virtual Penalties on the phone. It opens **Real penalties**: the
   projector shows the keeper, and the phone shows the rear camera with ball
   detections. Once armed, **Follow my real ball** draws a small, high-contrast
   football with a short yellow trail from the incoming physical track, before
   predicted wall contact.
3. Adjust **Goal height** first (default 122%). This extends the projected scene
   upward from the same goal line; it does not move the bottom downward.
4. Tap **Start guided setup**. Stay still beside the phone through the short
   stand-aside countdown and blinking-marker check. The app finds the goal
   opening and locks focus. Take the real ball to the **single centre ring**.
   Touch the wall with the ball and keep it still. No corner ball holds are needed.
   The centre cue clears while the outer ring stays visible; its white arc
   fills from fresh, steady ball observations. The ring is deliberately larger
   than the accepted ball-size gate, so it cannot set the physical reference.
   The wireless washout remains 900 ms.
   When the ring fills, step back during the five-second countdown; keeper
   reactions start automatically. **Wait** pauses the countdown if needed.
   **Cancel setup** leaves reactions off. If marker detection fails, retry
   with the goal clear or use **Mark corners on phone instead**; the same
   centre ball hold follows the manual fallback.
5. Shoot once setup finishes. The keeper makes one live attempt. A corroborated
   wall impact confirms the result without restarting that attempt. The current
   `live-save-only-v2` policy returns him directly to ready after recovery;
   automatic physical replays, outcome gestures and black transitions are off.
   Goals retain the glowing yellow **GOAL** title.
   Select **Simulated trial**, then **Demo**, to cycle through a central catch,
   low dive, hard top corner, central Panenka, roof net, over-the-bar and wide shot.
6. Adjust **Goal size** and **Bright wall** from the simulated-trial controls. Without an external
   display, Projection settings offers a fixed-camera preview.
7. Use **Wall games** to return. The existing wall games require fresh
   calibration after leaving this preview.

**Projector lead** advances the displayed ball and keeper pose to allow for
output delay (0–250 ms; initial review estimate 200 ms). Raise it when the copy
lags; lower it when the copy jumps ahead. It cannot overcome a decision made
too late for the display to deliver it before contact. The copy follows the
camera's line of sight through the calibrated wall; it is not a reconstruction
of the player's separate viewpoint. It stops on loss, pickup, reversal or
predicted contact. Very short approaches may produce no visible copy.

The physical mode predicts the incoming shot to drive the keeper, then uses the
existing wall-games impact detector to confirm the wall hit. The trial result
compares that hit with the virtual keeper's hand/body coverage at the contact
time. This is a game rule, not proof of physical ball–hand contact. The replay
reconstructs the observed path and keeper motion; its depth is illustrative and
it is not a camera-video replay. A wall hit alone cannot trigger a timely dive.

While **Real penalties** is visible, the existing debug Mac preview serves
`/frame.jpg` and `/state.json` on port 8765. `Documents/KeeperLive/frame.jpg` and
`state.json` retain only the latest inspection sample, updated at most once per
second, for retrieval through the paired developer connection. Metadata includes
capture time, wall-clock update time and an inspection session UUID; check these
before treating an image as live. Leaving the mode stops further exports.
`state.json.keeper` exposes calibration stage, corners, measured wall diameter,
armed state, reaction count and the last commitment. It also exposes the current
instruction, target index, observed hold progress, completed diameters and
countdown. `keeperUpdatedAt` tracks the status independently when thermal policy
pauses JPEG previews; `frameTime` still describes the last camera image.
`KeeperLive/reactions.json`
keeps up to 100 commitments with source-frame time, decision time, estimated
arrival, goal coordinates, lead time and sample count.
**Record 20-second test** saves camera video, per-frame detections and resource
telemetry in the existing `Documents/WallTargets` recording format. Stop & save,
leaving the camera view, or a camera interruption finishes the current file.

## Implementation

The integrated source is `kicklab/Debug/VirtualPenalties`. The original
`experiments/KeeperLab` remains a separate prototype. Changes for the shared app
belong in the integrated source.

- RealityKit renders the existing procedural ground, rig and deforming net.
- A single `KeeperScene` transfers its stage between phone and external ARViews;
  it preserves the loaded rig and shot clock without rendering two 3D scenes.
- `VirtualPenaltyPresentation` owns the preview lifecycle. The existing wall
  camera runs in physical inspection mode, with stale wall-game crop corners
  cleared and scoring disabled. It stops for the simulated trial. No second
  capture session is created.
- `PhysicalBallPredictor` fits relative depth from measured apparent diameter
  and perspective-correct image coordinates. Several observations and two
  consistent estimates precede a commitment. A bounded quadratic follows
  vertical flight when enough samples are available. Held balls, stale frames,
  size outliers, retreating tracks and recovery-window rebounds are rejected.
- `PhysicalKeeperMotion` samples the captured rig directly on each render tick.
  Low side shots lower and roll the body into a ground dive, with the trailing
  foot kept close to the grass; high shots raise the body into a diving reach.
  Central shots select a smother, body catch or high reach. The simulated trial
  shares this motion implementation. Animation rate is capped at 2×;
  late reads can produce late attempts. Further pre-contact observations refine
  hand/body aim without restarting or reversing the committed dive. Physical
  pose time starts at the evidence frame's capture timestamp, with the output
  lead added and an 80 ms entry blend to avoid snapping into an advanced pose.
- `PhysicalShotReview` builds a virtual finish only after a corroborated wall
  hit with at least three recent observations. It checks the goal bounds and
  virtual hand/body coverage, continues the ball into the existing net physics,
  and reconstructs the ball's measured image-plane track.
- `PhysicalShotPlayback` separates the live finish, outcome gesture, covered
  transition, quarter-speed replay and return to play. Confirmation leaves the
  live body clock untouched and advances the ball to the current shot time.
  `PhysicalPoseHistory` stores the actual submitted body poses, including entry
  blending and refinements, so replay does not create another version of the
  attempt. Its timestamps use the existing output-lead clock; this does not
  measure the actual wireless presentation time.
- `KeeperOutcomeMotion` adds a compact fist pump for saves (with a caught ball
  in the other glove), or lowered shoulders/head, a glove to the forehead and
  a head shake for goals. Gestures start after recovery and return to ready.
  Tracking is gated during the result/gesture/transition and starts fresh during
  replay. The replay ball is scaled down to reduce detector feedback. Wireless
  transport still delays the result and replay on the wall.
- `PhysicalBallFlight` starts after two usable forward observations, independently
  of the stricter keeper commitment. It fits perspective-correct position and
  depth, coasts for at most 160 ms without another observation, and bounds total
  extrapolation to 400 ms including display lead. The canvas draws at display
  cadence using the goal homographies. The entire copy is less than half the
  measured real ball's wall diameter; physical-mode candidate selection rejects
  boxes below 75% of that measurement before ranking, preventing a confident
  detection of the projected copy from replacing the physical ball.
- Setup is transient. Goal-height/output changes, camera interruptions,
  backgrounding, display changes and detected phone motion invalidate it.
  Moving the projector while the phone stays still requires manual recalibration.
  Wall depth uses a centre ball hold, so strongly oblique camera positions remain
  an accuracy limit for this trial.
- Guided setup reuses the wall games' blink finder. Marker positions are
  projected from the actual rendered goal opening, including goal-height
  changes. One centre hold supplies the predictor's wall diameter. The previous
  four extra ball holds did not modify the detected corner mapping and have been
  removed. Missing, duplicate, sparse, unstable
  or wrong-position detections cannot finish a hold through elapsed time alone.
  Phone motion is checked during setup and while paused as well as during play.
  The active target keeps an outer progress ring while clearing its centre cue
  0.9 seconds before measurement can begin. The large halo is rejected by the
  ball-size gate. A disappearing projected false ball cannot finish the hold.
  If no physical ball remains, setup shows the brackets again for a retry.
- `WallGamesProjectorRoot` switches between the current wall game and penalties.
  The external window follows the scene's coordinate space on display changes.
  It chooses the largest advertised mode up to 1080p, with the preferred mode
  as a fallback, to avoid legacy low-resolution output and unnecessary 4K load.
- The BallDetectionDebug Info.plist explicitly declares
  `UIWindowSceneSessionRoleExternalDisplayNonInteractive`; generated scene
  manifests are disabled for this configuration so Xcode keeps that declaration.
- `KeeperAssets.bundle` contains the Microsoft Rocketbox character, retargeted
  Mixamo motion and their license/usage notices. Other app configurations exclude
  the bundle.

Apple documents the external scene declaration in
[UIWindowSceneSessionRoleExternalDisplayNonInteractive](https://developer.apple.com/documentation/bundleresources/information-property-list/uiapplicationscenemanifest/uisceneconfigurations/uiwindowscenesessionroleexternaldisplaynoninteractive).

## Build and deterministic checks

Build the `BallDetectionDebug` scheme using the `BallDetectionDebug`
configuration. Install the manifest-pinned detector with
`python3 scripts/install-rf-model.py` if this checkout lacks the ignored model.

Launch arguments:

- `--wall-targets`: open the normal wall-games menu.
- `--virtual-penalties`: open real-ball setup after the wall-games presentation.
- `--virtual-penalties --penalty-demo`: open the simulated trial and start its demo.
- `--shot=roof --net-impact`: inspect a preset's net contact.

Run the existing prototype verifiers against the integrated math sources:

```sh
swiftc -O -D DEBUG kicklab/Debug/VirtualPenalties/ShotSimulation.swift \
  kicklab/Debug/VirtualPenalties/GoalPhysics.swift \
  kicklab/Debug/VirtualPenalties/PhysicalKeeperMotion.swift \
  experiments/KeeperLab/Tools/verify_shots.swift -o /tmp/verify-integrated-keeper
swiftc -O -D DEBUG kicklab/Debug/VirtualPenalties/ShotSimulation.swift \
  kicklab/Debug/VirtualPenalties/GoalPhysics.swift \
  kicklab/Debug/VirtualPenalties/PhysicalKeeperMotion.swift \
  experiments/KeeperLab/Tools/verify_goal_physics.swift -o /tmp/verify-integrated-net
cd experiments/KeeperLab
/tmp/verify-integrated-keeper Resources/motion-library.json
/tmp/verify-integrated-net Resources/motion-library.json
```

These cover 14 keeper scenarios, 9 goal/miss/woodwork cases, 3 direct net
contacts and 72 corner/seam combinations. Logs and simulator captures are in
`experiments/KeeperLab/Review/integrated-*`.

## Verification — 20 October 2026

- Simulator and signed iPhone builds pass; all 98 deterministic cases pass.
- Opened penalties from the shared selector, played catches and goals, ran the
  demo loop and returned to the other games' menu.
- Verified separate external goal output and phone controls on iOS 26.5
  Simulator. Confirmed the character bundle loads and the phone's camera cutout
  no longer covers shot controls.
- The simulator's UIKit screen stayed at 720×480 even while its framebuffer
  advertised 1080p. Matching the simulated framebuffer to the active UIKit mode
  produced the full output shown in `integrated-projector.png`. Physical
  projector resolution negotiation and unplug/reconnect behavior still need a
  hardware test; the simulator did not reliably report disconnection.
- The integrated build is installed on Hewa's iPhone.

### Physical camera check and recorded passes

- Verified the iPhone's actual rear-camera image while the separate wireless
  projector display was active at 1280×720. This is real room evidence, distinct
  from the earlier simulator captures.
- Enlarged the physical-test goal to fit the output width, lowered its goal line
  toward the bottom of the picture and added a dark backdrop behind the net.
  The original and adjusted views are `Review/real-wall-first.jpg` and
  `Review/real-wall-adjusted.jpg` under `experiments/KeeperLab`.
- The projected picture still stops above the physical wall–floor join.
  Lowering the projector image is needed for ground-level alignment; camera
  framing cannot illuminate outside that picture. Ambient room light still
  reduces perceived contrast. Brightness and wireless display latency have not
  been measured with instruments.
- Retrieved the user's completed `2026-10-20_13-41-27` recording: 19.98 seconds,
  431 analysed frames (21.57 fps on average), worst thermal state Fair, no hit
  scoring or synthetic saves. Sensor configuration is 60 fps; this is **not**
  the measured analysis throughput.
- Four visible approaches provided approximately 0.33–0.50 seconds from first
  detected approach to estimated contact. Contact times are review estimates,
  not calibrated ground truth. Some detections widen or disappear near contact
  as the ball approaches its projected shadow. Off-camera intervals also exist;
  the fraction of all frames with a detection is not an accuracy measure.
- Review evidence: `Review/physical-test-2026-10-20/{video.mov,detections.csv,
  session.json,review-metrics.json}`. This recording predates live keeper
  reactions and is also used by the prediction regression check.
- Updated signed-device and simulator builds pass; the recording control was
  exercised on the physical phone and produced a completed playable recording.

### Real reaction verification

`Tools/verify_physical_keeper.swift` checks early approach predictions, stationary
and held balls, rebounds, gaps, duplicate/out-of-order observations, missing wall
calibration, bounded reach refinements and finite captured motion. Replaying the
first room recording produces one commitment in each of its four reviewed
approach windows. Offline replay uses an approximate wall diameter from review;
live sessions still require a fresh measured wall hold. It does not measure
wireless projection latency or establish save accuracy.

All 80 physical checks pass, covering guided-hold evidence rules, incoming flight
visualization and recorded approaches.
Signed-device and simulator builds also pass. The update is installed and launched
on Hewa's iPhone. Simulator output confirms taller framing, the earlier
simulated replay and the new marker/hold layouts (`guided-markers-projector.png`,
`guided-corner-projector.png`, `guided-centre-projector.png`). These initial
ring captures predate the marker-clearing fix; `guided-brackets-projector.png`
and `guided-measuring-projector.png` show the revised flow.

The physical projector is reconnected at 1280×720 and the four setup markers
were observed on the room wall. One retrieved failed search shows a person
walking across the camera between blink phases; it correctly rejected the
changing scene (`Review/guided-wall-search`). A stand-aside countdown now
precedes the check, with instructions to wait for the first numbered ring
before approaching the wall. The phone also reached thermal state Serious,
which pauses normal JPEG preview updates; lightweight keeper status remains
available independently.

### First guided physical test: zero keeper reactions

The user completed all five holds and recorded `2026-10-20_14-39-32`:
20.02 seconds, 356 recorded/analysed frames, with reactions armed throughout.
The session logged zero accepted keeper attempts. Replaying its detections
with the saved centre diameter (0.05484 of camera width, about 70 pixels)
reproduces zero predictions. Observations near the wall are about 47 pixels.
With a diagnostic diameter of 0.036, replay produces one commitment in each
of five approach windows, and no extra commitments. This diagnostic value is
not installed as a live calibration or proof of successful real saves.

The projected ring's size is consistent with the oversized setup measurement;
marker contamination is a likely cause, not directly proven by a calibration
video. Setup now uses brackets, removes the target, waits for display transport
to settle, and requires new stable physical-ball observations before saving
any diameter. The hold tests reject marker frames, a graphic that disappears,
and all earlier missing/wrong-position/unstable cases. Evidence is in
`Review/guided-physical-test-2026-10-20`.

### Marker-free setup and pre-impact ball following

The subsequent physical test `2026-10-20_14-56-22` completed all five holds with
diameters 0.0311–0.0357; centre diameter was 0.03533 (about 45 camera pixels).
Its 20.02 seconds contain five accepted keeper attempts, and the user confirmed
that the keeper moved. The user also observed late movement after the rebound.
On the first approach, the decision was delivered about 96 ms after its capture
frame, approximately 200 ms before predicted arrival. Manual frame review puts
the projected action-label change around 4.15 s and the decision around 3.914 s,
suggesting roughly 0.24 s of output delay. This is an approximate video review,
not an instrumented transport measurement. The old captured-animation windup
adds further visible delay.

The requested trial now shows a virtual copy **before impact**, following the
real shot; it does not start a second virtual flight after the wall hit.
Recorded replay produces flight evidence for all five approaches. With a
100 ms analysis allowance and 200 ms output lead, four have a drawable incoming
frame; the shortest approach is deliberately suppressed because it would
arrive too late. This is offline prediction evidence, not proof that those
four copies are aligned on the physical projector. Another physical test is
needed to assess the new copy and pose timing.

Both updated app builds pass, as do all 66 physical regression checks and
11 `RFSegBridgeTests` (including high-confidence projected copies ahead of a
lower-confidence real ball). The simulator fixture is captured in
`Review/ball-follow-projector.png` and `Review/ball-follow-phone.png`.
`Review/ball-follow-validation.json` records the validation boundary.
The signed ball-follow update was installed, then successfully launched after
the user unlocked the phone. Two subsequent physical recordings were retrieved
and reviewed below.

### Wireless wall review: 17:48:48 and 17:49:15

Both 20-second recordings and their detections/resources/session metadata are
preserved in `Review/ball-follow-test-2026-10-20_17-48-48` and
`Review/ball-follow-test-2026-10-20_17-49-15`. Both were armed, used a 250 ms
display lead and the same measured wall diameter (0.03851). The camera captured
about 60 fps; detection ran at approximately 25–28 fps. Thermal state remained
nominal. Capture-to-command delay on the accepted shots was 61–80 ms.

Manual review of the projected action label gives these command-to-visible
intervals. They include rendering, transport and projector processing; they are
not an isolated network measurement. Body-onset and physical-impact estimates
are less precise visual judgements.

| Recording / shot | Command → visible label | Body begins relative to wall impact |
| --- | --- | --- |
| 17:48:48 / 1 | 257–290 ms | 110–200 ms after |
| 17:48:48 / 2 | 275–308 ms | 117–182 ms after |
| 17:49:15 / 1 | 237–287 ms | 53–167 ms after |
| 17:49:15 / 2 | 388–438 ms | within about 50 ms, but wrong high reach |

The first clip's two later chips produced no reaction. An upward extrapolation
put the first forecast outside the goal; the predictor nevertheless entered its
cooldown before the controller accepted it. In the second clip, a descending
central ball produced a high catch attempt. The short lateral pass was already
too late according to the depth estimate. The fifth accepted command falls at
the end of the second clip, before its visible movement can be reviewed.

The revised trial:

- Commits only after the keeper accepts an attempt, so rejected forecasts can
  be corrected by later observations.
- Fits a gravity-aware vertical arc for both the keeper and pre-impact copy.
  Its prior assumes a nominal 22 cm football and approximately upright camera;
  this is a trial approximation, not measured 3D calibration.
- Excludes partly clipped ball boxes from motion depth measurements. This
  avoids a biased first size reading turning a high shot into a low forecast.

Replay with a stated 76 ms processing allowance now accepts seven attempts
across eight approaches, including both previously missed chips, with no extra
reactions outside the incoming-shot windows. The second clip's first high shot
is recognised 83 ms earlier and remains high. Its descending central shot
changes from a high catch to a lower body attempt. Those improvements do not
prove that the hands meet the ball on the physical wall.

All 80 physical checks and nine additional recorded timing/trajectory checks
pass, and both signed-device and simulator builds pass. Evidence includes
`Review/ball-follow-timing-replay.json`, `Review/wireless-timing-review.json`,
the four `wireless-onset-*.jpg` sheets with their exact frame PTS in the JSON,
and `Review/ball-follow-reactions-2026-10-20.json`.

The revised signed update is installed and launched on Hewa's iPhone.
Fresh camera status and `Review/wireless-trajectory-wall.jpg` confirm the goal
on the wireless projector, nominal temperature and live analysis. The session
is in setup with reactions unarmed; guided calibration must be repeated after
the restart. Set Projector lead to 250 ms for the next comparison recording
(the launch default is 200 ms).

The user chose to continue wirelessly. Variable 240–440 ms output delay remains.
The short pass still lacks usable lead, and some moving near-wall diameters
are smaller than the held centre calibration, making contact estimates early.
No hand-picked replacement diameter is installed. The virtual copy is brief
at this delay; its physical alignment and the revised keeper timing require
another wall recording. Real save/goal scoring remains off.

Run the physical regression suite from the repository root:

```sh
swiftc -O -D DEBUG \
  kicklab/Debug/VirtualPenalties/ShotSimulation.swift \
  kicklab/Debug/VirtualPenalties/GoalPhysics.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallArc.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallPrediction.swift \
  kicklab/Debug/VirtualPenalties/PhysicalCalibrationHold.swift \
  kicklab/Debug/VirtualPenalties/PhysicalKeeperMotion.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallFlight.swift \
  experiments/KeeperLab/Tools/verify_physical_keeper.swift \
  -o /tmp/verify-physical-keeper
/tmp/verify-physical-keeper experiments/KeeperLab
```

Replay the two wireless recordings, including the nine additional regressions:

```sh
swiftc -O -D DEBUG \
  kicklab/Debug/VirtualPenalties/ShotSimulation.swift \
  kicklab/Debug/VirtualPenalties/GoalPhysics.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallArc.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallPrediction.swift \
  kicklab/Debug/VirtualPenalties/PhysicalBallFlight.swift \
  kicklab/Debug/VirtualPenalties/PhysicalKeeperMotion.swift \
  experiments/KeeperLab/Tools/review_physical_timing.swift \
  -o /tmp/review-physical-timing
/tmp/review-physical-timing experiments/KeeperLab \
  > experiments/KeeperLab/Review/ball-follow-timing-replay.json
```

### Height, ball finish and replay trial: 18:22:49 and 18:24:04

Inspected both new 20-second recordings before changing gameplay. Their complete
video, detections and resource metadata are preserved in
`Review/wireless-arc-test-2026-10-20_18-22-49` and
`Review/wireless-arc-test-2026-10-20_18-24-04`. Both used **200 ms** projector lead,
not the requested 250 ms. Detection ran at roughly 22–23 fps with Fair thermal
state; accepted commands arrived 73–110 ms after their camera frames.

Each clip contains four accepted keeper attempts. Offline replay of the existing
wall impact detector confirms all eight contacts. Confirmation follows the
contact by approximately 233–417 ms, before additional output delay. The two low
shots in the first clip map to goal heights of −0.15 m and −0.11 m: they hit below
the calibrated opening. Align the projected goal line with the physical floor
before using those shots to judge low saves.

The incoming copy is eligible to draw on only 15 and 20 analysed frames across
the respective clips when replayed with their 200 ms lead and an assumed 76 ms
delivery allowance. Those are offline eligibility counts, not counts of visible
projector frames. Its short lifetime, small footprint and low contrast explain
why a continuous ball pass is hard to see. The new copy uses stronger contrast
and a short yellow trail; it still cannot remove wireless transport delay.

The new trial adds:

- Height-specific ground dives and airborne reaches, plus central smothers,
  body catches and high reaches. It uses the existing free captured motions.
- A virtual result from the measured wall hit and the keeper's coverage at that
  contact time. Predictions alone cannot award a goal.
- A visible ball finish with net response, glowing yellow GOAL text, saved/miss
  titles, and an automatic 0.65× reconstructed replay.
- Fresh tracking during replay so an accepted new approach can interrupt it.
  The large result title briefly gates tracking to reduce projected feedback.

Validation passes: 40 height/result/replay checks, 80 physical tracking/setup
checks, nine recorded timing regressions, 14 simulated shot scenarios, and the
existing net checks including 72 corner/seam combinations. Signed iPhone and
simulator builds pass. External-display simulator captures show the low dive,
high reach, GOAL, SAVED and REPLAY states in `Review/gameplay-*.png`.
These are simulator render checks; the new result/replay flow still needs a
physical wall recording. No new exact command-to-visible latency measurement
has been established from these clips.

Inspection details: `Review/wireless-arc-inspection.json`,
`Review/wireless-arc-confirmed-contacts.txt`,
`Review/wireless-arc-timing-replay.json`, and
`Review/keeper-gameplay-validation.json`. The timing tool labels its comparison
policy `original-linear-baseline`; it is not the policy installed for these new
recordings.

Run the new gameplay checks from the repository root:

```sh
swiftc -O -D DEBUG \
  kicklab/Debug/VirtualPenalties/ShotSimulation.swift \
  kicklab/Debug/VirtualPenalties/GoalPhysics.swift \
  kicklab/Debug/VirtualPenalties/PhysicalKeeperMotion.swift \
  kicklab/Debug/VirtualPenalties/PhysicalShotReview.swift \
  kicklab/Debug/VirtualPenalties/PhysicalShotPlayback.swift \
  kicklab/Debug/VirtualPenalties/KeeperOutcomeMotion.swift \
  experiments/KeeperLab/Tools/verify_keeper_gameplay.swift \
  -o /tmp/verify-keeper-gameplay
/tmp/verify-keeper-gameplay experiments/KeeperLab
```

Simulator-only still fixtures: `--physical-result=goal` or
`--physical-result=save`, with `--review-age=0.3` for the finish,
`--review-age=1.8` for the outcome gesture, or `--review-live` for the automatic
sequence. To exercise the real handoff, use `--physical-flow=goal`, `save` or
`over` and `--flow-audit`; these start a live attempt before delayed confirmation.
`--flow-interrupt` injects a second shot during replay. The audit is written to
the simulator's `Documents/flow-audit.json`.

The signed gameplay update is installed and launched on the iPhone. Fresh live
telemetry reports the new `measured-wall-hit-keeper-coverage-v1` policy, and
`Review/gameplay-installed-wall.jpg` confirms the wireless goal and guided setup
on the actual wall. Setup is being repeated after the restart; no physical shot
result from this new build has yet been validated.
The simulator's three timed `gameplay-live-*.png` captures verify automatic
result → replay → ready. The simulator's external video recorder retained an
old rendering surface across app restart, so its movie was discarded; the
fresh screenshots are the visual evidence.

### Physical replay-flow inspection: 18:56:00

The user reported that a shot appeared to produce three reactions and that
replay was too fast, and requested postponing additional features. Retrieved
the completed 20-second recording, detections, telemetry and reaction/result
log. This inspection makes no application changes.

The clip contains two real shots, two new keeper commands and two confirmed
results (over the bar and caught). A third command in the session log predates
the recording. There is no evidence of extra keeper commands during these
replays. The repeat comes from the presentation:

1. The keeper performs the live attempt.
2. `finishPhysicalShot` replaces it with a reconstructed frame at the earlier
   wall-contact time. Confirmation arrives 502 ms and 366 ms after that contact;
   including the existing 200 ms pose lead, this rewinds the keeper clock by
   approximately 702 ms and 566 ms.
3. After only 950 ms, the result phase jumps to the start of the replay,
   repeating the action again without a separate transition.

The replay's 0.65× multiplier also retains the live motion's rate. The high
dive ran at the 2× cap, so its replay is still 1.3× the source captured motion.
The central catch's replay is approximately 0.85× source motion. This is slower
than the live attempts but does not consistently look like slow motion.
Furthermore, replay samples the final refined motion rather than a stored
history of the exact poses rendered live.

The preceding deterministic checks covered poses, outcome rules and ball-path
continuity; they missed the live-to-result animation-clock discontinuity.
Simulator fixtures with no active live attempt also did not exercise it.
The next correction should preserve one uninterrupted live attempt, allow a
result hold, and enter one clearly separated slow replay of the shown motion.
Celebrations, frustration, extra miss reactions and crossbar sound remain
deferred pending this correction.

Evidence: `Review/replay-flow-inspection.json`, `replay-flow-reactions.json`,
`replay-flow-high-shot.jpg`, `replay-flow-catch.jpg`, and the complete
`replay-flow-test-2026-10-20_18-56-00` directory. The rewind values are derived
from app clocks and code, not a new measurement of wireless projection latency.

### Single live attempt and outcome gestures

The subsequent correction removes the result-phase rewind. Confirming a wall
hit leaves the current pose, position, entry blend and live motion clock intact.
The virtual ball begins its finish at the current elapsed shot time instead of
making another approach. After the original motion has recovered, a 1.7-second
outcome gesture plays, followed by a covered transition into one quarter-speed
replay. With the live motion rate capped at 2×, replay is at most 0.5× the
original captured motion. A new accepted shot can interrupt replay and blends
from the currently shown pose without first snapping to ready.

Replay uses a bounded five-second pose history, including the actual entry
blend and aim refinements. The ball path is still reconstructed from camera
observations and virtual physics; it is not camera video or measured 3D motion.
A caught ball retains its contact offset when attaching to the recorded hands.
The live result still uses the existing approximate virtual coverage rule.

Save gestures use one fist pump, with a caught ball in the other glove. Goal
gestures lower the head/shoulders, raise a glove to the forehead and shake the
head briefly. These are procedural gestures on the existing rig, preserve bone
lengths and start only after save recovery. Over/wide shots use a small glance;
crossbar detection/audio remains a separate deferred addition.

The replay ball's size is bounded using the measured wall-ball footprint and
perspective compensation. It no longer grows on approach toward the virtual
camera. Tracking is gated during the result/gesture/transition and cleared
before resuming during replay; these controls reduce projected-ball feedback.

Validation:

- 63 deterministic checks pass, including both recorded delayed confirmations,
  monotonic result ball time, recovery-before-gesture ordering, exactly one
  replay, quarter-speed playback, recorded-pose fidelity, catch continuity,
  bounded history and smooth grounded gestures.
- Full simulator live attempts confirm **zero pose/position jump at result
  confirmation**, one ordered result → gesture → transition → replay → ready
  sequence, and successful replay interruption with zero immediate pose jump.
  These fixtures exercise a running live motion, unlike the earlier still
  previews. Evidence: `Review/single-attempt-goal-audit.json`,
  `Review/single-attempt-save-interrupt-audit.json` and their PNG captures.
- Live result logs now include planned gesture/replay/return timestamps.
  Telemetry identifies the presentation as
  `single-live-attempt-quarter-replay-v1`.

Wireless latency is unchanged. The corrected sequence and gestures still need
a fresh physical recording before their appearance on the wall is validated.

Final simulator and signed iPhone builds pass. The update is installed and
launched; fresh phone telemetry confirms the new presentation policy and an
unarmed setup state. The current camera image shows the projector's home menu,
so Screen Mirroring must be reconnected before guided setup and the next test.
Evidence: `Review/single-attempt-install.json`, `single-attempt-launch.json`,
`single-attempt-live-state.json` and `single-attempt-installed-wall.jpg`.

### Live save mechanics, replay deferred

The 19:38:04 physical recording contains two central shots and two commands.
The first arrival estimate is 134 ms early; the second is 53 ms early.
The old live path refined the target but ignored refined arrival times, and
scored a reconstructed contact pose rather than the pose submitted to the
display. Its first result sequence occupied about 10.1 seconds. Inspection
evidence is preserved in `Review/latest-flow-inspection.json` and the
`latest-flow-test-2026-10-20_19-38-04` folder.

The user asked to put replay aside and concentrate on the ball and saves:

- Automatic physical replay, outcome gestures and black transitions are off.
  The original recovery finishes and the keeper returns to ready.
- A small grounded preparation starts while the first trajectory is checked.
  It does not commit a dive or count as an additional attempt.
- `PhysicalSaveTiming` adjusts the remaining reach to refined arrival times
  without rewinding, exceeding the source-motion speed limit, or restarting.
  A short contact hold prevents an early estimate from immediately pulling
  the hands away (160 ms centrally, 60 ms for dives).
- Physical results use timestamped rendered poses at estimated wall contact.
  Missing pose evidence cannot create a save. Catches require two nearby hands
  around the ball; one-hand contact is a parry. Result logs preserve contact
  evidence, palms and the assumed display lead.
- A confirmed catch continues into a bounded chest cradle. Its ball is only
  visible when the actual palms form a grip. The finish ball uses the measured
  wall size, clears before fresh tracking, and never starts another approach.

Validation: 82 gameplay/pose checks, 80 tracking checks and nine recorded
trajectory regressions pass. Simulator and signed iPhone builds pass. The
running simulator flow records zero pose/position jump at confirmation and a
direct return to ready, with no replay/gesture phase (`live-save-flow-audit.json`).

The physical presentation policy is `live-save-only-v2`. Rendered-pose scoring
still depends on the configured estimate of wireless display latency; it is
not an instrumented measurement of the exact pose visible at contact. The
changes require a fresh physical recording to assess their appearance.

### Direction-first anticipation and Juggle Dude balls

The prediction policy is now `direction-first-three-observation-v4`. Two
forward observations can start grounded preparation; they cannot start a
dive. Three observations spanning at least 60 ms can commit when depth speed
is consistent, size-fit error is small, detector confidence is sufficient,
and successive arrival/target forecasts agree tightly. Other tracks retain
the longer confirmation path. Goal bounds and the live acceptance gate still
apply; a rejected early proposal does not consume the shot. Arrival and reach
continue refining during the same attempt.

Replaying nine accepted approaches from the 17:48:48, 17:49:15 and 19:38:04
recordings advances six decisions by 33–50 ms; three are unchanged. This
measures the decision policy offline, not improved wireless display latency.
85 physical tracking/calibration/flight checks and 18 recorded trajectory
checks pass. The historical oversized-calibration test explicitly uses the
historical policy to reproduce its original zero-reaction failure.

The real-ball screen now offers all 14 replacement skins already bundled in
Juggle Dude, defaulting to Classic Pro and remembering the selection. The
`.jdmaterial` files are byte-identical to the main checkout. The 3D ball uses
their colors, seam data and object normals converted to tangent space; seam
distance is never interpreted as alpha. The projected camera copy uses the
main app's sphere renderer with 32 small spin frames prepared off the frame
loop. Skin loading preserves the previous material until the replacement is
ready. Simulator views verify the selector, approaching copy and held ball.
Replay and outcome gestures remain disabled.

### Live projection visual review (21 October 2026)

Launch the debug app with `--wall-visual-audit --wall-targets` to review all
12 available games on the external display. The isolated audit model cycles
38 calibration, gameplay, impact and result states. It does not ingest physical
shots or replace saved calibration. The phone shows Previous, Pause, Next and
Finish review controls. Normal launches do not enable this mode.

The existing read-only camera feed serves 1280-pixel JPEGs in this mode, with
scene timestamps and locked exposure/focus/white-balance metadata. Camera
inference is bypassed while the visual audit is active. Capture with
`experiments/ProjectionAudit/Tools/capture_tour.py <live-feed-url> lights-on`;
`build_review.py` produces labelled contact sheets and a local HTML gallery.
The original frames are retained without image enhancement.

The first wall review captured 114 frames across all 38 states with identical
camera settings and the projector connected throughout. Under the ceiling
light, dark backgrounds merge with the wall, colour separation is weak, and
small HUD/result text is faint. The goal net competes with the target rings,
robot and keeper; the classic game result screens make the board too small.
These are visual observations from the camera, not calibrated luminance
measurements or validation of physical shot accuracy/timing. Monster Raid and
the concept's human-keeper Penalty Duel are not implemented. Existing Goal
Duel is the robot-based prototype.

A second, shorter tour (`--wall-audit-overview`) captured 39 frames of all
12 gameplay scenes and the keeper goal state after the ceiling light was
switched off. Explicit audit-only exposure/ISO/focus flags approximately
reproduced the first camera settings; white balance was locked anew after an
app restart. Readability and colour separation improved visibly, but the wall
still lacked the concept's dark background and saturated glow. Artwork gaps
remain independently of lighting: the wireframe city, simple robot, faint
environment details, thin target edges, and oversized bright goal net. See
`experiments/ProjectionAudit/Review/review.html` for both passes and the original
frames. The comparison is qualitative, not calibrated colour/luminance data.

The newest recording retrieved for this request is **20:02:57**, from the
previous `gravity-refined-arrival-v3` build. Its low shot receives a command at
3.022 s, before estimated contact at 3.533 s; a 50 ms frame review brackets
visible movement around 3.15–3.25 s. It bounces low and hits below the goal.
The lofted second shot exits above the camera, returns with an inconsistent
size/depth track, and never produces a committed dive under either policy.
Both measured hits are outside the calibrated goal. This clip is not
validation of a catch or of the newly installed policy. Evidence:
`Review/anticipation-inspection.json`, `anticipation-recorded-comparison.json`,
`anticipation-newest-predictions.json` and the original video/CSV in
`anticipation-test-2026-10-20_20-02-57`.

Simulator and signed device builds pass. The new build is installed and
launched on the iPhone; `Review/anticipation-installed-state.json` confirms
the new prediction policy, Classic Pro, and `live-save-only-v2`. It is unarmed
until guided setup is run again. Wireless latency, incomplete camera coverage
on lofted shots and depth uncertainty remain physical-test limitations.
