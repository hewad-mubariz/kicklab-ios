# Juggle Dude code audit

Date: 10 October 2026. Baseline: working tree on commit `4e9ffbf`, including uncommitted work. Source references describe this snapshot and may move as other work continues.

The main priorities are reliable recording and cancellation, bounded video memory, reliable result syncing, and reducing work on the main thread. The project already has useful lifecycle, media parity, account isolation, and backend tests. The next step is to strengthen these boundaries, then optimize measured bottlenecks. A wholesale rewrite would put working behavior at unnecessary risk.

This is a static audit and prioritized review backlog. No application code, database, user media, or cloud configuration was changed for this audit. No new device profiling, UI automation, production security testing, or runtime reproduction was performed. “Confirmed” below means the implementation establishes the behavior or exposure; it does not mean the corresponding failure occurred on a device. Performance impact remains unmeasured unless explicitly described as an arithmetic estimate.

## Scope

| Area | Source files inventoried | Lines |
| --- | ---: | ---: |
| iOS application and native shaders | 234 | 45,616 |
| Unit and integration test sources | 70 | 9,219 |
| UI test sources | 23 | 2,168 |
| Backend functions, migrations and tests | 7 | 696 |
| Development scripts | 49 | 2,753 |
| Total | 383 | 60,452 |

Inventory includes Swift, Metal, native headers/Objective-C++, TypeScript, SQL, Python and shell source in those directories. Counts can change during concurrent development. Configuration, package locks and documentation were inspected separately. Generated builds, artifacts, design assets, model weights and vendored dependencies are excluded from these source totals.

All these areas received inventory and targeted pattern screening. Deeper call-path inspection concentrated on capture, analysis, media preparation/export, caches, account/authentication, results/history, subscriptions, leaderboard SQL and account deletion. This is not a claim that every line or shader formula received a full correctness proof. The separate `kicklab-lab` repository, training datasets, production AWS/Supabase settings, website, model accuracy across the entire dataset, and external CI settings are outside this audit.

## How to review the backlog

P1 means review first because the failure can lose a recording, freeze a flow, prevent synchronization, exhaust resources, or undermine public rankings. P2 means address in planned reliability/performance work. P3 means maintenance or compatibility hardening. There is no substantiated P0 finding here.

Evidence labels are **Confirmed** for visible control flow, **Profile** for a visible cost whose practical importance needs measurement, and **Decision** for an explicit product/architecture tradeoff. Effort is relative: **S** is a focused change, **M** crosses a component boundary, and **L** changes persistence, processing or server architecture. These are not calendar estimates.

| ID | Priority | Review item | Evidence | Effort |
| --- | --- | --- | --- | --- |
| A01 | P1 | Terminal recording errors are treated like dropped frames | Confirmed | M |
| A02 | P1 | Cancelled polling loops can stop yielding normally | Confirmed | S |
| A03 | P1 | A bad outbox item blocks later results | Confirmed | M |
| A04 | P1 | Long imports accumulate masks without a runtime budget | Confirmed / Profile | L |
| A05 | P1 before competitive launch | Leaderboard accepts client-declared scores and source | Confirmed / Decision | L |
| A06 | P2 | AR capture encodes metadata and writes files on the main thread | Confirmed / Profile | M |
| A07 | P2 | Graph snapshots repeatedly process the whole timeline | Confirmed / Profile | M |
| A08 | P2 | Graph export rasterizes SwiftUI on the main actor per frame | Confirmed / Profile | M |
| A09 | P2 | History reload performs synchronous full-directory reads | Confirmed / Profile | M |
| A10 | P2 | Outbox draining repeatedly decodes every remaining item | Confirmed / Profile | M |
| A11 | P2 | HDR proxy cache lacks eviction and subscriber cancellation | Confirmed | M |
| A12 | P3 | Older Save Share preview decodes from the start of the video | Confirmed / Profile | M |
| A13 | P2 | Pipeline stages repeatedly hash the same source file | Confirmed / Profile | M |
| A14 | P2 | Export waits synchronously for GPU completion per frame | Confirmed / Profile | L |
| A15 | P2 | Alpha processing allocates and copies large buffers per frame | Confirmed / Profile | M |
| A16 | P2 | Scene export creates multiple full-video intermediates | Confirmed / Profile | L |
| A17 | P2 | Video storage lacks a shared budget and ownership policy | Confirmed / Decision | M |
| A18 | P2 | Background history and sync depend on fully protected files | Confirmed / Device check | M |
| A19 | P2 | Export reuse key omits some rendered track inputs | Confirmed | S |
| A20 | P2 | Shot export can silently omit or truncate audio | Confirmed | M |
| A21 | P2 | High-frame-rate output policy differs between exporters | Confirmed / Device check | M |
| A22 | P2 | Inference failures can still produce a completed session | Confirmed / Decision | M |
| A23 | P2 | Scene preparation cannot cancel its initial refinement phase | Confirmed | M |
| A24 | P2 | Export lifecycle remains split across views and workers | Confirmed / Architecture | L |
| A25 | P2 | Failed local deletion marker write is ignored | Confirmed | M |
| A26 | P2 | Partial server deletion relies on another client attempt | Confirmed | M |
| A27 | P2 | Leaderboard ranks all qualifying users for each request | Confirmed / Profile | L |
| A28 | P2 | Avatar signing delays the entire leaderboard response | Confirmed / Profile | M |
| A29 | P2 | Session submission has no application-level volume budget | Confirmed / Deployment check | M |
| A30 | P3 | Deletion request size is checked after buffering its body | Confirmed | S |
| A31 | P2 | Fresh builds depend on manually supplied model assets | Confirmed | M |
| A32 | P2 | Validation needs a repeatable entry point and skip accounting | Confirmed / Process | M |
| A33 | P2 | Large components combine unrelated responsibilities | Confirmed / Architecture | L |
| A34 | P3 | Some diagnostic entry points compile outside Debug | Confirmed | S |
| A35 | P3 | Opening Photos has no failure handling | Confirmed / Compatibility | S |

