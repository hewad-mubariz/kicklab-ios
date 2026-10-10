> Superseded: the body-anchored approach was rejected. See the current ball-driven review in `artifacts/reference-effects/index.html` and `docs/reference-effects.md`.

# Player-scale effects on input 4

The graphics pass now uses the recorded player bounds as well as the ball. The reference is the ten-effect picker artwork: a readable ball, recognizable materials, and detail extending from the shoes toward the shoulders. Neon is deliberately more prominent.

## Shipping changes

- `BallStyleSample` retains the detector's normalized player rectangle. Brief ball-track interpolation interpolates the player rectangle only when both endpoints contain it. The tracking adapter applies the same aspect-fill geometry to ball and player, with a 140 ms average on the player bounds to soften detector jitter.
- `EffectFrame` sends an eighth `float4` to Metal: player center x, feet y, half width and height. The render tile includes the atmosphere and drifting particles. The existing 640-pixel maximum tile dimension remains in place.
- Non-Fire materials have a separate player-scale pass and a second particle population. Ribbons cross the lower body and dim on their back turns; the upper central body stays relatively clear. These are composition cues, not segmentation or depth occlusion.
- Ice uses a fractured frost shell, faceted shards and cold mist. Neon has thicker emerald tubes, fine hot cores and traveling highlights. Galaxy adds blue/violet nebula and larger stars. Electric adds long branching discharges. Aura has silver filaments. Shadow uses opaque charcoal smoke with violet edges. Rainbow retains separate colors through bends. Pixel uses broken square columns. Nature has irregular vines and fluttering veined leaves.
- With no player rectangle, the atmosphere falls back to a bounded field around the ball. It does not claim to locate a person. Missing ball tracking and zero intensity still clear every effect.
- Live view, replay, exports and scene-projected tracks carry the player geometry. The Debug review harness now saves/restores player boxes instead of dropping them.
- Fire's material and particle behavior are retained. A same-frame comparison on input 4 differed in one channel by one 8-bit level out of 2,764,800 RGB channels after recompilation.

## Review

Open `artifacts/player-effects/index.html`. It contains a synchronized original/effect comparison, all ten full app exports, a cropped ten-way video, and motion sheets. The main review uses original daylight, 85% effect intensity, original ball material, and 720 × 1280 output (the input's native size).

Input: `/Users/hewadmubariz/Downloads/input/input-positive/input4.mp4`. The app analyzed 456 frames, with accepted ball and person detections on all 456. This is detection coverage, not an accuracy score. No hand-authored ball or player positions were used.

`analysis.json` is the actual detector report. `verification.json` records full decoding, frame count, duration and original AAC preservation for every export. `EffectsTests.xcresult` / `tests.log` contain the tracking, Metal and scene-export regression run. `FinalGPUTests.xcresult` / `final-gpu-tests.log` cover the final shader refinement. `device-build.log` contains the iPhone Release build.

## Reproduce

Build/install the Debug app and launch in the simulator:

```sh
xcrun simctl launch --terminate-running-process booted com.juggledude \
  --effects-video /Users/hewadmubariz/Downloads/input/input-positive/input4.mp4 \
  --effects-folder player-effects-input4 --effects-quality 720 --effects-export
```

To reuse the existing input 4 detections, add `--effects-track` with the absolute path to `artifacts/player-effects/analysis.json`. Wait for the new run's `Documents/player-effects-input4/status.txt` to say `COMPLETE`, copy the MP4s into `artifacts/player-effects`, and run:

```sh
python3 scripts/review-player-effects.py
```

The early `neon-before-after.jpg` compares the saved previous shader with the new shader on the same input 4 frame and detections. The full videos come from the shipping app exporter. This pass does not include physical-iPhone frame-time or thermal measurements.
