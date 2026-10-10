# Person boundary audit — 28 September 2026

Follow-up: the [implemented strategy comparison and selection](matting-strategy-selection.md) supersedes this audit's pending-experiment status. It includes sequential RVM trials, the reproduced crop failure, native boundary/temporal changes, and fresh device verification. The observations below describe the earlier implementation.

The current approach is a useful baseline, but the evidence does not support treating it as sufficient for consistently clean hands, hair, feet and motion blur. Keep the separate ball path; benchmark a dedicated person video-matting stage before spending more effort on global mask thresholds.

## Evidence and limits

Reviewed the current processor, repair, cache and Metal compositing code. Ran fresh Vision inference on the existing source-resolution park crops at 2.0, 4.2 and 5.0 seconds, comparing the selected instance mask before and after the production `bodyComponent` function. These are independently initialized Mac still-frame checks, not a sequential iPhone benchmark. Also extracted source/alpha pairs from the saved `iphone-final/foreground.mp4` at 2.0 and 4.2 seconds.

The user's screenshot has no timestamp or build identity, so this audit reproduces the class of hand-boundary problem; it does not establish the exact processing history of that screenshot.

[Hand comparison](../artifacts/person-boundary-audit/hand-stage-comparison.png): left is the original source, middle is the raw Vision cutout, right is the same cutout after connected-component cleanup. The rough fringe and retained source-background color are already visible in the middle. Cleanup makes little visible difference here. The source hand itself has limited detail; matting should preserve its visible coverage, not manufacture sharper fingers.

| Source time | Pixels changed by cleanup | Removed alpha coverage, in fully opaque pixel equivalents | Repair triggered |
| --- | ---: | ---: | --- |
| 2.0 s | 2,633 | 18.72 | No |
| 4.2 s | 1,999 | 14.10 | No |
| 5.0 s | 1,961 | 12.40 | No |

Each evaluated mask is 526 × 1,142. These are stage-difference measurements, not accuracy against ground truth. The large changed-pixel counts represent mostly very faint coverage. They do not establish that every removed pixel was correct or incorrect.

[iPhone source/alpha hand crop](../artifacts/person-boundary-audit/iphone-hand-2s.png) independently shows the delivered alpha simplifying the hand into a broad silhouette. It is decoded from the saved phone cache, so it includes encoding effects and cannot isolate those effects from native inference.

## Where the strategy falls short

1. `DetailedForegroundMaskProcessor.swift:31–46` selects a foreground instance using a person guide and accepts its scaled soft mask. This is image-based subject lifting. The main detailed person path has no explicit temporal matte propagation, recurrent state, or motion-aware edge validation. Reusing an image request is not a demonstrated solution to edge flicker. This audit did not measure flicker.
2. `needsPersonRepair` measures total confident-guide coverage and lower-third coverage. Small hand failures occupy too little of the body to trip these checks. It also cannot detect excess background retained by the detailed mask. All three sampled frames pass this gate.
3. `bodyComponent` keeps the largest component at alpha ≥32/255, plus a one-pixel soft border. This can discard disconnected/faint details and broader low-alpha motion blur. It is a plausible secondary weakness, but the sampled comparison does **not** implicate it as the main cause of the visible hand fringe.
4. `cleanForegroundStudy` estimates old-background colors near an edge. It cannot recover a missing finger or correct the silhouette. It skips alpha below 0.08 and above 0.98, so a background pixel incorrectly classified as opaque is not repaired. Locally estimating background color is also imperfect against detailed foliage.
5. Color and alpha are packed into an H.264 cache. The inspected phone file is 1952 × 1254, yuv420p. Lossy encoding is another possible source of boundary degradation; an uncompressed-versus-decoded comparison is needed to quantify it. It is not proven to cause the supplied screenshot. The sampled raw Vision result already has an edge problem upstream of encoding.

Apple describes subject lifting as an image-based request producing a soft segmentation mask. It is not accurate to call the existing output a purely binary mask: [Apple's subject-lifting session](https://developer.apple.com/videos/play/wwdc2023/10176/).

## Recommended next experiment

Keep native Vision as the baseline and keep the ball detector/matte separate. Compare the current person output with a dedicated video-matting model that estimates fine alpha while using information across frames. [Robust Video Matting](https://github.com/PeterL1n/RobustVideoMatting) provides recurrent temporal processing, foreground-color output and official Core ML exports. [MatAnyone 2](https://github.com/pq-yang/MatAnyone2) is another relevant human-matting benchmark. Neither has been run on Juggle Dude footage in this audit. Their published results are not evidence of an improvement here; model/code rights must be suitable before product integration.

For the comparison:

- Process identical consecutive source frames. Inspect hands, toes, hair, blurred kicks, body entry/exit and ball overlaps on both existing clips plus held-out juggling clips.
- Preserve native model alpha before cleanup, final alpha before encoding, decoded alpha, and composites over white, black, magenta and the actual stadium. This separates inference, cleanup, color spill and cache loss.
- Judge missing foreground, retained background and temporal stability separately. A per-frame `hasPerson`/`hasBall` flag is only an availability check.
- Compare conservative local boundary refinement as a smaller native alternative. Do not globally erode or blur: these trade fringes for thinner fingers or softer halos without resolving foreground identity.
- Measure preparation time and memory on the target iPhone. Keep the existing offline preparation workflow; do not assume a desktop demonstration proves mobile real-time performance.

No production mask settings were changed by this investigation. The added diagnostic compiled and ran successfully on the three samples; application tests were not rerun because application code was unchanged.

## Reproduce the stage audit

From the repository root:

```sh
mkdir -p artifacts/person-boundary-audit
swiftc -O -module-cache-path /tmp/kicklab-swift-cache \
  kicklab/Environments/ForegroundMaskProcessor.swift \
  kicklab/Environments/DetailedForegroundMaskProcessor.swift \
  kicklab/Environments/BallForegroundMask.swift \
  kicklab/Environments/BallCutoutTracker.swift \
  kicklab/Environments/BallImageLocator.swift \
  scripts/review-person-boundary.swift \
  -o artifacts/person-boundary-audit/review-person-boundary
artifacts/person-boundary-audit/review-person-boundary \
  artifacts/person-boundary-audit \
  artifacts/cutout-refinement/vision-park/2000-2160-source.png \
  artifacts/cutout-refinement/vision-park/4200-2160-source.png \
  artifacts/cutout-refinement/vision-park/5000-2160-source.png
```

Vision execution needs access to native GPU services. The outputs include raw/clean/guide composites, numeric mask PNGs and `stage-audit.json`.