## Recording and cancellation

### A01 Terminal recording errors are treated like dropped frames

**P1 · Confirmed · M.** [Recorder.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/Recorder.swift:140) returns `nil` for both `startWriting()` failure and `adaptor.append()` failure, as well as ordinary writer backpressure. [CameraSession.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/CameraSession.swift:525) continues offering the frame to analysis regardless of that result. The writer object can remain present while the recording is no longer viable. On Stop, the completion returns only a URL or `nil`, losing the underlying reason.

A disk/encoder failure can therefore leave counting active without a usable saved recording. Separate temporary frame drops from terminal writer failure. Propagate a typed error to the capture owner, stop promptly, and preserve any recoverable output and result metadata.

**Acceptance:** Inject writer startup failure and append failure after several good frames. Capture must leave recording state promptly, report the failure once, and allow a subsequent recording. Ordinary backpressure must remain nonfatal.

### A02 Cancelled polling loops can stop yielding normally

**P1 · Confirmed · S.** [ShotEffectsReplayView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectsReplayView.swift:467) waits for player readiness in a loop using `try? await Task.sleep`, without checking cancellation or imposing a deadline. [SaveShareView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/SaveShareView.swift:379) uses the same pattern while waiting for burn-in. The main juggling downloader already uses cancellation-aware sleep at [ReplayDownloader.swift line 104](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/ReplayDownloader.swift:104); the finding applies to the two cited waits. After cancellation, sleep throws immediately and the error is discarded; the loop can repeatedly poll without the intended delay. If readiness/export completion needs the main actor, this also competes with the work needed to exit the loop.

Replace these waits with cancellation-aware task results or observation. Handle failed player readiness explicitly and add a bounded readiness timeout. This identifies a cancellation defect; it does not establish that every dismissal currently triggers it.

**Acceptance:** Cancel while player status stays unknown and while an export is in progress. Both waits must exit promptly without a CPU spike or late UI mutation. A failed player must produce a recoverable error.

### A06 AR capture writes frame metadata on the main thread

**P2 · Confirmed cost, impact needs profiling · M.** [ShotGeometryCapture.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/ShotGeometryCapture.swift:178) explicitly consumes AR frames on the main actor. Its recording branch creates the writer, appends pixels, rebuilds plane boundary arrays, serializes sorted-key JSON, and calls `FileHandle.write` for each saved frame at [line 252](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/ShotGeometryCapture.swift:252). Roll events also serialize and write there at [line 937](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/ShotGeometryCapture.swift:937).

Storage latency and changing AR geometry consequently share the UI's frame budget. Move recording and metadata serialization into a dedicated bounded worker, preserving the exact frame/geometry pairing and original timestamps. Keep only presentation state on the main actor. Do not introduce an unbounded queue of retained ARFrames.

**Acceptance:** Record on the oldest supported phone while interacting with controls and under storage pressure. Measure main-thread frame time, capture drops, queue depth and timestamp correspondence before and after.

### A22 Inference failures can still produce a completed session

**P2 · Confirmed · M.** [VideoAnalyzer.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoAnalyzer.swift:301) converts detector exceptions into empty detections and increments a diagnostic counter, then finishes normally. Cache writes are correctly suppressed when errors occurred at [line 477](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoAnalyzer.swift:477), but that is different from informing the user or downstream result submission. [CameraSession.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/CameraSession.swift:555) also substitutes empty detections. [JugglingContactVerifier.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/JugglingContactVerifier.swift:65) stores a Vision error, after which contact buffering/checks are disabled until reset.

Ordinary uncertainty should remain distinct from a broken inference pipeline. Introduce session quality state with an error threshold and recovery policy. Decide when degraded results may be saved locally or submitted to a public ranking. Keep safe error categories and counts; do not expose raw frames or account data in telemetry.

**Acceptance:** Inject one transient model error, repeated detector errors and a pose warmup failure. Verify recovery, clear degraded-state behavior, and the intended result eligibility for each case.

### A23 Initial scene refinement is outside the cancellation handle

**P2 · Confirmed · M.** [StadiumPreviewModel.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/StadiumPreviewModel.swift:59) awaits `readySummary` before storing its `worker` at line 77. `cancelPreparation()` at [line 171](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/StadiumPreviewModel.swift:171) returns immediately when no worker exists. Cancelling during that first phase therefore cannot stop it through this method.

Give preparation one task handle covering refinement, calibration, segmentation and finalization. Preserve the existing policy that simply dismissing an environment sheet does not cancel session-owned work; an explicit Cancel must cover every phase.

**Acceptance:** Cancel separately during initial refinement, calibration, model loading and frame processing. Await teardown before retrying; do not publish a cancelled result or launch overlapping model passes.

## Memory and computation

