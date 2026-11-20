# Wall games: frozen beta candidate and endurance qualification

## 24 October follow-up: confirmed model load; recorder candidate

The user’s next three complete recordings (11:58:29, 12:00:27, 12:03:57)
used the intended `31a2289f…` build on iPhone 17 Pro Max. Serious occurred
7m17s after the first recording started. Play was unplugged; charging started
after the warning. Memory peaked around 353 MiB and recovered at rest, with
no memory-warning event. These are different workloads from the earlier run,
so 7 versus 9 minutes is not a matched before/after heat measurement.

The phase/idle gates worked, especially in Memory Strike, but recording kept
encoding every delivered camera frame. As inference rested, Memory’s saved
video cadence rose to about 45 fps. The new recorder samples only empty,
intentionally unanalysed frames at 10 fps. Every analysed frame, every ball
observation and provisional pixel evidence stays eligible for recording;
encoder backpressure remains possible. Capture, resolution, live inference,
contact rules and game graphics are unchanged by this candidate. CSV rows
remain one-to-one with decoded movie frames and retain original timestamps.
The metadata identifies the cadence policy and counts intentional video skips.

Production Swift replay on all ten October 24 sessions lost no saved analysed
or ball-observation frame. For the three latest sessions it writes 2747/4056,
4392/6821 and 2984/7582 frames: 32.3%, 35.6% and 60.6% fewer. These are encoder
admission reductions, **not measured heat or energy savings**, and recorded
observations are not physical ground truth. Quiet footage has lower temporal
resolution for future labelling. The 229-test wall suite passed; an added
variable-cadence movie/CSV/contact integration test also passed (230 distinct
wall tests covered across the two successful runs).

An explicitly launched, bounded diagnostic component study keeps the live
720p60 camera on and feeds the same twelve saved frames to the RF 384 CPU+GPU
model and H264 encoder. It compares capture, 60/15 fps video, 30/15 Hz model,
and production Memory Strike graphics. It does not run physical shot scoring,
full-frame recovery, hand pose or the alignment pipeline. It writes separate
`Documents/WallThermalStudy` files, stops when backgrounded or Serious, and is
inactive without `--wall-thermal-study`. The normal game launch must not carry
that flag. The final candidate hardens camera setup failure cleanup; the study
measurements used the earlier `thermal-study-20261024` executable.

Forward and reverse Power Profiler traces confirm the model is the largest
incremental load in this experiment. At 30 Hz, model-only GPU power-impact
scores averaged 33.0 / 21.1; at 15 Hz, 14.8 / 7.0, respectively. These are
unitless same-device scores, not watts or proof of 15 Hz shot accuracy.
Capture/video-only scores were zero in the app GPU lane; that does not mean
the camera or encoder uses no energy. Graphics-only Memory Strike also had
near-zero GPU impact in this study. Reducing video from 60 to 15 fps did not
consistently reduce power in the combined phases across orderings.

The traces ran with one display at roughly 53% brightness; power logs reported
unplugged. The user confirmed USB, but CoreDevice continued reporting a local
network transport. Do not call this a verified wired/AirPlay endurance test.
All component runs completed at Normal. The raw reports, video verification
and timing limitations are recorded in `findings.json` beside the traces.

The candidate was installed and launched normally on iPhone 17 Pro Max.
The on-device fingerprint matches; detector startup is ready, recording is off,
camera is resting, memory about 104 MiB, and thermal state Normal at verification.
 Do not present the recording change as the primary
heat fix. Before reducing active inference cadence or changing the compute
backend, validate fast approach/rebound evidence using the model and real
videos; the current export deliberately avoids Neural Engine numerical drift.
No 30-minute endurance pass has been established. The next physical check is
at most 5–10 minutes after Normal, with the same game/projector setup, and
should stop if the warning returns. Preserve that partial run for comparison.

Evidence, signed build, baseline snapshot, isolated diff, trace exports,
replays and test logs:
`/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/wall-targets/thermal-profile-20261024/`.
Candidate source fingerprint:
`acb492fd123b07b2a0c72d0f0413215330ec469d0bd21aa1617b69c2db1e965d`.
The earlier 30-minute instructions below are historical and superseded until
this shorter check and a substantive model-power reduction are validated.

## 24 October: iPhone 17 heat investigation and comparison build

