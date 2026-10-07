# Research-to-implementation audit — 28 September 2026

This is the baseline audit. The subsequent implementation and measured results are in [the sequential improvement report](cutout-improvement-progress.md); several gaps listed below are now addressed.

The supplied research is broadly relevant, but many of its foundation steps already exist. The main remaining work is validating and improving fine alpha, resolving suspicious foreground regions, and establishing a fair person-model comparison. Hand holes, attached background and hair flicker need mask-stage investigation before lighting changes can help.

This audit reads the current implementation and the supplied research, checks primary project/API sources, and runs controlled probes against the shared native implementation. It does not claim to identify the exact origin of every newly reported defect without a stage trace of that sequence.

## What exists and what is missing

| Research recommendation | Current status | Evidence / remaining work |
| --- | --- | --- |
| Keep Swift, AVFoundation and Metal | Implemented | Decode, offline processing, rendering and export already use these. No measured reason for a C++ rewrite. |
| Correct high-resolution Vision alpha | Implemented | Both person and ball call `generateScaledMaskForImage(forInstances:from:)`. Instance IDs select targets; they are not composited as alpha. |
| Explicit targets instead of allInstances | Implemented, with limits | Person instance is selected against an accurate person guide; ball instance is selected near a verified center. No production `allInstances` union. Dominant-person selection is not persistent multi-person identity tracking. |
| Separate person and ball branches | Implemented | `DetailedForegroundMaskProcessor` keeps them separate until `ForegroundMatte.image`. Native crops precede preview downsampling. |
| Ball detector/tracker → crop → semantic matte | Implemented, with limits | Image-validated localization, tight source crop, selected instance, constrained contour fallback. No learned occlusion-aware ball video-matting model; partial occlusion and motion blur still require labeled checks. |
| Target-aware combination | Partial | Components and ball support are constrained before combining, but the final operation is still maximum. It cannot reject a false-positive patch already retained by either branch. Max itself is not automatically wrong for validated visible masks. |
| Repair holes without filling genuine gaps | Partial | Local repair needs person-guide alpha >235/255 and sufficient component area/width/height. It adds guide coverage; it does not resolve false-positive foreground or recover details both models miss. |
| Preserve fine hair/hand coverage | Not established | Largest-component cleanup uses alpha ≥32/255 and retains a one-pixel soft border. Fainter connected detail farther outside that core can be removed. Current tests do not establish real hair/finger accuracy. |
| Spatial edge refinement | Implemented heuristic; guided filter/trimap absent | Metal estimates local foreground/background colors near a boundary. Effective correction requires background within five cache pixels and a sufficiently opaque interior sample. No `MPSImageGuidedFilter`, explicit three-region trimap, ViTMatte, or suspicious-interior classifier. |
| Warp before temporal smoothing | Implemented, with limits | Backward Vision flow, previous alpha/color, photometric and alpha gates, reset on time discontinuity. Flow runs at ≤512-pixel maximum edge. No forward/backward consistency test, separate object-motion confidence, or explicit occlusion map. |
| Edge foreground-color decontamination | Implemented heuristic | Refined linear-premultiplied color is cached and used by the scene/reflection renderer. Residual spill remains; there is no learned foreground-color estimator in the app. |
| Synchronization/orientation/premultiplication | Substantially covered | Upright shared source, numeric alpha, packed RGB/alpha sharing one timestamp, versioned renderer, a soft-alpha GPU test. This does not rule out real-frame cache/compositing losses; uncompressed-versus-decoded comparisons remain necessary. |
| Save all failing stages | Incomplete | Old raw/clean/guide still-image audits, final caches and per-frame metadata exist. No complete sequential trace of raw person, guide, cleaned/repaired person, ball, combined, spatial, temporal, encoded and decoded alpha for the same current run. |
| RVM person benchmark | Run; fair selection still incomplete | Fixed Core ML and higher-detail recurrent TorchScript runs exist. Native runs included the dedicated ball branch; RVM did not. Need same ball masks, source timestamps/crops and compositor, plus person-only ROI scoring. |
| MatAnyone 2 benchmark | Not run or integrated | Worth a controlled person-only trial after establishing the trace/baseline; package output resolution and distribution terms are material limits. |
| SAM 2.1 + ViTMatte / SAM2Matting | Not run or integrated | Workstation prototypes to consider if simpler approaches fail. Not established on-device solutions for this app. |
| Higher-quality final-export matting | Not implemented as a separate pass | Export renders the prepared H.264 foreground cache; it does not rerun segmentation/refinement from the source. Preparation covers the full duration at a maximum 30 fps and up to 1080p output. |
| Every original source frame | Not currently preserved | The park source has 422 frames at 60000/1001 fps; preparation produces 212 at 30 fps. Prior “all 212 frames” verification means every prepared frame, not all original camera frames. |
| User keep/remove corrections propagated through video | Absent | Potential fallback for difficult clips, but not the first automatic-quality experiment. |
| Empty-scene background capture | Absent | A separate future capture mode, not a fix for arbitrary existing park clips. |

