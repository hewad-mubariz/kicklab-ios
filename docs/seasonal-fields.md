# Snow Field and Beach Field

These two environments complete the current six-scene set. Select them in Replay & Effects → Environment, or use the horizontally scrolling Snow and Beach tabs in the prepared scene preview. The chosen environment and camera framing use the existing save, replay and export pipeline.

The supplied images guide real-time interpretations, rather than photographic replicas. Snow Field includes blue dusk lighting, snowy spruce, alpine terrain, a lit timber cabin, powder-like ground and falling snow. Beach Field includes warm sand, palms, a hut, surfboards, sunset water, foam and distant sails. Both retain KICKLAB training banners, court markings, benches and floodlights. Neither field mirrors signage or scenery on the floor.

## Implementation

- `kicklab/Environments/SeasonalFields.h` contains the shared analytic geometry, material shading, sky and weather. The ground, enclosure and props are world-space geometry. Trees use fixed planes; distant snowy mountains use an angular image backdrop. These are lightweight scenic representations, not full scanned terrain.
- `PreviewEnvironment` appends shader indices 4 and 5, preserving existing identifiers. `StadiumPreviewRenderer` binds the seasonal tree atlas and mountain texture for both preview and export.
- Snow and ocean animation use source playback time, so seeking and export follow the same animation timeline. Snow is occluded by scenery and applied before foreground compositing; the existing opaque player and ball pixels are preserved.
- The preview comparison control scrolls horizontally to accommodate Original plus all six environments. It brings the selected scene into view.
- `scripts/review-seasonal-fields.swift` renders landscape, portrait, side, reverse and picker-card images using the shipping shader. `--animate` adds 60 frames per environment at 30 fps.

## Generated assets and prompts

The built-in image-generation tool created the following assets. No CLI or API fallback was used.

### Tree atlas

Saved to `kicklab/Assets.xcassets/seasonal-trees-v1.imageset/seasonal-trees-v1.png`. The tool returned a 1254 × 1254 RGBA PNG with transparency; the prompt requested 2048 × 2048.

> Use case: photorealistic-natural. Asset type: transparent RGBA two-tree sprite atlas for native real-time football environments. One square 2048x2048 PNG with TWO completely separate isolated whole trees. LEFT half: realistic mature alpine spruce with dark blue-green needles and thick natural clumps of white snow resting on branch tops, exposed dark trunk base, irregular boughs, not a Christmas tree ornament. RIGHT half: realistic tall coconut palm, slightly curved textured brown trunk, spreading arching fronds with individually visible narrow green leaflets and some dry brown hanging fronds, no snow. Photographic detailed natural foliage, neutral diffuse light, suitable for shader relighting. CRITICAL BOUNDARIES: left tree entirely inside x=4%..46% of full canvas; right tree entirely inside x=54%..96%. There must be at least 8% full-canvas empty transparent gutter between trees and 4% transparent margin outside. Both whole trees including every branch tip, canopy edge and trunk base visible, absolutely no overlapping or clipping. Bases aligned y=94%; tallest tip may begin y=8%, shorter tree may have extra top space to retain natural proportions. Genuine transparent alpha outside each tree and in gaps among leaves/branches. No background, sky, ground, cast shadow, checkerboard, text, border, objects, or watermark. Orthographic straight-on elevation.

### Mountain backdrop

Saved to `kicklab/Assets.xcassets/snow-mountains-v1.imageset/snow-mountains-v1.png`, a 1536 × 1024 RGBA PNG.

> Use case: photorealistic-natural. Asset type: transparent distant alpine mountain ridge matte for a 3D winter football environment. Create a wide 3:2 photographic image of a continuous jagged alpine mountain range with snow on rocky faces and dark blue-grey vertical crags, cold blue late-afternoon ambient illumination with restrained pale peach light on a few upper edges. Composition: peaks occupy the middle third vertically, the highest peaks at left-of-centre and far right, a lower valley notch at about 68% across; the whole lower half is continuous layered mountainous terrain with distant dark conifer foothills, filling the image down to the bottom and both side edges. Every upper mountain silhouette edge must have genuine transparent alpha above it: absolutely no sky, no sun disc, no clouds, no plain opaque backdrop or checkerboard. High-detail natural rugged rock striations and broken snowfields, atmospheric depth between overlapping ridges. View from far away with a long lens, nearly frontal elevation. No foreground objects, buildings, people, roads, typography, watermarks, borders. This is a background terrain cutout, not a finished scene; terrain touches left, right and bottom edges but peaks have ample empty transparent space above.

## Validation

The simulator build and `IndoorArenaTests` / `SceneExportTests` suites passed. Both scenes are covered for foreground preservation, distinct backgrounds, a complete camera turn, saved framing, and 14-second exports with audio and a rotated counter. The suites also cover frame timing and rejection of incomplete legacy previews. The log is `artifacts/seasonal-fields/tests.log`.

Final native renders and two-second animation previews are in `artifacts/seasonal-fields/final/snowField/` and `artifacts/seasonal-fields/final/beachField/`. Front, side, reverse and portrait views were reviewed. Consecutive-time frames confirm animated snow and water. A simulator screenshot at `artifacts/seasonal-fields/final/beachField/app-preview.png` confirms Beach selection, the scrolling tabs, prepared player/ball playback, counter and Use Beach Field action.

These checks do not establish performance on physical iPhones. The next phase is video quality, playback and export refinement; no additional environment is planned in this scene set.