The saved 24 October run reached Fair at 11:11:36, Serious at 11:17:16,
and Fair again at 11:19:51. Fair is still warm. The camera rested between
rounds and memory recovered; these logs do not establish a memory leak.
The CPU+GPU 384 detector was continuously active during Memory Strike WATCH,
despite that phase rejecting shots. Model stages occupied about 94% of the
timed frame pipeline in that session; this is elapsed time, not GPU energy.

The comparison build keeps detector resolution, model, contact rules and
rendering unchanged. Memory Strike suspends inference during WATCH/interlude
while alignment, recording and the game clock continue. Crossing that boundary
clears pending contact evidence. Recall wakes inference immediately. Accelerated
wall games now use a conservative full-scene motion check between shots, with
a 4 Hz fallback search and full-rate analysis during movement and for 650 ms
after a model observation. Player-sized motion also wakes it; motion itself
never counts as a ball or hit. CPU tracking and physical keeper inspection keep
their existing policies. Resource logs separate phase skips from idle skips.

Evidence is preserved in
`/Users/hewadmubariz/Desktop/projects/kicklab/benchmarks/wall-targets/thermal-update-20261024/`:
baseline source archive, isolated change diff, source/build manifests, signed
device build, 226 passing wall tests, replay tools and reports. The source
fingerprint is `31a2289fb78514e4fbf9018287848fed09a182fc6b3c8e9c45545f5cc1822d02`.
Use the manifest value if copying this candidate into another build.

On the three latest gameplay recordings, candidate admission retained all 36
previously accepted hits and all saved ball observations during input phases.
It avoided 30.1% of Brick Blast, 22.8% of Clear the Wall and 58.7% of Memory
Strike's model-analysis frame opportunities. One rejected Memory contact during
interlude disappears. No retained contact was confirmed later in this replay.
This uses decoded video motion, recorded detections/hand state and production
contact rules; it does not rerun Core ML, establish physical accuracy, or measure
on-device thermal savings. Saved detections are not ground truth.

Install this comparison only on the iPhone 17 Pro Max for the initial 30-minute
check. Start at Normal, with consistent brightness/projector settings and no Mac
preview. Play repeated rounds for 30 minutes total (10 minutes each Memory
Strike, Brick Blast, Clear the Wall); keep the normal recording/autosave behavior.
If the heat warning returns, stop, note the elapsed time and preserve that shorter
run. Thermal improvement and beta acceptance remain pending that physical test.

Status, 22 October 2026: **feature scope frozen; performance qualification pending.**
The existing games and shot rules are the candidate. No new game modes, scoring,
keeper animation or replay features belong to this pass. The goalkeeper work stays
where it is. Diagnostic logging is not a product feature. Do not label this build
“MVP accepted” or the device tests “passed” until the evidence below exists.

The user chose **prepare now, run on the phones later**. No long physical-device
test was performed during preparation. The connected older device is an
**iPhone 11 Pro Max (iPhone12,5)**; the newer device is an **iPhone 17 Pro Max
(iPhone18,2)**. This is not coverage for every iPhone 11/17 model or every small
screen. A physically smaller phone needs a separate layout/accessibility check.

## Candidate and measurements

Use the same signed Ball Detection Debug app on both phones. The worktree is
`/Users/hewadmubariz/.codex/worktrees/keeper-lab/kicklab`; the bundle identifier is
`com.juggledude.balldetection.debug`. Keep the production device-specific detector
profile, input resolution and tracking policies; do not force both phones onto
the same compute backend or lower detection quality for a better heat result.

The diagnostic configuration can use `WALL_ENDURANCE_OPTIMIZATION_LEVEL=-O` for
the app target only. Its normal default remains `-Onone`. Swift packages retain
their own settings. This is an optimized **diagnostic** build, not a Release or
TestFlight qualification. The games currently compile under diagnostic flags.
Final distribution needs its own configuration check and matched endurance run.

Build/source evidence lives in `benchmarks/wall-targets/beta-endurance-20261022/`.
The generated Info.plist `WallEnduranceBuild` value identifies the source snapshot;
the build manifest also records the executable SHA-256. Install the exact same
candidate on both phones. No builds or fixes during a measurement run.

The bounded on-device `Documents/PowerDiagnostics/power-*.jsonl` history records:

- Whole-app physical footprint, iOS thermal pressure and memory-warning events.
- Battery percentage, unplugged/charging/full state, Low Power Mode and brightness.
- Run ID, process ID, hardware model, OS, bundle/build and source fingerprint.
- Menu/setup/playing/results phase, video recording and Mac-preview state.
- Camera and analysis FPS snapshots, inference time and whole-process CPU seconds.
- Attached screen count and whether the main screen is captured. Capture can also
  mean screen recording, so note the actual AirPlay setup manually.