Main implementation evidence: [person selection, repair and ball masks](../kicklab/Environments/DetailedForegroundMaskProcessor.swift), [mask combination](../kicklab/Environments/ForegroundMaskProcessor.swift), [edge shader](../kicklab/Environments/ForegroundMatting.h), [motion processing](../kicklab/Environments/ForegroundEdgeProcessor.swift), [preparation/cache](../kicklab/Environments/StadiumPreviewPreparer.swift), [export](../kicklab/Environments/SceneMovieRenderer.swift).

## Fresh controlled probes

`scripts/probe-matte-limitations.swift` runs the current shared code and Metal shader. Results: [probes.json](../artifacts/research-gap-audit/probes.json). Alpha values below are 0–255.

| Controlled input | Observed output | What it proves |
| --- | --- | --- |
| Incorrect opaque background block touching the body | Interior remains 255 after component cleanup and edge refinement | Being attached lets it survive component selection; narrow boundary refinement does not correct a broad interior. |
| Missing 12×12 interior patch, guide confidence 230 | No repair region | A second mask can substantially support the person yet fail the repair threshold. At guide 255, the same patch yields one region. |
| Same missing patch, opaque previous frame, identical source colors, perfect zero motion | Center remains 0 with history enabled | Temporal smoothing deliberately rejects large disagreement away from the current boundary; it is not a general hole-recovery stage. |
| Faint strand attached to the body, alpha 20 then 34 | Cleanup outputs 0 then 34 | Crossing the component threshold can create a discontinuity in retained faint detail. This is a plausible contributor to blinking and needs real-sequence confirmation. |

These are synthetic mechanism probes, not measurements of defect frequency in the user's video. They establish that the current implementation can exhibit the reported classes of failure. They do not justify globally filling holes, lowering all thresholds, or retaining every connected pixel: those changes can retain foliage and fill valid spaces between fingers/arms.

## What deserves priority now