### A04 Long imports accumulate masks without a runtime budget

**P1 · Confirmed growth, device threshold unmeasured · L.** [VideoAnalyzer.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoAnalyzer.swift:211) derives work from duration and FPS without a supported-duration or decoded-memory gate. It appends retained per-frame masks and recovered frames at [line 367](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoAnalyzer.swift:367). [SessionAnalysisStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/SessionAnalysisStore.swift:24) limits what is cached, but the check happens after the arrays already exist. Live capture also retains track/evidence arrays for the run in [CameraSession.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/CameraSession.swift:95).

For scale only: 10 minutes × 60 frames/sec × a 128×128 one-byte alpha mask is **562.5 MiB of alpha alone** if every frame has a maximum-size mask. This is an upper-size scenario, not a measured allocation; actual masks may be smaller and sparse. Model, decode, history and rendering memory are additional.

Define supported input budgets before analysis; stream or chunk retained masks, bound concurrent jobs, and handle memory pressure. Bound live session duration or persist long-run data incrementally. A disk-cache limit is not a runtime-memory limit.

**Acceptance:** Use short, 5-minute and 10-minute clips at 30/60/120 FPS, dense masks and sparse masks. Record peak resident memory, cancellation latency and completion behavior on the oldest supported device. Long inputs must be rejected clearly or processed within a documented budget.

### A07 Graph snapshots repeatedly process the whole timeline

**P2 · Confirmed · M.** [MotionStyleLayout.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/MotionStyleLayout.swift:139) filters touches, finds current points, derives peak ranges, scans completed peaks, scans points for the active flight, and recomputes streak state for each snapshot. [CaptureMotionGraph.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/CaptureMotionGraph.swift:29) filters, sorts and maps visible points again; with a replay duration the visible range is the full clip. [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:172) asks for a snapshot on every output frame.

This repeatedly visits clip-length arrays. A clip with N timeline points and F exported frames incurs repeated work proportional to F×N, plus sorting and derived calculations; it is not a constant-cost playhead update. Precompute static graph geometry, bounds and prefix statistics, then locate the playhead with indexed search. Use a rolling window for live capture and preserve gaps when reducing display points.

**Acceptance:** Compare snapshot time and allocations on 30-second, 5-minute and 10-minute inputs. Seek backward and forward and compare graph/count/streak output against existing fixtures.

### A08 Graph export rasterizes SwiftUI on the main actor per frame

**P2 · Confirmed · M.** [ExportMotionGraph.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/ExportMotionGraph.swift:55) constructs an `ImageRenderer` and SwiftUI graph card on the main actor for each image. The export loop awaits it for every video frame in [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:171).

That serializes a graphics step through the UI thread even when decoding and effects run elsewhere. Measure this independently from A07. Cache static card/text elements, reduce unnecessary redraws, or introduce a Core Graphics/Metal renderer sharing graph geometry with the preview. Keep visual parity; moving arbitrary SwiftUI rendering off actor is not a safe fix.

**Acceptance:** Export identical clips with graph off/on, measuring main-actor time, UI responsiveness, export FPS and allocations. Compare representative rendered frames for every graph style and run a real locked-phone export check.

### A12 Older Save Share preview decodes from the start of the video

**P3 · Confirmed; secondary route · M.** [EffectVideoGeometry.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/EffectVideoGeometry.swift:25) starts a new asset reader and consumes samples until the requested timestamp. [SaveShareView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/SaveShareView.swift:346) requests a thumbnail 35% into the clip. A thumbnail for a long video therefore decodes a substantial prefix just to retain one image. This is the older Save Share view, still referenced by post-session navigation and Debug review screens; the current main Download path uses a bounded-size image-generator thumbnail in [ReplayDownloader.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/ReplayDownloader.swift:129). Establish whether the older route should remain before optimizing it.

Cache a thumbnail during an existing pass, or seek to a bounded time range while maintaining the exact composition timestamp/mask contract. The existing comment explains why substituting an image generator blindly would risk alignment regressions.

**Acceptance:** Measure thumbnail latency near the start, middle and end of long VFR and constant-FPS clips. Validate actual frame timestamp, orientation and mask alignment against the existing sequential decoder.

### A13 Pipeline stages repeatedly hash the same source

**P2 · Confirmed · M.** Full content hashing is implemented safely in chunks by [SessionAnalysisStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/SessionAnalysisStore.swift:34), but invoked independently by [VideoAnalyzer.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoAnalyzer.swift:160), [BallVisualRefiner.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallVisualRefiner.swift:106), and [BallSurfaceTimeline.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallSurfaceTimeline.swift:204), before their cache lookups.

Reopening/changing effects can therefore reread a large original even for an eventual cache hit. Introduce an immutable imported-media identity whose content digest is computed once and passed through the job graph. Revalidate externally mutable files; do not replace content identity with URL equality alone.

**Acceptance:** Count bytes read and digest invocations across import → preview → material change → export → reopen. Confirm identical copies share results and changed content cannot reuse stale results.

### A14 Export waits synchronously for the GPU per frame

**P2 · Profile · L.** [MetalEffectEngine.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/Metal/MetalEffectEngine.swift:237) copies the source into scratch, encodes effects, commits, then calls `waitUntilCompleted()`. Both main exporters call this within a serial frame loop. This is a correct and understandable resource-lifetime boundary, but prevents overlap of that worker's CPU preparation and GPU work.

