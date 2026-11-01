# Download choices for large and fast clips

A camera clip imported at 4K or above 60 fps is slow to save, and a replacement ball makes it slower.
Tapping Download on such a clip now asks how to save it; smaller clips save straight away as before.

- **Faster** — 1080p at up to 60 fps, H.264. Clips of 60 fps or less keep their own rate.
- **Original** — the clip's own size and frame rate. Above 1080p it is saved as HEVC at 40 Mbit/s,
  or 60 Mbit/s above 60 fps. Above 60 fps it stays a MOV with the full-speed playback intent.

In the editor the Download button itself stretches, with a spring, into `✕ · Original · Faster`
over the session title; ✕ folds it back and a choice starts the download in the same button
([ReplayDownloadButton](../kicklab/Record/ReplayDownloader.swift)). The saved toast names what was
saved, such as "4K · 120 fps". Save & Share keeps its 720p and
1080p entries, now capped at 60 fps, and adds the original to the Quality menu
([SaveShareView](../kicklab/Record/SaveShareView.swift)). In-app recordings (720p, 30–60 fps) and
prepared stadium scenes never ask. The choices come from the clip's metadata in
[ExportChoice](../kicklab/Effects/VideoExportFormat.swift).

## Frames kept at 60 fps

A capped save keeps a frame once `1/60 − ½ source frame` has passed since the last kept one
(`VideoExportFormat.spacing`), so a 120 fps clip keeps every second frame and a 240 fps clip every
fourth. The outline pass uses the same rule.

For a replacement ball on an import of 100 fps or more, preparation reads outlines at that 60 fps
([BallVisualRefiner](../kicklab/Effects/BallVisualRefiner.swift)), so every frame the faster save
keeps has its own silhouette. Choosing the original asks
[SessionEffectsPreparation](../kicklab/Record/SessionEffectsPreparation.swift) for every frame
first; the replay preview uses the nearest outline in between. Effects only follow positions and
are unchanged.

## Measured

IMG_9064, 52 s, 4K, 120 fps HLG, Lava + Fire with the counter, on the iPhone 17 Pro Max
([ImportedClipCostTests](../kicklabTests/ImportedClipCostTests.swift), Release build):

| | Before | Faster | Original |
| --- | --- | --- | --- |
| Ball preparation | 204 s (every frame) | 142 s (60 fps) | 304 s on a warm phone |
| Spin | about 40 s | 43 s | 48 s |
| Save | 107–140 s at 1080p · 120 fps | 59 s | 182 s |
| Video | 1080p · 120 fps · H.264 · 89 MB | 1080p · 60 fps · H.264 · 88 MB | 4K · 120 fps · HEVC · 375 MB |

Preparation gains less than half because every pass still decodes all 4K frames. Frames at 5, 15.9
and 30 s of both saves match in counter, effect and ball placement; the 4K save is visibly sharper.

[DownloadChoiceTests](../kicklabTests/DownloadChoiceTests.swift) checks the choices and, on a
120 fps copy of the 60 fps fixture, that the faster save keeps exactly the 45 outlined frames, each
with a silhouette, and the original keeps all 90 at the source size.
