# Outdoor session checks after removing the auxiliary pose model

Build 84 removes MediaPipe Full, its SDK/linker anchors, model-only heel/toe
proofs and the debug On/Off switch. The retired preference and launch flags
cannot enable it. The model file is also excluded from target membership so a
copy left in another checkout cannot accidentally ship.

The existing RF-DETR ball detector, lazy Apple Vision contact poses (revision 2
with CPU fallback), visible-foot recovery v2, small-arc/adjacent-foot rules,
hand-hold and floor-bounce rejection, three-second visibility grace, and live
count/mask reuse remain. The current analysis signature uses the former model-Off
identity. Saved model-On evidence cannot match; old diagnostic reports still
show their original mode and costs. Historical numeric shoe proofs are ignored
when decoding evidence for the current counter. Saved session results and videos
are not deleted or rewritten.

## Measurements behind the removal

Two separate five-minute sessions on iPhone 17 Pro Max, 1.2.0 build 83:

| Metric | Model On | Model Off |
| --- | ---: | ---: |
| Extra model calls | 9,001 | 0 |
| Analysis FPS | 29.98 | 29.92 |
| Counting-stage average | 20.48 ms | 13.05 ms |
| App median / peak footprint | 396 / 479 MiB | 312 / 391 MiB |
| Thermal state | Normal | Normal |
| Counted touches | 257 | 214 |

The observed 36% reduction is counting-stage wall-clock work, not total pipeline
latency, CPU utilization or isolated energy. The ball-detector worker overlaps
the counting worker. Different performances/exposure prevent an accuracy claim
from the counts. Battery readings were coarse (50 to 45 versus 45 to 45).
The Off source had a 675 ms startup frame gap and 30 reported capture drops near
startup; none accrued later. Both sources copied with matching SHA-256 hashes
and fully decoded. Evidence is under the local ignored artifact directory
`artifacts/outdoor-pose-runs/iphone17-20261109/`, including
`on-off-comparison.json` and both complete session folders.

## Running the duration ladder

Use the main Juggle Dude local Debug build, with optimized (`-O`) device code.
Launch once with `--outdoor-validation` to persistently show the debug overlay.
In the camera, tap **Session tests · 30s–30min**, choose a duration, then press
Record. Available durations are 30 seconds, 1, 2, 3, 5, 10, 15, 20, 25 and 30
minutes. Auto-stop uses recorded-video time. Manual stop still works; a short
attempt stays marked short. Restore a hidden overlay in Profile → Settings →
Show debug overlays. Release builds expose no test panel or counter toggle.

The overlay keeps touch count, elapsed/target time, process memory/peak, thermal
state, battery/Low Power state, ball-detector latency/backend, analysis/saved
FPS, camera/writer drops, analysis replacements and retained mask bytes.
The label “Counter stage” excludes the separately measured ball detector.

Each armed run retains evidence under Documents/FinalValidation/<run UUID>:

- `report.json`: device/build, target, stages, final metrics and review notes.
- `samples.jsonl`: one-second thermal, footprint, battery, FPS and touch samples.
- `live-performance.json`: final cumulative stage totals after counter flush.
- `detector.csv`: periodic detector and counter timing samples.
- `live-contacts.jsonl` and `live-touches.json`: decisions and touch timestamps.
- `capture.json` and `source.mov`: capture cadence and original recording.

Legacy `shoeRecoveryEnabled`, `analysisShoeRecoveryEnabled`, `shoePose` and
`shoe_*` diagnostic fields remain readable. New runs report Off/zero; these are
schema compatibility only, with no auxiliary model object or per-frame work.
Reports and originals remain shareable from the panel. Extra retained test
videos consume storage independently of ordinary history.

For comparisons, begin unplugged at Normal thermal state with similar lighting,
framing and movement. A long run reveals thermal changes and memory growth, but
accuracy still requires manual counting. The duration-ladder UI test arms and
disarms 30 minutes; it does not claim a real 30-minute capture.

## Build 84 verification

All 80 selected code/UI checks pass, including report compatibility, retired
model-proof rejection, unchanged base counter rules, cache identity, long-session
mask reuse and duration controls. The signed optimized Debug device app shrank
from 244,594,059 to 186,430,843 bytes (58,163,216 bytes removed). These are local
uncompressed Debug bundles, not App Store download sizes. Bundle inspection finds
zero auxiliary model/SDK files and zero MediaPipe exported symbols (4,759 before).
The installed iPhone 17 launch report confirms build 84, model Off and an exact
match to the ON field recording's remaining counter configuration. Build/test
and installation evidence is under `artifacts/remove-aux-pose/`.