Use a Metal trace before changing it. If the wait dominates, try a small bounded pool of frames with command completion callbacks and explicit texture/pixel-buffer leases. Do not remove the wait while reusing the same scratch textures.

**Acceptance:** Record CPU/GPU utilization and p95 export frame time. A pipelined version must retain timestamp order, memory bounds, cancellation behavior and pixel parity under repeated exports.

### A15 Alpha processing allocates and copies large buffers per frame

**P2 · Profile · M.** [LosslessAlphaCache.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/LosslessAlphaCache.swift:28) allocates raw and encoded arrays, copies alpha pixel by pixel, compresses, then constructs `Data`. The reader at [line 82](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/LosslessAlphaCache.swift:82) allocates decoded bytes and a new pixel buffer for each different requested frame, then copies again. At the preparer's maximum 1080×1920 cache size, one alpha plane is about 2 MiB before compression.

Reuse compression scratch and appropriately pooled output buffers. Consider decoding directly into a compatible destination while respecting stride and ownership. The existing mapped file and one-frame cache are useful and should remain bounded.

**Acceptance:** Measure allocation count, CPU time and peak memory during preparation and replay. Preserve lossless alpha byte equality, exact timestamp lookup, corrupt-cache rejection and safe overlapping consumers.

### A16 Scene export creates multiple full-video intermediates

**P2 · Profile · L.** [StadiumPreviewPreparer.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/StadiumPreviewPreparer.swift:65) prepares a high-resolution source pipeline, calibration, original/foreground videos and lossless alpha. [SceneMovieRenderer.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Environments/SceneMovieRenderer.swift:15) renders another full movie. [ReplayDownloader.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/ReplayDownloader.swift:88) then passes that scene into the ball/overlay exporter for another decode/encode pass.

These passes serve real fidelity and reuse requirements. Their combined CPU, disk and energy cost needs an end-to-end budget. Consider compositing scene, ball and overlays into one final writer while retaining reusable foreground preparation. Avoid rerendering an unchanged scene and preserve source audio once.

**Acceptance:** Measure total time, bytes written, peak disk use, energy and visual parity for original, ball-only, graph-only and scene+ball+graph outputs. Optimize the dominant pass rather than lowering all quality settings.

## Storage and synchronization

### A03 A bad outbox item blocks later results

**P1 · Confirmed · M.** [PlayerStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerStore.swift:18) decodes every outbox JSON using throwing `map`; one corrupt record prevents loading the entire queue. Its sync loop at [line 294](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerStore.swift:294) always submits `pending.first`. All failures enter the same retry path. [PlayerData.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerData.swift:181) discards HTTP status/error classification behind `requestFailed`.

A permanently rejected first result, such as a conflicting idempotency payload or invalid timestamp, is retried indefinitely and later valid results cannot advance. Corrupt files cause the same queue-wide blockage before any request is sent.

Decode records independently, quarantine unreadable entries, classify permanent validation/auth/rate-limit/transient errors, and let unrelated valid entries continue. Keep rejected results visible and recoverable; do not silently delete them. Preserve existing per-account ownership and idempotency.

**Acceptance:** Queue one malformed file, one permanently rejected result and one valid result. The valid result must sync, invalid entries must have an actionable state, and transient failures must still retry without duplicates or cross-account writes.

### A09 History reload performs synchronous full-directory reads

**P2 · Confirmed · M.** [SessionHistoryStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/History/SessionHistoryStore.swift:29) executes on the main actor and calls synchronous library/outbox enumeration and decoding. [SessionHistory.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/History/SessionHistory.swift:163) reads and sorts all local metadata. Cloud page loading writes each item and reloads the directory at [SessionHistoryStore.swift line 141](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/History/SessionHistoryStore.swift:141). Account changes and saving can trigger the same work.

Move storage operations behind a dedicated storage actor and publish immutable results guarded by the existing account generation. Maintain an index or embedded database and page local history as it grows. Avoid reloading the full library to update one row.

**Acceptance:** Open, refresh and append history with 100, 1,000 and 10,000 metadata records. Measure UI stalls and ensure account switching during reads never publishes another account's results.

### A10 Outbox draining repeatedly decodes all remaining records

**P2 · Confirmed · M.** [PlayerStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerStore.swift:297) reads and sorts the entire pending queue before sending only its first result, then repeats. Draining N entries performs approximately N+(N−1)+…+1 record reads, excluding retries. Work is off the UI thread here, but remains quadratic disk/decoding work.

Load a bounded batch once, advance it, then refresh when new entries arrive. Alternatively share the persistent index from A09. Preserve generation checks and late-success ownership semantics.

**Acceptance:** Drain 1,000 synthetic results through a local service stub and count file decodes. Work should scale approximately linearly, including new entries arriving during the drain and account switching.

### A11 HDR proxy cache lacks eviction and subscriber cancellation

**P2 · Confirmed · M.** [EffectPreviewCache.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/EffectPreviewCache.swift:9) keeps completed tasks in a process-wide URL dictionary forever; successful entries are not removed, their output existence is not revalidated, and proxy files have no eviction policy here. A detached render is awaited without forwarding waiter cancellation. Different source URLs can start independent full-video transcodes.

Add explicit completed entries, file validation, a disk budget, bounded render concurrency, and subscriber-aware cancellation. Do not cancel shared work while another replay/export still needs it. Distinguish a deliberately retained reusable proxy from an abandoned temporary file.