Sampling remains every five seconds plus lifecycle/power events, with no retained
video or growing sample array in this logger. Rotation remains bounded to eight
256 KiB files. Pull the logs after each run; old history eventually rotates out.
The logger does not estimate temperature in Celsius, GPU/ANE watts, battery health,
true per-frame p95, real-shot accuracy or projector latency.

## Controls before each run

1. Phone cool at **Normal** thermal state, preferably 60–85% battery; unplug before
   launching the measured run. No USB charging, wireless charging or debugger.
2. Same room, projector, AirPlay route, wall, camera position, phone brightness
   (40% for the first comparison), audio level and case condition. Disable automatic
   brightness for the controlled test. Record any unavoidable change.
3. Low Power Mode off. Record OS, battery maximum capacity from Settings, ambient
   temperature if available, starting battery, free storage and case condition.
4. Keep normal game recording behavior identical. Mac browser preview off for the
   main wall-game comparison; if a goal-game path enables it automatically, note
   that and keep that path as a separately matched workload.
5. Start a fresh app process for each run so histories cannot accidentally combine
   multiple builds. Use the same device-specific settings each time. Record the
   wall-clock time when actual play begins and ends.

The phone must remain foreground and the projector connection must remain stable.
A lock, background interval, charging event or connection change is evidence to
keep, not something to hide. The report flags it; repeat the controlled run later.

## Test matrix, one phone at a time

| Test | Both phones | What it establishes |
|---|---|---|
| Primary baseline | 5 min at the game menu/results, normal setup, **30 min repeated Clear the Wall rounds**, 5 min at results | Memory plateau/recovery, battery, heat, long-session side-hit reliability |
| Repeat baseline | Same 30 min workload after cooling, preferably another day | Reproducibility; avoids choosing a lucky run |
| Memory Strike | 30 min of ordinary watch/input/restart cycles | Timers, sound, pattern state, repeated-round cleanup |
| Graphics-heavy games | 15 min Brick Blast and 15 min Meteor Defence, same sequence on each phone | Effects/particles plus camera load; report separately from the primary baseline |
| Goal games | 15 min Top Bins and 15 min Find the Space | Goal scene/camera path, retained scene memory and setup reliability |
| Extended endurance | **60 min** on each phone after the 30 min runs are stable | Late-session degradation and sustained battery use |
| Lifecycle/recovery | 10 game-entry/exit cycles; 5 background/resume cycles; 3 AirPlay reconnects | Resource release, clean recalibration, no duplicate cameras/audio/timers |
| Remaining game smoke pass | Start, play a complete round, results, restart, exit for every current selectable game | Feature freeze did not conceal a broken route |

Do lifecycle/reconnect tests separately from battery comparisons. Test ordinary
charging play separately only after the unplugged baseline; never infer drain from
a charging phone. Keep the existing critical-heat handling; end a run if the phone
reports Critical, the app stops, or the battery reaches 15%. Save the partial run
with its reason; it is not a successful 30/60-minute completion.

## Real-shot checks at the beginning, middle and end

At minutes 2–5, 14–17 and 26–29 of primary gameplay, repeat the same six-target
sequence through three normally restarted rounds: **18 valid hits**, covering
left/centre/right and top/bottom, followed by two deliberate outside-board shots.
Include gentle and faster passes in the same order each time. Only count shots
whose physical contact is visible and unambiguous. Mark unclear line hits separately.

Keep an independent tally/video witness: attempted target, actual contact location,
whether one hit was registered, wrong target, double count, and visible delay.
Also observe a 30-second stationary-ball interval and 30 seconds with no ball.
The game's own scored hits are not ground truth. An empty room or stationary ball
cannot establish fast side-impact performance. If diagnostic video is enabled for
these checks, use the identical capture schedule on both phones and note its cost.

## Proposed acceptance targets

These are provisional product targets, not measured results or platform limits.
Review the first matched baselines before freezing the final battery budget.

