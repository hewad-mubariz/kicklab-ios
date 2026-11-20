# Analytics chooser artwork

The 21 lab analytics now have illustrations composed for a small chooser tile, rather than reduced screenshots of the full replay overlay. The mint/yellow/cyan marks emphasize one idea per view. There are no fabricated measurement readouts in the artwork.

`sources/athlete.png` and `sources/touch-lens.png` were generated with the built-in image generation tool. Both depict fictional subjects; no owner's photograph was used as input. The exact prompts are in `prompts.json`. These sources are authoring inputs only and are not bundled separately in the app.

The shipping JPEGs are in `kicklab/Assets.xcassets/AnalyticsPreviews`. Touch Lens's old personal-footage thumbnail is replaced. Touch Lens still analyzes and displays the current session's own frames at runtime.

Regenerate all 21 assets on macOS from the repository root:

```sh
swift scripts/analytics-previews/render.swift
```

The renderer uses AppKit/CoreGraphics and the two generated source images. It produces uniform 600 × 360 JPEGs. Do not use the historical `LabViewsTests.testLabViewDiagramPreviews` footage study to regenerate shipping thumbnails.

The chooser fits the full illustration into a 90-point preview area. Existing graph styles continue to render actual session data when selected; tracking progress, selection, playback and export behavior are unchanged.

Visual review uses `AnalyticsTilesSnapshotTests`, with `TEST_RUNNER_TILES_OUT` pointing to an existing output folder. It renders all artwork in the real SwiftUI cards at 320- and 390-point widths, a four-column review sheet, and selected/loading states.

Validation on an iPhone 17 Pro Simulator running on the Mac: app build succeeded; both snapshot checks passed with no skipped tests. The resulting cards were visually reviewed at both widths. See `review-sheet.jpg` and `selection-and-loading.jpg`. The existing replay playback UI check could not reach the app: `ProReplayUITestCase` failed in StoreKit setup with `notEntitled`, including with ad-hoc signing enabled. No purchase or entitlement behavior was changed for this artwork update.
