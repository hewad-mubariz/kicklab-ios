# Outdoor session and pose-cost checks

Use the main Juggle Dude local Debug build, with optimized (`-O`) device app code.
Launch once with `--outdoor-validation` to persistently show the existing debug
overlay. The debug toe choice is preserved across launches and defaults to On.
Release builds always enable the normal heel/toe model and expose no
test UI, launch switch or counter toggle.

In the camera, tap **Session tests · 30s–30min**, choose **Toe recovery (MediaPipe)**
On or Off beside the duration ladder, select a duration, then press the
normal Record button. The available durations are 30 seconds, 1, 2, 3, 5, 10, 15,
20, 25 and 30 minutes. The existing coordinator stops against recorded-video time.
Manual stop still works, and a short attempt stays marked as short. Collapse the
overlay by tapping its header; restore a closed overlay in Profile → Settings →
Show debug overlays.

This is a model-only comparison. Off skips MediaPipe Full inference and shoe
proofs; visible-foot recovery v2, Apple Vision revision 2/fallback and all other
counter rules stay enabled. The mode is latched when Record resets the counter,
even if camera warmup happened before the switch changed. The prior pose model
is released on reset. The switch is disabled during recording setup, recording,
finalization and guided analysis. Explicit `--shoe-recovery-on/off` benchmark
launches lock the switch until a normal icon launch.

Each report and its history row identify the live toe mode. Fresh analysis stores
its own mode separately, including `settings.json` in every retained analysis
attempt, so replaying the same source with a different mode does not relabel the
live result. On/Off analysis signatures remain separate, while a model choice
after warmup preserves mask/count reuse provenance if all other settings match.

The overlay shows touch count and elapsed/target time, process memory/peak,
thermal state, battery/Low Power state, ball-detector latency and backend,
analysis/saved FPS, camera/writer drops, analysis replacements and retained mask
bytes. Pose fields specifically refer to **MediaPipe Full on CPU**, separately
from the lazy Apple Vision body/hand requests in the detector log.

Pose measurements include model initialization time, inference calls/errors,
average and maximum inference latency, frames with a valid 33-point pose,
total pose work and supported contact checks. Supported checks are not necessarily
additional counted touches. Calls that throw are included in attempted-call time.
The footprint before/after initialization is a whole-process observation, not
isolated model RAM. The existing ball detector, camera buffers and other work
can affect it. These timings are wall-clock work measurements, not CPU utilization
or isolated pose energy. Pose work is already inside contact-buffer/full-frame
timings and must not be added again.

Each armed run retains evidence under Documents/FinalValidation/<run UUID>:

- `report.json`: device, build, target, stages, exact final capture and pose totals.
  It also includes `shoeRecoveryEnabled` and `analysisShoeRecoveryEnabled` when recorded.
- `samples.jsonl`: one-second thermal, footprint, battery, free disk, FPS, touch
  count and cumulative pose snapshots.
- `live-performance.json`: final stage totals and pose snapshot after counter flush.
- `detector.csv`: periodic detector timings plus cumulative `shoe_*` columns.
- `live-contacts.jsonl` and `live-touches.json`: contact decisions and confirmed touches.
- `capture.json` and retained `source.mov`: saved frame cadence and original recording.

Reports and originals can be shared from the same test panel. Existing reports
remain readable when the new optional fields are absent. No telemetry upload is
added. Extra retained test videos consume storage independently of ordinary history.

Start with 30 seconds for framing and audio; then 3, 10 and 30 minutes as useful.
For a device comparison, begin at Normal thermal state with similar lighting,
framing and movement, and note charging and Low Power status. A longer run tells
us about thermal changes, lost analysis frames and memory growth. It does not
prove touch accuracy without a manual count/review. Comparing different outdoor
performances also cannot isolate the model's incremental energy or accuracy;
controlled saved-video comparisons remain the stronger follow-up for that.

Validation covers the duration ladder through 30 minutes, old report decoding,
cumulative counters without double-counting, real pose inference/reset and normal
heel/toe rules. The UI test selects and disarms 30 minutes; it does not claim to
have completed a real 30-minute outdoor capture.
