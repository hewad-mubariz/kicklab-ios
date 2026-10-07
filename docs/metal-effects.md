# Metal effects engine

The follow-up [six-effect and Nightfall pass](six-effects.md) documents the current editor, decoded-frame synchronization and newer validation. The remainder records the initial Metal rollout.

Fire, Ice, Neon, Galaxy, and the recording counter now use `MetalEffectEngine`.
The old CoreGraphics effect paths have been removed. `BallMaterialRenderer` retains the existing ball skins without redesigning them.

## Rendering

1. `EffectFrame` supplies upright pixel coordinates, physical ball radius, video time, visibility, motion, and recent detections. Preview applies the same aspect-fill crop as the video. Live history now carries real timestamps.
2. A compute pass integrates an advected, warped 3D noise density field through 12 slices for Fire. Flame length and direction respond to tracked velocity. The irregular burning surface preserves the photographic ball underneath. A separate age-weighted field follows the recent trajectory, without connecting detection gaps.
3. An instanced quad pass adds 80 drifting embers. The counter uses 210 seeded particles with varied delay, lifetime, travel, width, and brightness. Their state is a function of timestamp, so pause, seek, export and repeat renders agree.
4. Two MPS Gaussian passes provide near and broad bloom from the HDR emission texture. Tone mapping occurs after bloom, producing valid premultiplied SDR pixels.
5. Preview draws into a transparent MTKView. Export copies the source frame to a GPU texture and composites into a Metal-compatible pixel buffer, avoiding simultaneous reads/writes to the same texture. GPU completion is checked before the encoder receives the frame. Audio muxing and SDR conversion are retained.

Heavy shading is limited to the emitter/trail region, capped at 640 pixels on its longest dimension. Targets use quantized sizes, pipelines and the seeded noise volume are shared, and preview limits frames in flight. Unchanged option thumbnails are not resubmitted at video frame rate. These are engineering bounds, not a measured physical-device frame-rate guarantee.

The counter increases the number to 100 pt, uses a white-to-mint fill, runs a short burst for each count update, and stops the animation clock after the burst. Reduced Motion disables expanding particles. Counting/detection behavior is unchanged.

## Validation

- Debug iPhone 17 Pro simulator build and all 12 existing/new tests passed. Four GPU tests were rerun and passed after final Fire tuning.
- Release build for generic iOS succeeded, including device Metal shader compilation.
- Actual input: `/Users/hewadmubariz/Downloads/input/input-positive/input.mp4`.
- Existing real detector results: `artifacts/effects-validation/analysis.json`. The graphics pass reuses this track; it does not manufacture ball positions or rerun/tune counting.
- Four effects exported with original ball material: 1080 × 1920, 422 frames, 7.04 seconds; full decode passed and source AAC bytes were preserved exactly.
- GPU tests cover deterministic pause/seek, effect distinction, zero intensity / visibility, valid premultiplied alpha, preview vs export source-over agreement within two 8-bit levels, counter decay, and crop/history mapping.
- `artifacts/metal-effects/index.html` contains the previous/new Fire comparison, full-frame exports, and scripted counter graphic review.

Remaining limits: no person-depth occlusion, no fluid simulation, and no physical-iPhone thermal/frame-rate profiling. Simulator export timings include decoding, rendering and encoding, and are not live FPS measurements.

## Reproduce

Build and install Debug, then launch with:

```
--effects-video /absolute/input.mp4
--effects-track /absolute/analysis.json
--effects-export
```

Use `--effects-only fire` for a single export. Files and status are written to the app's `Documents/metal-effects` folder. Copy the exports into the repository artifact folder and run `python3 scripts/review-metal-effects.py` to validate and rebuild the review page.

Counter graphic review:

```
--session-design counter --counter-image /absolute/frame.png
```

Add `--counter-age 0.16` for a fixed burst phase. These debug launch routes are excluded from Release builds. `scripts/render-metal-frame.swift` is a macOS rendering lab compiled with `EffectFrame.swift`, `MetalEffectEngine.swift`, and a compiled version of the same Metal shader library; it is used for fast shader iteration only. Final video artifacts come from the app exporter.

Apple references: [MTKView](https://developer.apple.com/documentation/metalkit/mtkview), [MPSImageGaussianBlur](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianblur), [Core Video Metal texture creation](https://developer.apple.com/documentation/corevideo/cvmetaltexturecachecreatetexturefromimage(_:_:_:_:_:_:_:_:_:)).