**Acceptance:** Open many HDR clips, cancel preparations, remove a cached proxy, and request the same source concurrently. Check bounded disk/task growth, correct regeneration and no duplicate transcodes.

### A17 Video storage lacks a shared budget and ownership policy

**P2 · Confirmed policy gap · M.** [ContentView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/ContentView.swift:27) copies imported movies to temporary storage. [SessionHistory.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/History/SessionHistory.swift:189) copies originals into durable per-session history. [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:120) creates export outputs, and [ShotEffectsReplayView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectsReplayView.swift:715) retains successful output URLs. Cleanup exists for several cancellation/error paths and scene folders; it is not absent everywhere. Durable history supports individual replay removal.

The reviewed paths have no shared preflight free-space check, temporary-file registry, or whole-library storage budget. Large imports, retained originals, HDR proxies and multiple effect exports can coexist. Specify ownership for original, replay, proxy, partial and Photos-saved output; clean only regenerable/unreferenced files. Show users retained replay size and offer explicit bulk management instead of silently deleting originals.

**Acceptance:** Track disk use across repeated edit/export cycles, successful Photos saves, cancellation and relaunch. Simulate low space. Active sources and the user's only durable video copy must remain protected.

### A18 Background history and sync depend on fully protected files

**P2 · Confirmed policy mismatch; device reproduction needed · M.** [SessionHistory.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/History/SessionHistory.swift:200) marks archived replay files `.complete`; metadata and outbox files also use `.completeFileProtection`. Import/export temporary media instead uses `.completeUntilFirstUserAuthentication`, for example [ContentView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/ContentView.swift:31). Apple's Complete Protection class becomes inaccessible after the phone locks. [Apple Data Protection classes](https://support.apple.com/en-ke/guide/security/secb010e978a/web).

The current sync path must read the outbox and write history after a server response; these accesses can fail when the phone locks even if runtime remains available. Inaccessible history records are skipped by `try?` decoding and may temporarily disappear from a reload. Archived video is currently opened through a simple history player; this audit did not find a history-to-editor export route, so it does not claim an existing export-from-history failure. Define which background operations wait for protected data and which need access after first unlock. Keep stronger archive protection where appropriate, and handle protected-data availability explicitly.

**Acceptance:** On a passcode-protected physical phone, lock while a queued result is uploading, while history is being persisted, and during a fresh-import export. Verify each operation completes or waits/retries on unlock without losing metadata or showing an empty library as authoritative. Do not broadly weaken protection as a shortcut.

### A25 Failed local deletion marker write is ignored

**P2 · Confirmed · M.** [PlayerStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerStore.swift:112) uses `try? queue.markDeleted(owner)` after remote deletion has succeeded. The in-memory guard blocks late writes, but if the durable marker fails and subsequent cleanup also fails, that pending cleanup can be forgotten after process restart. [AccountStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Account/AccountStore.swift:109) nevertheless tells the user cleanup will retry when reopened.

Persist cleanup intent before relying on the retry guarantee and preserve a recoverable owner identifier until cleanup is durable or complete. Distinguish marker-write failure from file-removal failure and avoid exposing deleted account data during recovery.

**Acceptance:** Fault-inject marker creation/write failure and directory removal failure, then recreate the stores. Cleanup must still be discoverable, or the UI must accurately explain that automatic retry could not be scheduled.

## Export correctness and lifecycle

### A19 Export reuse key omits some rendered track inputs

**P2 · Confirmed · S.** [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:38) hashes frame time, mask presence mode and alpha bytes for its completed-request reuse key. It omits ball coordinates, dimensions, mask rectangle/dimensions, and other geometry consumed by the renderer. The request also identifies the source by URL rather than immutable content identity.

A changed track with unchanged timestamps/alpha can match the previous request and return an old export. Use an immutable analysis revision/content identity plus complete render-relevant inputs. Compute expensive track digests off the main actor or once when analysis is finalized.

**Acceptance:** Change only ball position, box size, mask rectangle, then source content at the same URL. Each relevant change must invalidate the output; an identical request should reuse it.

### A20 Shot export can silently omit or truncate audio

**P2 · Confirmed · M.** [ShotEffectExporter.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectExporter.swift:51) drops audio when reader attachment fails. At [line 79](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectExporter.swift:79), inability to add/start audio input also becomes `nil`. `feedSound` interprets no next sample as completion, while the final checks at [line 134](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectExporter.swift:134) inspect the video reader and writer but not a failed sound reader.

Having no source audio is legitimate; failing to preserve existing audio should be a distinct error or explicit user-approved fallback. Check sound reader terminal status and track coverage, and retain enough error information to diagnose unsupported formats.

**Acceptance:** Export sources with no audio, normal audio, offset audio, unsupported passthrough audio and a truncated audio stream. Verify expected duration/alignment or a clear failure instead of reporting silent success.

### A21 High frame rate output policy differs between exporters

**P2 · Confirmed divergence; Photos behavior requires device validation · M.** [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:115) deliberately uses MOV above 60 FPS and writes full-frame-rate playback intent to address Photos slow-motion interpretation. [ShotEffectExporter.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectExporter.swift:28) always creates MP4 and does not apply that policy.

This is a specific example of fixes drifting between export paths. It does not prove every high-FPS shot currently plays slowly, because source and replay-clock transformations matter. Share the container/metadata/cadence policy while preserving intentionally selected slow-motion effects.

