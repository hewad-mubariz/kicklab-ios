# Matting strategy selection — 28 September 2026

Follow-up: [ground contact and scene realism audit](ground-contact-realism-audit.md) distinguishes the small measured floor-anchor error from grass-occluded soles and the scene's lighting/depth mismatch. The improvements here do not establish realistic scene integration.

Further review: [research-to-implementation gap audit](matting-research-gap-audit.md) identifies unhandled attached-background, hole and faint-strand cases with executable probes. It also qualifies the model selection: the earlier native comparison included a separate ball branch while RVM did not, so ball transparency cannot establish inferior person matting. A fair comparison with a shared ball branch remains pending. The 212-frame park validation covers the prepared 30 fps sequence, not all 422 original camera frames.

The previous strategy was insufficient on these clips. The selected implementation keeps native subject lifting and the independently verified ball matte, then adds a complete motion envelope, local person repair, source-guided boundary refinement, and motion-compensated temporal filtering. This is an implemented improvement with two-clip regression evidence, not a claim that all edge flicker is solved.

Review the [actual iPhone before/after at 6.5 seconds](../artifacts/matting-strategy-study/iphone-review/recovered-foot.jpg) and [full same-camera comparison movie](../artifacts/matting-strategy-study/iphone-review/comparison.mp4) (previous left, revised right). Both sides use real phone-produced masks. The revised raised foot is recovered; green edge contamination remains visible around some contours and must not be described as eliminated.

## Confirmed causes

- **Straight cut through the raised shin:** the once-per-second calibration missed the extended leg. The old park person crop started at normalized x=0.358697. Processing had already discarded the pixels outside that rectangle; later smoothing could not recover them. The failure is reproduced at frame 195 / 6.5 seconds. Calibration now scans every preparation frame, including soft person coverage, before selecting the crop.
- **Small missing regions:** whole-body/lower-third coverage ratios could pass while a hand disappeared. Repair now finds local connected gaps supported by the current frame's confident person guide. It does not paste a previous foot into a new pose.
- **Park-colored fringes:** the raw detailed matte sometimes includes background as opaque foreground. The old shader skipped opaque pixels, and the cache retained original park RGB under alpha. The new narrow boundary pass adjusts coverage using nearby foreground/background colors and removes estimated background color in linear light. The cache stores premultiplied foreground; preview, export, and floor reflections consume the same representation.
- **Blinking:** the detailed subject-lift path had no explicit motion-aware alpha history. The new pass warps the previous matte to the current frame using backward optical flow and accepts history with source-color and boundary support. Time discontinuities reset history.

## Strategies actually tried

All footage was processed locally. Initial native comparisons used consecutive frames at up to 2160-pixel short edge: all 212 park frames and the first 360 indoor frames. The selected pipeline subsequently processed the full 572-frame indoor clip.

| Strategy | Observed result and decision |
| --- | --- |
| Existing subject lifting and repair | Useful fine detail, but reproduced the clipped shin and contaminated boundaries. Insufficient unchanged. |
| Wider subject-lifting crop alone | Recovers crop coverage, but does not independently solve fringe or temporal instability. Excessively wide input also reduces effective subject detail. |
| Accurate and balanced person segmentation reused over the sequence | Faster in this Mac comparison; visibly coarser hands/feet and retained surroundings. Keep accurate segmentation as an identity/repair guide. |
| Official RVM fixed Core ML 1920×1080, downsample ratio 0.25 | Broader fringes on this full-body material. This preset alone is an inadequate basis for rejecting RVM. |
| Official dynamic RVM, recurrent states retained, ratios 0.4 and 0.6 | Native-detail park crop is 1066×1186. The 0.6 result improves substantially and remains a credible challenger. The 1080×1920 indoor 0.6 run covers all 572 frames; sampled empty-room output retains faint objects, entry/exit has residual edges, and the detached ball can be translucent. It is not an established replacement for person gating plus separate ball handling. |
| Native pipeline with full envelope, local repair, color refinement and motion-aware alpha | **Selected main path.** Directly fixes the reproduced crop error, keeps current ball validation, and is implemented in the shared preparation/rendering code. Controlled temporal ablation shows a modest stability improvement. |

The [same-crop park comparison](../artifacts/matting-strategy-study/rvm-native-same-crop.jpg), [RVM indoor samples](../artifacts/matting-strategy-study/rvm-indoor-review.jpg), and [native indoor samples](../artifacts/matting-strategy-study/native-indoor-review.jpg) show representative frames. RVM uses its foreground-color prediction and standard model compositing; the native cache uses linear-light compositing. These views are visual inspections, not ground-truth accuracy rankings.

