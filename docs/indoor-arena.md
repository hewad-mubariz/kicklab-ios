# Indoor Arena

Open **Replay & Effects → Environment → Indoor Arena**. Once the foreground preview is prepared, the Original / Stadium / Indoor selector compares environments. Stadium and Indoor share the prepared video and timestamp; switching between them does not rerun segmentation.

## Design

The supplied indoor hall image and the [Motion Lab gallery](https://github.com/hewad-mubariz/react-native-motion-lab/tree/main/src/scenes/gallery) informed the lighting and material direction. This implementation uses native Metal, with a complete room around the camera: charcoal wall panels, structural columns, roof trusses, suspended white twin lights, warm wall lights, thin perimeter coves, service doors, and Juggle Dude signage. The sealed concrete floor has court markings, softened room reflections, a faint foreground reflection, and the existing foot-contact shadow.

The room is world-space geometry described through analytic ray intersections in `IndoorArena.h`. Camera rotation reveals the side and rear walls; it is not a fixed background image. The existing recorded-camera follow, drag/arrow look controls, zoom, and device-motion controls apply to both environments.

## Implementation

- `PreviewEnvironment.swift` identifies the scene independently of effect color grading.
- `StadiumPreviewRenderer.swift` selects the environment through the previously reserved `layout.w` uniform and binds the new material/signage textures.
- `IndoorArena.h` contains room intersections, surface shading, lights, court markings and reflection shading.
- `ArenaSignage.swift` draws the wordmark and motto into a native text atlas.
- `StadiumPreview.metal` composites the same prepared RGB/alpha foreground over either scene, adding a subtle indoor floor reflection.
- `StadiumInteractiveSurface.swift`, `StadiumPreviewView.swift`, and `ReplayEffectsView.swift` expose scene selection and paused-frame redraws.

The concrete texture was generated with the built-in image tool; [asset details and the final prompt](indoor-arena-assets.md) are recorded separately. Lights, lettering, reflections, room structure and court markings are rendered in code.

## Validation

The iOS simulator suite passed **43 tests in six suites**. The new Metal regression verifies that changing rooms changes the background while preserving opaque foreground pixels and that rotating a full turn returns to the same view. Simulator and signed iPhone builds succeeded. UI checks covered opening Indoor Arena from Replay & Effects, paused switching to Stadium, and camera rotation toward a side wall. The final build was installed and launched on the connected iPhone; preparation reported ready for all 212 frames of the 7.04-second sample (`artifacts/indoor-arena/device-status.json`).

`scripts/review-indoor-arena.swift` renders the actual shared shader against the prepared iPhone sample. Final review images are in `artifacts/indoor-arena/final/`, including the empty room, rear/side views, and the foreground at 0°, 30°, 90°, 180°, 270°, and 360°. These are native renderer outputs, not generated room illustrations. Mac render timings are not an iPhone performance benchmark.

## Current scope

Choose **Use Indoor Arena** to apply the room and camera framing. Replay, the nearby Counter editor and Edited Save / Share use the same rendered scene. Full-length export includes the selected touch counter, its transform, ball effects and original audio. See [environment-export.md](environment-export.md). The room supports 360° looking, but the recorded person remains a 2D foreground in the scene; the original video cannot reveal unseen sides of the body. Reflections are an intentionally inexpensive approximation, not path tracing or full volumetric lighting. This scene work does not change detection, ball tracking, or foreground-mask generation.