**Acceptance:** Save 30/60/120/240 FPS shots with original timing and with explicit time effects. Compare duration, frame timestamps, audio and actual Photos playback against the corresponding juggling exports.

### A24 Export lifecycle remains split across views and workers

**P2 · Architecture · L.** [ReplayDownloader.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/ReplayDownloader.swift:9) already provides a useful typed lifecycle for juggling, but delegates to another independently owned task in [BallStyleBurnIn.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/BallStyleBurnIn.swift:33) and polls its state. Its cancellation catch calls `burnIn.cancel()` without awaiting render teardown. [ShotEffectsReplayView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectsReplayView.swift:684) contains a separate render/save/notification sequence, and the older Save Share screen has another one. [VideoBackgroundWork.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/VideoBackgroundWork.swift:60) coordinates runtime leases but stores jobs only in memory.

Extend the existing downloader boundary into a shared export job model with typed phases, explicit cancellation ownership, awaited teardown, output cleanup and one completion contract. In particular, retry must not reach `burnIn.export` while its previous worker is still exporting, because that method simply ignores overlapping calls. Views should observe it. Persist enough job intent to explain an interrupted job after process termination; do not promise iOS will continue work after a force quit. Keep path-specific renderers, but share lifecycle/media policies.

**Acceptance:** The same lifecycle suite should cover juggling and shots: close editor, background, lock, cancel, deny Photos access, save, retry, and relaunch after interruption. Completion notification/navigation must happen once and only after Photos commits.

## Backend and account reliability

### A05 Leaderboard accepts client-declared scores and source

**P1 before a competitive public launch · Confirmed trust boundary · L.** [The submission RPC](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:76) trusts the authenticated caller's count, duration, `recording`/`gallery` classification and completion date. Schema bounds allow up to 1,000,000 touches with duration as low as 1 ms at [line 54](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:54). [Ranking](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:134) includes `device_reported` rows, excluding only rejected ones.

RLS prevents writing another user's identity; it does not verify a score. A modified client can submit its own invented score or label an import as a recording. This is explicitly documented as device-reported in the schema, so treat it as an unresolved product trust decision rather than a newly discovered authentication bypass.

Choose the leaderboard's trust level. Add plausible score/duration checks, version policy and moderation visibility; stronger competition needs an independently verifiable session/evidence protocol. Client-side checks or attestation alone do not prove the count is true.

**Acceptance:** In an isolated database, submit impossible count/duration combinations and forged source labels with an ordinary authenticated identity. Verify the chosen policy and ensure legitimate offline sessions remain supported.

### A26 Partial server deletion relies on another client attempt

**P2 · Confirmed · M.** [delete-account/index.ts](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/functions/delete-account/index.ts:123) revokes Apple authorization, marks the profile as pending deletion, deletes avatar bytes, then deletes the auth user. Failure after the marker intentionally leaves writes blocked and visibility disabled. The function returns an error, but the reviewed backend contains no worker to reconcile outstanding deletion markers automatically.

If the client never retries, a partially deleted account can remain pending indefinitely. Add an idempotent server-side deletion state machine and reconciliation policy, with explicit Apple revocation progress and narrowly scoped admin operations. Existing retry handling for a user already deleted is useful and should remain.

**Acceptance:** Fail each external step independently. Resume after service recovery without exposing the profile, recreating data, or losing track of pending deletion. Test the Apple-linked case separately.

### A27 Leaderboard computes the full ranking for each request

**P2 · Profile before scale · L.** [The leaderboard query](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:130) computes each user's best session, ranks qualifying users, computes around-me entries and counts players before returning the limited top list. `p_limit` limits output, not total ranking work. The date-led partial index at [line 73](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:73) does not by itself make the all-time per-user selection/ranking constant-cost.

Benchmark realistic data using `EXPLAIN (ANALYZE, BUFFERS)` in a nonproduction database. Consider maintained per-user bests, weekly aggregates, suitable indexes, and short-lived result caching. Preserve moderation, opt-out, ties and week-boundary behavior.

**Acceptance:** Measure week/all-time and around-me queries at increasing session/user counts and concurrent reads. Set a query latency/cost budget from those measurements before choosing a materialization strategy.

### A28 Avatar signing delays the entire leaderboard

**P2 · Confirmed · M.** [PlayerStore.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerStore.swift:328) fetches rankings, then creates one signing request per unique avatar and waits for the whole task group before returning any entries. [PlayerData.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Profile/PlayerData.swift:146) requests individual 5-minute signed URLs; requests have a 30-second timeout. With the current 50-entry limit and up to three around-me rows, this can add up to roughly 53 signing requests before the table appears.

Publish ranks/names immediately with placeholders. Cache signed URLs until shortly before expiry, bound concurrent signing, and investigate batch signing while retaining the private bucket and visibility policy. Failed images should not delay usable scores.

**Acceptance:** Load a full board with slow and failing avatar requests. Ranking text must appear independently; repeated refreshes should reuse valid links and account/visibility changes must invalidate appropriately.

### A29 Session submission has no application-level volume budget

**P2 · Confirmed in repository; deployment controls unverified · M.** [The submission RPC](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/migrations/202610090001_profiles_and_juggling.sql:92) prevents overwriting the same `(user_id,id)` but accepts fresh IDs without a per-user submission budget. The client serializes its own queue; a modified client need not. Authentication-provider rate limits would not establish a session-submission quota.