1. **Trace the exact failure sequence.** Save short consecutive sections around hand holes, hair flicker and attached background, with the source, raw person alpha, person guide, cleaned person, repaired person, ball, combined alpha, spatial-only result, temporal result, decoded cache and exported composite. Use identical frame timestamps and coordinates. Show black, white, saturated contrasting color and actual arena backgrounds. Find the first stage that creates each defect.
2. **Separate removal from recovery.** Mark obvious foreground-to-keep and background-to-remove regions, with an unknown band around ambiguous hair/motion blur. Test local disagreement/uncertainty handling for both missing skin and excess background. Preserve real finger/arm gaps. Do not declare existing mask interiors universally certain.
3. **Compare refinement alternatives with the same input.** Current shader versus a confidence-weighted guided-filter experiment; then a trimap-based learned refiner if the simpler trial cannot recover useful detail. Inspect whether the current foreground-color fit itself removes valid skin on difficult boundaries.
4. **Run a fair person-model comparison.** Native selected subject lift plus accurate guide, high-detail RVM, and MatAnyone 2, with the exact same verified ball branch and renderer. Score hands, hair, feet and body/background confusion separately. Native remains the current implementation, not a proven universal winner. Ball transparency in a person-only RVM result is not valid evidence against its person quality.
5. **Ablate temporal and cache effects.** Disable history without changing the other stages; compare raw refined alpha with the decoded H.264 alpha and final export. Test abrupt hand movement, occlusion/reappearance, repeated similar foreground/background colors, hair, and genuine spaces between fingers. Explore flow confidence or local higher-resolution motion only when the trace implicates history. Do not strengthen averaging globally.
6. **Decide the export quality path from measurements.** A higher-quality offline pass can avoid inheriting the same lossy matte cache and can preserve original cadence where supported. Test it against the current 30 fps path; higher resolution/frame rate alone does not fix wrong foreground identity. Keep preview/export camera and compositing behavior consistent even if matting quality differs.

The acceptance evidence should include fewer annotated false-positive background pixels, fewer missing hand/foot pixels, preserved genuine gaps and soft hair, lower temporal error without trails, and actual phone memory/time. Review normal-speed exported video as well as paused crops. Use held-out clips, not only the two clips used to tune this implementation.

The earlier 57 passing tests establish covered behavior and regressions. They are not a hand/hair segmentation benchmark. The earlier roughly 10% reduction in large motion-compensated alpha changes is an aggregate proxy, not proof that the reported regions no longer blink. No production behavior was changed in this audit, so the application suite was not rerun; the new native probe compiled and executed successfully.

## Assessment of the proposed technologies

- **Apple guided filtering:** available natively and not yet used. The installed SDK exposes regression/reconstruction and optional confidence weights. A reasonable small experiment for uncertain boundaries; it does not supply semantic identity or guarantee recovery of missing fingers. [Apple API](https://developer.apple.com/documentation/metalperformanceshaders/mpsimageguidedfilter).
- **RVM:** the official model is designed for human video matting with recurrent state and foreground/alpha outputs. We have already run it; improve the fairness of that comparison before repeating downloads or rejecting it because of the ball. [Official project](https://github.com/PeterL1n/RobustVideoMatting).
- **MatAnyone2Kit:** the author's 30 fps claim is for iPhone 16/A18 at fixed 288×512 working/returned-alpha resolution. That is not a KickLab export measurement. The repository identifies GPL-3.0 package code and non-commercial NTU S-Lab bundled weights. Treat it as an evaluation candidate with those stated constraints, not an already cleared product dependency. [Package documentation](https://github.com/flowtyone/MatAnyone2Kit).
- **SAM 2 + ViTMatte:** a plausible prompted tracking-plus-refinement experiment. ViTMatte expects an image and trimap; temporal consistency remains an additional requirement. Neither stage exists in KickLab. [SAM 2](https://github.com/facebookresearch/sam2), [ViTMatte](https://github.com/hustvl/ViTMatte).
- **SAM2Matting:** relevant to both human and non-human targets, but local quality, runtime and iPhone feasibility are untested. Its repository states CC BY-NC-SA 4.0/non-commercial research terms. Defer product integration; workstation evaluation is a separate bounded experiment. [Official project](https://github.com/FudanCVL/SAM2Matting).
- **BackgroundMattingV2:** requires an extra background image. Potentially useful for a controlled stationary-camera capture mode; it cannot be assumed to work for existing clips without that input. [Official project](https://github.com/PeterL1n/BackgroundMattingV2).

There is no current evidence that a language rewrite, a new background image, global hole filling, or simply stronger smoothing will solve these defects. The research's most immediately useful recommendations are full stage tracing, uncertainty-aware refinement, fair person-only model comparisons, and an export-quality audit.