| Area | Target / review rule |
|---|---|
| Stability | No crash, jetsam, forced restart, lost calibration during an unchanged setup, or duplicate camera/audio path |
| Heat | No Critical state; investigate Serious lasting over 2 minutes or any heat-correlated responsiveness loss |
| Memory | After warmup, late active median stays within max(25 MiB, 10%) of early active median for the same game. Check repeat-round/return-to-results retention; no repeated stair-step growth or memory warnings |
| Recovery | After 2–5 min at results, compare with the same warmed resting state. Investigate >50 MiB added retention after repeated identical cycles; bounded caches are not automatically a leak |
| Responsiveness | Compare matching active shot bursts early/late, not the overall FPS average. Investigate >20% worsening in sampled inference time, sustained capture-rate loss, or visibly delayed feedback |
| Accuracy | Aim for ≥95% correct eligible hits overall, ≥90% in each spatial zone with at least 20 attempts per zone accumulated across repeat tests, no duplicate scores or stationary-ball false hits; no >5 percentage-point early/late deterioration |
| Battery | Initial target ≤15 percentage points per 30 min of matched play at 40% brightness; measure twice, report battery health and coarse percentage uncertainty. No extrapolated all-day runtime claim |
| Smaller screens | All setup and restart controls visible/tappable, no HUD clipping in supported orientations; Pro Max runs alone do not pass this |

A threshold breach starts investigation. A clean telemetry file alone never awards
beta acceptance. Keep manual accuracy/rendering/recovery results with the report.

## Pull and report after a test

From the worktree root, use an unused output directory (the collector refuses to
overwrite previous evidence). The collector reads small files only; it does not
launch, reinstall or delete anything on the phone.

```sh
# iPhone 11 Pro Max
python3 scripts/wall-endurance.py collect \
  --device ED8613A6-8382-57D6-963A-E1E4886933ED \
  --output benchmarks/wall-targets/endurance/iphone11-run01

# iPhone 17 Pro Max
python3 scripts/wall-endurance.py collect \
  --device 0440AB85-BD17-5A51-AF30-B00F6F7E3382 \
  --output benchmarks/wall-targets/endurance/iphone17-run01

python3 scripts/wall-endurance.py report \
  benchmarks/wall-targets/endurance/iphone11-run01 \
  --run all --output benchmarks/wall-targets/endurance/iphone11-run01/report.json
```

The JSON includes per-run five-minute windows and explicit missing-data reasons;
a Markdown summary is written beside it. Select the measured UUID with `--run`
after inspecting `availableRuns`. `latest` alone could pick an accidental relaunch
after the test. An app restart is never stitched into the preceding run.

## Evidence at preparation

Existing histories were pulled from both phones without launching or installing.
They contain charging/resting intervals, changed brightness, short runs and gaps;
they are diagnostic context, not a matched endurance baseline. Legacy logs lack
phase/build/display fields, so those values remain unknown instead of being
reported as zero or a pass. New physical runs and acceptance are still pending.

## Deployment — 22 October 2026

The user subsequently requested installation for testing on 23 October. The same
signed, fingerprint-verified candidate was installed on the iPhone 11 Pro Max and
iPhone 17 Pro Max. Both installed app records match their installation receipts
(bundle `com.juggledude.balldetection.debug`, version 1.0, build 13). The apps were
not launched for an endurance run. Installation receipts and verification are in
`benchmarks/wall-targets/beta-endurance-20261022/deployment-20261022/`; the build
manifest records the exact candidate. Physical tests and beta acceptance remain pending.


## One-hour target — 25 October 2026

The user's endurance target is now **60 minutes of ordinary alternating wall games
with normal thermal state**, stable hit accuracy and no restart. This is an
unmet product target, not a claim about the current build. Existing 30-minute
results do not satisfy it. The 25 October baseline reached Serious after about
15 minutes of elapsed recording/setup time and blocked the next game.

For the next candidate, start the iPhone 17 Pro Max at Normal, unplugged, with the
same brightness, fixed camera, room lighting and projector connection. Play
repeated rounds rather than leaving a single game idle. Preserve individual
round videos and continuous power logs; do not stop/relaunch the app between
rounds. Compare early and late controlled shots, including tile edges and short
turn intervals. The one-hour run is not passed if the heat guard blocks play,
Serious/Critical occurs, accuracy deteriorates, or logs are missing. Record Fair
intervals separately; they are not a verified Normal-only hour. Do not bypass the
thermal guard to complete the target. A cooldown/restart begins a separate run.

Review at approximately 15 minutes before continuing toward 60. Preserve the
same recording settings for comparison. Report actual active-play time as well
as elapsed time and time spent in setup/results. Do not extrapolate replay model
call reductions into a promised battery or thermal duration.