Determine actual gateway/database limits, then add an application policy that bounds abusive writes while permitting offline catch-up. Couple this with A05, but keep volume limits separate from score authenticity. Monitor rejection counts and storage/query growth without logging bearer tokens.

**Acceptance:** Use an isolated environment to submit large bursts of unique IDs from one account and concurrent normal users. Verify bounded load and fair catch-up behavior, including retry guidance.

### A30 Deletion request body is buffered before its effective limit

**P3 · Confirmed · S.** [delete-account/index.ts](/Users/hewadmubariz/Desktop/projects/kicklab/supabase/functions/delete-account/index.ts:113) checks `Content-Length`, then uses `req.text()`, then checks string length. A missing or misleading length can cause the entire body to be buffered before rejection. Authentication occurs first, and infrastructure may impose another limit; this is not evidence of an unauthenticated production denial of service.

Read the body with a byte cap and abort as soon as the limit is exceeded. Apply a request deadline and retain the strict field allowlist.

**Acceptance:** Send oversized authenticated streamed bodies with absent/mismatched length and multibyte characters. Reject after the configured byte budget rather than after reading the whole body.

## Architecture and development workflow

### A31 Fresh builds depend on manually supplied model assets

**P2 · Confirmed · M.** [.gitignore](/Users/hewadmubariz/Desktop/projects/kicklab/.gitignore:23) excludes `.mlpackage` directories and states that fresh clones need models copied manually. [README.md](/Users/hewadmubariz/Desktop/projects/kicklab/README.md:1) contains only the project title. Production model selection is centralized at [BallDetector.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/BallDetector.swift:183), but the reviewed setup has no root-level reproducible model acquisition/verification workflow.

Provide a model manifest with immutable version, checksum, input/output contract, licensing location and trusted retrieval instructions. Add a preflight that reports missing/mismatched models and account config clearly. Document Xcode version, deployment target, scheme, build/test commands and local backend prerequisites. Keep credentials out of the manifest.

**Acceptance:** A clean checkout on another Mac can obtain the exact expected models, verify hashes, build, and run the documented test subset without relying on this machine's Downloads directory or old artifacts.

### A32 Validation needs one repeatable entry point and skip accounting

**P2 · Process · M.** The repository includes substantial media, lifecycle, backend and account tests. [scripts/test-account-backend.sh](/Users/hewadmubariz/Desktop/projects/kicklab/scripts/test-account-backend.sh:1) is a useful isolated SQL runner. Device-specific suites intentionally skip without hardware/fixtures, for example [VisualInferenceThroughputTests.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklabTests/VisualInferenceThroughputTests.swift:52) and [JugglingPhoneValidationTests.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklabTests/JugglingPhoneValidationTests.swift:15). No repository CI workflow or unified root validation entry point was found in the screened files; external CI was not inspected.

Define a fast deterministic lane, a Release build lane, backend function/SQL lanes, and a scheduled physical-device media/performance lane. Report required tests that skipped separately from passed tests. Baseline performance budgets by device/OS/fixture instead of treating a simulator pass as evidence for GPU, thermal, lock or Photos behavior.

**Acceptance:** One documented command produces build/test/skip summaries and fixture/model identities. A missing required device fixture must make the relevant validation lane incomplete, not silently green. Avoid rerunning expensive visual studies for unrelated UI edits.

### A33 Large components combine unrelated responsibilities

**P2 · Architecture · L.** [ShotGeometryCapture.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/ShotGeometryCapture.swift:13) combines AR session ownership, video recording, geometry persistence, calibration, ball tracking and UI state. [ShotEffectsReplayView.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/PowerShot/ShotEffectsReplayView.swift:1) owns preparation, playback, editing and saving. [BallDetector.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/BallDetector.swift:257) combines model loading, preprocessing, output decoding, retry and recovery policy. [EffectShaders.metal](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Effects/Metal/EffectShaders.metal:1) contains 1,737 lines spanning effect implementations. File length alone is not a defect; these cross-cutting responsibilities make policy drift harder to detect.

Extract boundaries incrementally: CaptureWriter, AnalysisPipeline/Result, MediaRepository, ExportJob and model-specific inference adapters. Keep counting observations distinct from appearance-only repairs, as the current code deliberately does. Replace string/Boolean combinations used as operation state with typed states at boundaries. Gradually enforce concurrency ownership rather than adding more `@unchecked Sendable` annotations.

**Acceptance:** Each extraction preserves the existing fixture and lifecycle results, has one clear mutable-state owner, and removes duplicate policy decisions. Start with a real defect from this backlog, not a general file-splitting campaign.

### A34 Some diagnostic entry points compile outside Debug

**P3 · Confirmed · S.** [kicklabApp.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/kicklabApp.swift:43) checks design/capture/benchmark launch arguments outside its later `#if DEBUG` branch. [DetectorPhoneBenchmark.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Detection/DetectorPhoneBenchmark.swift:8) is also not gated as a whole. Many other review views correctly are Debug-only, including sign-in and leaderboard concepts. Production model selection is fixed; this is not a claim that old launch flags can freely change it.

Put intended development-only entry points in a separate review target or gate them consistently. Centralize experimental flags and document intentional release diagnostics. Ordinary users supplying launch arguments remotely is not an established threat here; this is scope and maintenance hardening.

