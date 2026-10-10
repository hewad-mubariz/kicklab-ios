# Forest Court

Choose **Replay & Effects → Environment → Forest Court**, or the **Forest** tab in the prepared scene preview. **Use Forest Court** saves the environment with camera framing; replay, counter editing and export use the existing shared pipeline.

The supplied woodland-court image guides this real-time interpretation: matte worn grass, off-white lines, warm daylight, spruce and oak foliage, distant mountain ridges, mossy banks, scattered stones, timber rails and benches, and dark canvas training banners. The floor has no mirrored signs or scenery.

## Implementation

- `ForestCourt.h` renders the clearing, short grass relief, worn soil, fallen leaves, foliage shadows, rocks, banks, timber enclosure and lamps in world space. Trees use fixed radial planes arranged in three depth layers, supporting camera rotation and parallax without rotating to face the camera. The distant mountain ridges are angular background geometry; this is not a full photogrammetric forest.
- `ForestSignage.swift` creates native Juggle Dude, PRACTICE. IMPROVE. REPEAT. and SAME GAME. DIFFERENT VIBES. lettering for the side banners.
- `PreviewEnvironment.forestCourt` uses shader index 3, preserving earlier identifiers and shader indices.
- `StadiumPreviewRenderer` binds the foliage and sign atlases to both preview and export. Foreground compositing, contact position, ball tracking and counter rendering retain their existing behavior.
- `scripts/review-forest-court.swift` produces landscape, portrait, side, reverse and picker-card renders with the shipping shader. Outputs are in `artifacts/forest-court/final/`. Native Mac renders took approximately 8–22 ms including submission and warmup; these are not iPhone performance measurements.

## Foliage asset and generation prompts

The built-in image-generation tool was used, with an initial generation followed by one atlas-spacing correction. No API/CLI fallback was used. The final project asset is `kicklab/Assets.xcassets/forest-trees-v2.imageset/forest-trees-v2.png`, a 1254 × 1254 RGBA image with genuine transparency. The requested size was 2048 × 2048; the tool returned 1254 × 1254. The shader samples each half separately and aligns the trunk bases to the ground. The earlier atlas is retained in `artifacts/forest-court/references/forest-trees-v1.imageset/`.

Initial prompt:

> Use case: photorealistic-natural. Asset type: transparent RGBA tree sprite atlas for a real-time native 3D forest football court. Create one square 2048x2048 image divided invisibly into TWO equal vertical columns, with ONE complete mature tree isolated in each column. Left half: tall European Norway spruce with irregular layered evergreen boughs, visible brown trunk at bottom, natural sparse gaps between delicate needle clusters. Right half: mature slender-trunk oak with an irregular rounded leafy crown and small green leaves, airy gaps through the branches. Both trees fill their own half from 4% below the top to 4% above the bottom; every branch and trunk stays completely inside its own column, no overlap between trees. Tree bases aligned on the same baseline. Photographic botanical realism, fine individual needles/leaves, deep natural forest green with modest warm sunlit olive tips. Neutral diffuse daytime illumination, no dramatic baked shadows. Genuine fully transparent alpha background everywhere outside the tree silhouettes including gaps inside their canopies; no sky, no ground, no grass, no cast shadow, no vignette, no checkerboard, no labels, no text, no border. Straight-on distant orthographic elevation, entirely visible trees including tips and bases, not illustrations or low-poly trees.

Final edit prompt (input: initial atlas):

> Edit this transparent tree atlas. Preserve photographic realism, foliage detail, natural green colors and real transparent alpha. Fix spacing and clipping ONLY: reduce each complete tree uniformly in size enough that it fits fully within its own half of the square image, with a clear transparent gutter on both sides of each tree. Left spruce must occupy ONLY x=4% through x=46% of full image; right oak ONLY x=54% through x=96%. No leaf, branch, antialias pixel or trunk may extend outside these limits, and no parts of one tree may appear in the other half. Both bases aligned at y=94%. Retain natural aspect ratios; ample transparent top margin is acceptable. Both whole trees including every canopy edge must be visible. This is a sprite atlas for graphics: transparent outside the trees and through canopy gaps; no sky, no ground, no added objects, no lettering, no checkerboard, no background.

## Validation

The environment regression includes Forest Court for opaque foreground preservation, a distinct background, and a complete camera turn. Persistence covers every environment. The full export regression includes Forest Court with a 14-second clip, audio and rotated counter. The simulator build and both regression suites passed. Test/build output is recorded in `artifacts/forest-court/tests.log`. A simulator check confirmed the Forest tab, prepared player/ball playback, counter and Use Forest Court action; the environment-card screen is captured in `artifacts/forest-court/final/environment-picker.png`.
