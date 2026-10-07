# Player cutout and camera study

A working first step toward replacement environments. It is now available through **Replay & Effects → Environment → Preview Classic Stadium**, with progress, Original/Stadium comparison and a camera-movement toggle. This is a bounded preview; the saved environment and export integration remain unfinished. See [in-app preview details](stadium-app-preview.md). The study runner also processes existing clips on the Mac and exports review videos.

[Open the review](../artifacts/foreground-study/index.html)

## What is implemented

- `ForegroundMaskProcessor`: sequential Apple Vision person segmentation at balanced/accurate quality. The worker handles an upright source crop, returns timestamped masks, and resets Vision state on a discontinuity. Processing is designed to happen before presentation rather than inside a drawing callback.
- `BallForegroundMask`: keeps the ball independently of the person mask. It searches locally around the existing detector position for a coherent perimeter, adjusts the center/radius, refines the radial silhouette, and feathers the boundary. A small inward edge adjustment reduces retained background. It is an approximation for a roughly circular ball, not a trained ball-matting model.
- `ForegroundMatte`: maps both masks to the same upright source coordinate space and combines their coverage.
- `SceneCameraRig`: perspective calibration from source framing and estimated ground position; analytic lateral and forward camera movement with a zero-velocity start. A locked mode provides a direct comparison. No playback-rate or render-order dependence.
- `StadiumPreview.metal`: a simple world-space pitch/goal/curved-stand calibration scene, shared with the in-app preview. The camera casts rays through the scene and reprojects the source image and mask onto a shared subject plane. Foreground and floor therefore use the same projection. Blending is performed in linear light.
- `VisibleFootContact` estimates a support boundary from connected lower-leg pixels in the person mask. A stability filter holds the previous depth and fades the shadow when the foot disappears or the estimate jumps implausibly.
- The subject plane's depth is adjusted to put that visible boundary on the floor without changing the scene camera. A tighter contact shadow follows it. This is a visible-boundary heuristic, not reconstructed foot pose or measured 3D depth.

The stadium art in this study is deliberately simple. It is not the port of the detailed RN stadium and should not be mistaken for the final Classic Stadium appearance.

## Actual footage

Two seven-second excerpts are normalized through the existing AVFoundation upright/SDR geometry path at 720 × 1280, 30 fps:

- Park: `input.mp4`, source seconds 0–7, including a small distant player and balls in flight.
- Indoor: `input5.mp4`, source seconds 9–16, including close framing, fast feet and motion blur.

Each excerpt has six variants: normalized original, balanced cutout, accurate cutout, combined alpha mask, locked scene camera and gently moving scene camera. Original source-audio excerpts are remuxed into the review copies. The 30 fps study is not a claim that production export may discard the source cadence.

A coarse prepass examines accurate person masks to estimate a stable crop and ground/framing parameters. Ground placement is based on mask bounds and has uncertainty. All footage is single-player. Source camera motion has not been solved.

## Findings and limits

- Apple Vision produces a useful initial full-body cutout on both samples. Cropping around the player helps allocate mask detail to the subject.
- The detached ball requires independent preservation. Initial fixed-center contour masks retained a visible crescent of trees beneath the park ball; a constrained center/radius search and a small inward adjustment reduced it.
- Hair, fast blurred feet and some ball edges still show halos or uncertain coverage. The study is not ready to be represented as a finished production-quality mask.
- In the outdoor source, grass already occludes the bottom of the standing foot. Segmentation cannot restore the unseen toes. The [foot-contact comparison](../artifacts/foot-contact-study/index.html) includes the original crop alongside the mask, plus the placement/shadow correction. No replacement body pixels were generated.
- The restrained camera move creates different motion at the subject, pitch and distant goal. Geometric tests verify that a subject-plane ground anchor and the corresponding floor point project together.
- This does not reconstruct the human body in 3D. It cannot support a large orbit around the player. All foreground pixels currently share one depth plane, including the ball.
- Handheld-camera estimation, dynamic subject depth, reliable planted-foot tracking and final scene lighting remain open. The existing counting motion compensator only estimates a limited screen-space motion component; it is not a complete camera solve.
- Mask videos and stills are diagnostic artifacts. A production timestamp-indexed, versioned mask cache and replay/export integration are not implemented yet.

## Validation

27 simulator tests pass, covering source-framing identity, smooth camera startup, seek determinism, locked mode, ground-anchor attachment, depth parallax, ball-boundary refinement, contact estimation and missing-foot stability. The iPhone Release build also succeeds. The actual Vision processing is exercised on the Mac's hardware against the clips rather than through mocked masks. Test and build logs for the contact correction are in `artifacts/foot-contact-study/`.

The media assembly script verifies output dimensions, frame counts, duration and full decoding. Timing reports describe this Mac study, not iPhone performance. Physical-iPhone mask throughput, cached playback, memory and thermal behavior still need measurement.

## Reproduce

```sh
zsh scripts/run-foreground-study.sh
```

The contact comparison preserves the previous camera videos in `artifacts/foot-contact-study/{park,indoor}/before.mp4`. After rendering the current study, rebuild its before/after page with `python3 scripts/assemble-foot-contact-study.py`.

Requires the Xcode Metal toolchain, Swift, the existing local source videos, and Homebrew FFmpeg/FFprobe. The script reads the source paths from the existing detector reports. It does not upload footage or change the counting pipeline.

## Next stage

Review the cutout and locked/moving camera videos. Then improve the weak mask edges and ground calibration, add source-camera motion estimation for handheld clips, and port the RN stadium's geometry/materials into the calibrated native scene. Integrate it as a selectable editor environment after these quality gates pass.
