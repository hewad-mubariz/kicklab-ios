# Review and validation

Open [index.html](index.html) for the screen gallery.

## Implemented

Shared SwiftUI tokens and components in SessionStyle.swift now define the teal surfaces, mint accents, headers, segmented tabs, buttons, stat cards and native intensity slider.

- Recording: compact dark HUD cards, consistent mint accents and a finer red recording ring.
- Processing: football orb, progress/checklist hierarchy and encouragement.
- Summary: compact crown and scattered gold flecks, paired stats, milestone cards and three consistent actions.
- Replay: portrait preview, compact five-option effect row, consistent Ball Style/Environment thumbnails and fixed bottom action.
- Stats: shared tabs, compact metric cards, labeled chart grid, anchored peak label and smaller consistency ring.
- Export: centered title, Original/Edited tabs, compact quality and share controls, secondary bottom actions.

Height values are formatted with units in the views; calculations are unchanged.

## Verification

- Final Debug build succeeded on iPhone 17 Pro / iOS 26.5 simulator.
- Inspected Summary, Processing, Replay, all three editor tabs, Stats Overview/Height, and Save & Share.
- Manually checked Summary → Replay → Summary → Stats → Save & Share navigation.
- Checked the restyled slider's value binding and fixed floating-point percentage display rounding.
- Compared recording-session lifecycle, replay selection/playback, and export function sections with the starting files: unchanged.
- No real-camera capture, Photos save, social share, or export was performed in this styling pass.
- Ball Style and Environment retain their existing placeholder behavior. Effect rendering itself is unchanged.
- Screenshots contain illustrative data and footage, not measured session results.

The longer DESIGN.md records the target direction. Alternate chart types, direct social integrations, and other future behavior described there remain for a later implementation pass.

## Debug preview

SessionDesignReview.swift and its launch entry are compiled only in Debug. Release continues to open ContentView normally.

Launch arguments:

```
--session-design summary
--session-video /absolute/path/to/design/juggling-flow/review-footage-wide.mp4
-kicklab.juggling.personalBest 999999
```

Supported screens: summary, effects, stats, share, processing. The personal-best launch override prevents the fixture score from changing saved records. Sample images/videos live outside the app target.

## Generated review media

Built-in imagegen was used to generate illustrative review footage only.

Saved stills:
- review-footage.png — initial framing
- review-footage-wide.png — final framing used in the gallery

Matching .mp4 files are static review clips created with ffmpeg. These are not shipped app artwork or user recordings.

Initial prompt:

Use case: photorealistic-natural. Asset type: illustrative test footage still for a football training app design review, portrait 9:16. Full body young adult male footballer with dark short hair, wearing plain black jersey, black shorts, black socks and black football shoes, no logos. He is juggling one black and white football with his raised right foot on a green football pitch at night. Head near upper 18 percent, feet near bottom 85 percent, entire person visible centered in frame, ball at lower center around 67 percent height. Background is atmospheric teal-black community football stadium, floodlights left and right, soft depth of field. Cinematic realistic sports photography, athletic movement, friendly premium training brand mood. No text, no UI, no frame, no watermark. Ball should have no glow or flames; the app draws its own effects.

Framing edit prompt (review-footage.png used as the edit target):

Use case: precise-object-edit. This is an illustrative video still for testing a mobile app layout. Keep the same adult footballer, clothing, ball, night pitch, lights, color grading and photographic style. Change only framing: pull the camera much further back. The entire player from top of hair to bottom of shoes must occupy the central 40 percent of image height, from 30% to 70% vertically, centered horizontally. The ball stays at the raised foot, around 57% image height. Extend the same sky and grassy pitch around him naturally. This extra framing margin lets multiple app preview crops preserve the head and ball. Portrait 9:16, no text, no UI, no logo, no watermark, no new people.