**Acceptance:** Inspect a Release build's reachable routes and diagnostic behavior. Production launch and public app entry points must not activate review recording/export flows; Debug review commands must remain reproducible.

### A35 Opening Photos has no failure handling

**P3 · Confirmed control flow; compatibility dependency · S.** [VideoSaveCompletion.swift](/Users/hewadmubariz/Desktop/projects/kicklab/kicklab/Record/VideoSaveCompletion.swift:43) clears `pendingPhotos` and opens `photos-redirect://` without checking success. The source comment describes the scheme as owned by Photos, but the reviewed [Apple URL Scheme Reference](https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/Introduction/Introduction.html) does not document a Photos contract. The reference is archived; absence there is not proof that the scheme fails on current iOS.

Treat the redirect as best effort, handle the open completion result, and retain a useful saved-video confirmation/share fallback. Do not promise navigation to the exact new asset or assume App Store rejection solely from this code.

**Acceptance:** Test successful and failed URL opening, notification tap while inactive, repeated activation and denied notification permission. A failed redirect must not erase confirmation that the video was saved.

## What is already worth preserving

- Capture and counting are separated with a bounded live-frame buffer. Do not replace it with a task for every camera frame.
- The offline analysis scheduler serializes expensive detector work and cancels queued waiters. Several preparation caches already share in-flight work.
- Analysis caches validate stored structures and enforce disk/mask limits. The problem in A04 is the earlier runtime accumulation, not the absence of any limits.
- Result submissions are idempotent and per-account. The SQL uses RLS, restricted grants and explicit function search paths. Fixing A05/A29 should preserve those controls.
- Authentication uses SDK-managed sessions, PKCE, Keychain storage and strict email callback parsing. The mobile service does not require a service-role key.
- StoreKit entitlement decisions accept verified transactions and handle revocation/upgrades. No client subscription bypass was established in the reviewed production path. Whether Pro follows an Apple account or an app account remains a product policy, not automatically a bug.
- Backend deletion verifies the caller, validates Apple identity before revocation, removes actual avatar bytes, and handles an already-deleted user retry. Local deletion has guards against late writes recreating data.
- Frame identity, visual-only recovery separation, VFR fixtures, CPU/GPU parity tests and corrupt alpha-cache validation are valuable correctness work. Performance optimization must retain them.
- Debug concept screens are generally gated. Their source size should not be mistaken for equivalent Release runtime cost.

## Suggested review sequence

1. **Protect recordings and progress:** A01, A02, A03. Add focused failure-injection coverage while fixing each behavior. These have clear failure mechanisms and do not require architectural redesign.
2. **Define workload and storage limits:** A04, A17, A18. Agree on supported clip length/FPS and lock behavior, measure memory/disk, then implement limits and ownership.
3. **Remove UI-thread costs:** A06, A09, A07, A08. Measure separately so improvements are attributable.
4. **Unify media correctness and job behavior:** A19–A24, A11. Extract only the policies needed for reliable cancellation, caching, audio, cadence and completion.
5. **Prepare accounts and ranking for growth:** A05, A25–A30, A10. Decide ranking trust before public competition; use isolated load/fault tests for backend changes.
6. **Optimize measured media bottlenecks:** A12–A16 and A28. Avoid speculative rewrites of model or shader internals.
7. **Make the work reproducible:** A31–A35. Begin build/fixture documentation early, then require the relevant validation lane for each change.

## Measurement plan

Use a fixed fixture manifest containing content hashes, expected duration/FPS/orientation, audio ranges, reviewed touch events and expected visual witnesses. Keep a short smoke corpus plus long-input stress fixtures.

| Workload | Capture measurements | Important variations |
| --- | --- | --- |
| Live juggling | Frame arrival/save/analysis rates, drops, p95 processing, peak memory, thermal state | Front/back lens, 30/60 FPS, shaky camera, repeated sessions, low storage |
| AR distance | Main-thread frame time, write latency, pending buffers, frame/geometry alignment | Many plane vertices, changing tracking state, calibration loss |
| Import and analysis | Decode/model/contact/repair time, hashes/read bytes, masks retained, cancellation latency | 30/60/120/240 FPS, VFR, HDR, portrait/landscape, 30 sec/5 min/10 min |
| Replay and graphs | Main-thread time, snapshot allocations, GPU time, retained memory after close | Every graph style, backward seek, repeated clip changes |
| Export | Time per stage, CPU/GPU overlap, energy, peak memory/disk, audio and timestamp parity | Graph off/on, material off/on, scene off/on, original timing/time effects |
| Background jobs | Phase transitions, cancellation latency, file access, completion count | App switch, lock, lease denial/expiration, Photos denial, relaunch |
| History and sync | Main-thread I/O, read count, queue drain cost, permanent/transient errors | 100/1,000/10,000 records, corrupt entries, offline queue, account switch |
| Backend | Query plans, p95 latency, write volume and failure categories | Week/all-time, opting out, moderation, concurrency, interrupted deletion |

Choose numeric budgets from the supported devices and product requirements. Compare warm/cold runs, use the same build configuration, and record the OS/model versions. Simulator results can validate logic but do not establish device energy, GPU-background, Photos-playback or file-protection behavior.

For each item, the review decision should be **fix now**, **schedule**, **measure first**, or **accept with a documented reason**. Close an item only when its acceptance check has evidence. Start with A01–A03; the performance work then has a more reliable baseline.
