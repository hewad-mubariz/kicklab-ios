# Touch counter sticker

Replay & Effects → **Counter**, the Counter button beside environment controls, and Save & Share share one counter configuration. Save & Share → **Include counter** adds the recorded touch count to either Original or Edited video. **Customize touch counter** opens a playing/scrubbable editor with ten styles: Particle Burst, Fire, Ice, Lightning, Galaxy, Neon Ring, Ripple, Flipboard, Pixel Burst and Golden Sparks.

The counter behaves like a sticker: drag to move, pinch to resize and twist with two fingers to rotate. Native UIKit pan, pinch and rotation recognizers run simultaneously, applying deltas in the fixed video coordinate space. The preview is pinned above the controls. Size, rotation, horizontal/vertical sliders and top/middle/bottom buttons provide precise alternatives. Reset restores position, size and angle without changing the style.

There is no elapsed-time overlay. The playback timestamp beside the scrubber is an editor control and is never exported. Loading existing settings retains the counter's style, enabled state, position and scale, initializes missing rotation to zero, and drops the old timer setting. Settings persist in `kicklab.export.overlays.v1`.

`ExportCounterTimeline` evaluates actual recorded touches at each video timestamp. Seeking backwards does not accumulate counts. Sessions without timed touch events show their known score with an explicit TOTAL TOUCHES label. Styles react to those touch events and briefly celebrate each multiple of 50; the count keeps advancing.

`ExportOverlayPlacement` stores normalized position, relative size and clockwise rotation. Rotation and resizing preserve the sticker center unless a frame edge requires clamping. Bounds account for the rotated corners, keeping the whole sticker within a 2.5% video inset. The same layout is used in the aspect-fit preview and 720p/1080p export, independent of black letterbox areas. The shared renderer rotates around the sticker center before drawing the count and its effects. Position, rotation, scale, style and enabled state all participate in the export cache key.

Validation: `artifacts/counter-sticker` contains the simulator/device build logs and 49 passing app tests. Counter tests cover rotated safe bounds at multiple angles/aspect ratios, resolution scaling, video-space dragging, simultaneous transform geometry, center preservation, rotated hit testing, migration from timer-enabled preferences, distinct deterministic styles, clockwise rendered direction and disabled-overlay output. The simulator UI was checked for removal of timer controls and a 29° rotated preview. A full physical two-finger interaction check remains useful on-device; simulator automation provides the equivalent size/rotation controls.

The real-video harness accepts `--effects-share`, `--effects-counter`, `--effects-badge <style>`, `--effects-quality 720|1080`, and `--effects-overlays <JSON path>`. `scripts/review-export-overlays.swift` renders the ten counter designs. Older validation files under `artifacts/export-overlays` describe the superseded timer experiment.

The normal Share-button result, `artifacts/counter-sticker/rotated-counter.mp4`, was decoded and visually checked: the counter retains its 29° clockwise tilt, and no elapsed-time overlay appears. Output is 1080×1920, 422 frames, 7.04 seconds. The AAC packet hash matches the original. `export-settings.json` contains only the counter; `verification.json` records its transform and media metadata. The corrected build was installed and opened on the connected iPhone.

Replacement environments now carry through the counter editor and final export. See [environment-export.md](environment-export.md) for the shared scene cache and full-length export checks.
