# Urban Court

Open **Replay & Effects → Environment → Urban Court**, then choose **Use Urban Court**. The environment cards scroll horizontally; the prepared preview also offers an **Urban** comparison tab. Selection, camera framing, counter overlays, and audio use the existing scene export pipeline.

The supplied night-court reference informed the design: navy cloud cover, a lit apartment skyline, warm floodlights, chain-link fencing above low concrete walls, teal crown and Juggle Dude lettering, benches, and a worn court with broken wet reflections. This is a procedural real-time interpretation, not a photographic reproduction of the reference.

## Rendering

- `UrbanCourt.h` defines a complete world-space enclosure, surrounding buildings, fence, benches, light fixtures, asphalt shading, and reflections. Looking sideways or behind the camera reveals geometry rather than a flat background.
- `UrbanSignage.swift` creates native lettering for the wall and skyline signs. The court reuses the existing concrete material for fine surface variation and adds procedural asphalt grain, wear, cracks, and wetness. Water collects in layered, warped surface depressions, with darker damp edges and separate asphalt/water roughness. Normal-based rain impacts expand and fade using playback time; a microfacet specular lobe breaks up the warm lamp reflections. Ripple detail fades with pixel footprint to avoid distant shimmer.
- `PreviewEnvironment.urbanCourt` uses shader index 2. Existing scene identifiers and indices remain stable.
- The shared shader preserves foreground compositing and the tracked foot-contact shadow. The floor does not mirror text, walls, buildings, fences, or the person. Puddles and rain ripples retain soft specular lamp highlights.
- The scene picker image is rendered by the shipping shader. `scripts/render-environment-cards.swift` can regenerate all scene cards.

## Visual review

`scripts/review-urban-court.swift` renders landscape, portrait, side, reverse, and card views. The reviewed outputs are in `artifacts/urban-court/final/`. `app-preview.png` shows the simulator running Urban Court with the existing prepared iPhone foreground and counter; the Urban tab and Use Urban Court action are visible. The final native Mac render run took approximately 5–15 ms per frame including CPU submission (not an iPhone performance benchmark).

## Wet-floor revision

The rain revision renders and a three-second animation are in `artifacts/urban-court/rain/final/`; `rain-preview.mp4` shows 90 frames at 30 fps. The current floor and picker card remove mirrored scene content; latest stills are in `artifacts/urban-court/no-reflections/`. `scripts/review-urban-court.swift` accepts a timestamp and `--animate` to reproduce the animation. Frame comparisons confirmed that only the floor changes over time (the upper scene is pixel-identical), while localized water ripples evolve. The simulator build and foreground/full-turn regression checks passed; results are recorded in `artifacts/urban-court/rain/tests.log`.

## Regression coverage

`IndoorArenaTests` now checks both Indoor Arena and Urban Court for background changes, opaque foreground preservation, and full-turn camera consistency. `SceneExportTests` covers all three environment identifiers through persistence and both Indoor and Urban through a 14-second video export with audio and a rotated counter. The simulator build and both test suites passed; the final log is `artifacts/urban-court/tests-final.log`.

The recorded person remains the existing flat foreground plane. No segmentation, ball detection, or tracking behavior was changed.