The RVM full-body resolution guidance motivated the higher-detail trial: [official inference guidance](https://github.com/PeterL1n/RobustVideoMatting/blob/master/documentation/inference.md). Model files remain evaluation artifacts outside the app; no model or runtime dependency was bundled. Source: [official RVM repository and releases](https://github.com/PeterL1n/RobustVideoMatting). Native APIs: [Apple subject lifting](https://developer.apple.com/videos/play/wwdc2023/10176/) and [optical flow](https://developer.apple.com/documentation/vision/vngenerateopticalflowrequest).

## Shared implementation

- `StadiumSceneCalibration` scans all output timestamps at up to 30 fps using a 720-pixel guide, keeps the dominant person component, and builds a padded union envelope. This adds an offline preparation pass.
- `DetailedForegroundMaskProcessor.personRepairRegions` repairs spatially local confident-guide gaps. `repairedPersonRegions` is saved per frame for diagnosis.
- `ForegroundEdgeProcessor` and `ForegroundMatting.h` perform the boundary/color pass and temporal filtering before cache encoding. Flow uses a maximum 512-pixel image edge. There is no global erosion or green chroma key.
- `matteVersion: 2` identifies the linear-premultiplied RGB cache. `temporalRefinement` records whether temporal processing was enabled. The renderer decodes color before interpolation and composites alpha once. Old recordings retain their original decode path.
- Both interactive surfaces and `SceneMovieRenderer` honor the cache version; the floor reflection also uses corrected foreground. The ball detector/counting logic is unchanged.

## Measured verification

**Temporal ablation:** identical selected park pipeline with history disabled versus enabled, 212 frames. Both masks were mapped to the same 540×960 source coordinates; current-to-previous source flow and a photometric gate define the shared comparison region. Ball regions are excluded.

| Proxy | History disabled | History enabled | Change |
| --- | ---: | ---: | ---: |
| Mean absolute motion-compensated alpha change | 0.016888 | 0.015980 | 5.38% lower |
| Pixel/frame changes greater than 0.5 alpha | 15,170 | 13,717 | 9.58% fewer |

This measures stability under an approximate correspondence, **not segmentation accuracy or a guarantee of no blinking**. Earlier comparisons against the old phone cache were confounded by crop/shape changes and did not establish improvement. The controlled result is in [stability-final.json](../artifacts/matting-strategy-study/stability-final.json); `old` means history disabled and `new` means enabled.

- **57 tests passed**, zero skipped/failed. New regressions cover local hand repair, opaque background fringe removal with interior preservation, moving-edge temporal coverage/history reset, and physically correct soft-alpha compositing. See [test summary](../artifacts/matting-strategy-study/tests-verified-summary.json).
- Final Mac preparation: park 212 frames / 7.04 s, indoor 572 frames / 19.067 s. All eight cache/preview movies fully decode; source audio packet hashes match exactly. Both same-camera park comparison movies also pass. See [media verification](../artifacts/matting-strategy-study/media-verification.json).
- Park availability: no missing person or separate ball matte; 40 frames invoke local repair. Indoor: no ball patch when the person is absent and no missing separate ball in the active 6–12 s section; 152 frames invoke repair. Entry/exit and offscreen/held balls account for other absence flags. These are availability checks, not correctness scores.
- Real native cancellation returns no successful preview and removes that run's partial files: [cancellation verification](../artifacts/matting-strategy-study/cancellation-verified.log).
- Simulator playback displays the final cache with the explicit **Prepared Mac sample** label: [UI screenshot](../artifacts/matting-strategy-study/simulator-mac-preview.png). Vision inference was not run in the simulator.
- The final optimized development build was installed and launched on the paired iPhone 17 Pro Max. A fresh preparation completed 212 frames; retrieved metadata explicitly has `matteVersion: 2` and `temporalRefinement: true`. Its diagnostics show no missing person/ball matte and 39 locally repaired frames. All four retrieved movies fully decode with 212 frames and exactly preserved source audio packets: [phone media verification](../artifacts/matting-strategy-study/iphone-media-verification.json). See [fresh status](../artifacts/matting-strategy-study/device-verified-status.json) and `iphone-verified/`. The earlier `device-stale-status.json` and `iphone-previous-retrieved/` are old output and must not be treated as this validation.

Mac total preparation took about 67 s for park and 172 s for indoor. These are individual local runs, not a sustained-performance benchmark. The RVM timings are model-inference timings on Mac MPS and exclude equivalent ball processing; they are not directly comparable with full native preparation or evidence of phone throughput.

## Reproduction and remaining limits

Use `scripts/build-matting-review.sh` to compile the native CLI with the shared Metal implementation. `compare-video-matting.swift` records sequential native/fixed-RVM comparisons. `export-matting-source.swift` creates matching SDR crops, and `review-rvm-detail.py` runs the official dynamic model with recurrent states retained. `check-stadium-preview.swift` exercises the full preparer and cancellation. `review-matting-result.swift` renders two caches at identical timestamps and camera settings. `measure-matte-sequence.py` calculates the stability proxy.

Fine fingers/hair, grass-covered toes, severe blur, long occlusion, multiple people, and similarly colored foreground/background remain difficult. Local color estimation is heuristic; temporal flow can be wrong. H.264 color/alpha encoding remains lossy. A cleaner matte cannot reveal toes physically hidden by grass in the original footage. Further model adoption should be decided on held-out juggling clips with labeled boundary/temporal failures, target-phone memory/preparation cost, and appropriate distribution rights. The high-detail RVM trial deserves that comparison; it has not been proved universally better or worse here.
