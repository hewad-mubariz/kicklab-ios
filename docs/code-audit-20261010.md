# Juggle Dude code audit

Date: 10 October 2026. Baseline: working tree on commit `4e9ffbf`, including uncommitted work. Source references describe this snapshot and may move as other work continues.

The main priorities are reliable recording and cancellation, bounded video memory, reliable result syncing, and reducing work on the main thread. The project already has useful lifecycle, media parity, account isolation, and backend tests. The next step is to strengthen these boundaries, then optimize measured bottlenecks. A wholesale rewrite would put working behavior at unnecessary risk.

This is a static audit and prioritized review backlog. No application code, database, user media, or cloud configuration was changed for this audit. No new device profiling, UI automation, production security testing, or runtime reproduction was performed. “Confirmed” below means the implementation establishes the behavior or exposure; it does not mean the corresponding failure occurred on a device. Performance impact remains unmeasured unless explicitly described as an arithmetic estimate.

## Launch hardening follow-up — 10 October 2026

The original findings below remain as the audit baseline. This follow-up implements the
launch safeguards; it does **not** declare the app cleared for public launch. Physical-device
acceptance remains required, especially phone lock, Photos, memory pressure and StoreKit.

| Findings | Implemented safeguard | Remaining acceptance work |
| --- | --- | --- |
| A01 | Recorder startup/append/finalization errors propagate to capture. Backpressure remains nonfatal. Failed analysis/recording cannot submit a score; any finalized usable recording can be saved from the error alert. | Real-device low-storage/encoder failure and recovery UI. |
| A02, A23 | Player readiness has cancellation and a 15-second timeout. Export waits respect cancellation. Scene ownership includes initial refinement. | Close/reopen and cancel at each native stage on device. |
| A03 | Decode queue entries independently; retain malformed/rejected payloads in an account-scoped Rejected folder. Permanent server rejection becomes visible local history; valid later results continue. Auth, quota and temporary network failures remain retryable rather than quarantined. | Longer offline catch-up on a physical device. |
| A04, A17 | At the user’s request, juggling has no fixed duration, frame-count or mask-memory cutoff. Input validity and storage preflight remain: 512 MiB reserve at recording start, plus estimated working space for imports/exports. Only named regenerable export files older than a day are cleaned at launch; originals/history are preserved. | Mask retention still grows with session length; unrestricted operation is not a bounded-memory guarantee. Profile longer dense/sparse clips and low storage on older devices. Shared library storage management remains future work. |
| A18 | Account sync/persistence waits for protected data to become available. History read errors do not publish an empty library. Complete Protection is retained. | Passcode-lock testing and retry after unlock. |
| A19 | Removed completed-export reuse based on incomplete track hashes. Each explicit render consumes the current source/track. | Rendering no longer has that cache optimization. Existing editor saved-look behavior remains. |
| A20, A21 | Shot export fails explicitly if present audio cannot be read/encoded or ends unexpectedly. Both exporters share MOV/full-speed metadata policy above 60 FPS. Shot writer now uses a 60,000-tick media scale; a new test caught and fixed 240 FPS rounding to about 236 FPS. | Actual Photos playback and unusual user audio formats on device. |
| A22 | Detector/contact failures cannot silently finish an import or submit a live score. Failed live quality is also excluded from persisted completed-analysis evidence. | Device model failures and model accuracy checks; no claim that these guards prove count accuracy. |
| A24 | Cancel waits for burn-in teardown before retry. Background acquisition has a five-second foreground fallback. A small job journal explains interrupted work after relaunch. | No force-quit resume promise. Shared exporter architecture and complete job restoration remain future work. |
| A25 | Failed local cleanup no longer promises a durable retry when its journal may be unwritable. The profile stays open to show the warning; it explains reopening and removing local app data if necessary. | Catastrophic disk failure cannot guarantee a journal write. Durable-marker success still supports automatic cleanup on relaunch. |
| A26 | Server-only reconciliation processes confirmed pending deletions independently of the client. Apple revocation still precedes the pending marker. Worker and ten-minute schedule deployed to Juggle Dude. | Monitor failed jobs and pending-deletion age; production probe had no pending accounts. |
| A05, A29 | Server-side plausibility bound and 240 new sessions/account/hour, serialized per account; idempotent retries consume no new budget. Live leaderboard clearly describes device-reported scores. | Casual rankings only: this does not verify source or prove scores. Stronger competition still requires evidence verification/moderation. |
| A31, A32 | README setup and a repeatable `scripts/validate-launch.sh` entry point for backend, Release build and selected logic/media checks. Skipped required checks are reported as incomplete. | Model packages still require approved local provisioning. Physical-device gates are not replaced by a simulator pass. |

Backend deployment evidence: `202610100001_submission_limits.sql` applied through the
Management API; `reconcile-account-deletions` deployed; cron job
`juggledude-deletion-recovery` active every ten minutes. A scheduled-format probe returned
HTTP 200 with zero completed/failed deletions; an unauthenticated request returned 401.
The 38 existing sessions were unchanged and none violated the new plausibility bound.
The project predates CLI migration tracking; baseline its existing schema before a future
`supabase db push`. Recovery uses a dedicated scoped secret, not a service-role key in
pg_net headers. See [Supabase scheduling](https://supabase.com/docs/guides/functions/schedule-functions),
[pg_net credential visibility](https://supabase.com/docs/guides/troubleshooting/database-roles-can-read-request-headers-queued-by-pg_net-ad6357),
and [PostgREST error mapping](https://docs.postgrest.org/en/v14/references/errors.html).

Validation completed: **68 Swift tests passed** (64 XCTest + four Swift Testing),
**15 backend function tests passed**, and all disposable-database SQL suites passed with
the new migration installed. The final Release build succeeded with no app-source
warnings; Xcode emitted its usual unused AppIntents metadata notice. No required tests in
this selected regression set skipped. New coverage includes recorder failure/retry,
corrupt/permanently rejected sync entries, cancellation during initial refinement,
burn-in teardown/retry, export cleanup, interrupted-job journaling, and actual 120/240 FPS
export duration/cadence/metadata.

Final logs: `/tmp/juggledude-launch-regression.log`,
`/tmp/juggledude-launch-release-final.log`, and
`/tmp/juggledude-launch-validation/`. Backend live verification:
`/tmp/juggledude-backend-verification.json`.

**Open launch gate:** real-phone recording/failure UI, oldest-supported-device peak
memory/thermal checks within the limits, lock/background and unlock recovery, Photos
permission denial/save/playback, low storage, and purchase/restore/account deletion on the
release candidate. The connected phone's availability was requested; no new device run
was performed in this follow-up. These are not inferred from a simulator pass. App changes
are in the working tree and require rebuilding/installing; the described backend safeguards
are already deployed.

## Physical-device video profiling — 10 October 2026

Priority order after the device measurements (cosmetic work deferred):

1. **Foreground import compute policy:** remove the unnecessary CPU restriction only
   after paired full-clip output checks. Preserve cancellation and safe background/lock
   behavior; an entitlement alone does not establish that acceleration is available.
2. **Sustained live tracking:** investigate the warm-device analysis decline from about
   27 to 10 FPS. Compare a cool-start run and actual ball-in-view counting; saved-video
   FPS is not evidence of tracking accuracy. Keep existing recording limits meanwhile.
3. **Long-session evidence:** measure dense mask retention and lower-end devices before
   raising duration or memory limits. Keep all frames/quality settings unchanged during
   the performance investigation and retain reproducible evidence for each change.

These are the current video priorities; the production sign-in, StoreKit, data recovery,
privacy and other real-device release gates above remain required for launch.

Measured the original `IMG_8652.MOV` (759,014,536 bytes, 60.985 seconds,
4K portrait HEVC Main 10 HDR, nominal 120 FPS) on the connected iPhone 17 Pro Max,
iOS 26.6.2. This run started at normal thermal pressure while plugged in at 90%
battery, with Low Power Mode off. App code was optimized (`-O`, whole-module) with
Debug instrumentation; dependency targets retained Debug compilation because the
compiler crashed when globally forcing optimized Debug package builds. There was
no XCTest or debugger attached. A quiet diagnostic screen replaced the animated
processing overlay. These measurements are not an App Store Release acceptance pass.

The normal 7,200-frame import guard was extended to 8,000 **only for an explicitly
flagged Debug profiling launch**, to allow this complete source through. The 64 MiB
mask guard and existing thermal pacing stayed active. No model, confidence threshold,
analysis cadence, inference precision or processing resolution was changed. The existing
import pipeline already uses an oriented, tone-mapped 720-pixel-short-edge composition;
using the original 4K file does not imply inference on native 4K pixels.

| Measurement | Observed result |
| --- | --- |
| Full analysis | Completed in 1,332.24 seconds (22m12s), cache bypassed |
| Analysis frames / model calls | 7,314 / 7,336, including 22 existing crop retries |
| Output | 4,056 detections; 39 counted touches; zero detector/contact errors |
| Whole-app memory | Peak **170.39 MiB** in 1 Hz samples; this can miss shorter peaks |
| Retained masks | **14.70 MiB** (15,409,045 bytes), below 64 MiB |
| Detector work | 796.23 s, including 754.72 s inference and 26.49 s preprocessing |
| Median / p95 inference | 101.11 / 114.19 ms |
| Thermal pacing waits | **502.09 s (8m22s)** |
| Thermal pressure | Elevated after 2m23s; high after 8m13s; never critical |
| Battery | Reported 90% throughout while charging; not a battery-drain measurement |

Timings overlap: do not add inference/preprocessing to their enclosing detector total.
The 2.31 s decoder measurement is synchronous waiting, not total decoder CPU/GPU work.
The analyzer's own 131.27 MiB peak samples outside inference calls; use the larger
whole-app sample peak above. Thermal state is iOS pressure, not a temperature in °C.
The source metadata reports 7,315 frames versus 7,314 produced by the existing composition
reader. No new skipping was introduced, but this run does not establish one-to-one
source-frame identity preservation. Saved counter trace and masks are comparison
evidence; the reported 39 touches have **not** been checked against human ground truth.

A subsequent explicit **15-second partial probe**, using the same processing logic with
additional metrics, observed `cpu_only = 1`, `background_gpu = 0`. Both the signed app
and provisioning profile contain the background GPU entitlement. `VideoBackgroundWork`
selects a CPU-only lease when the runtime reports no background GPU resource; that lease
also restricts foreground model and image work. This is a confirmed policy issue in the
probe and a plausible major contributor to the baseline time, **not a measured speedup**
and not direct compute-device instrumentation from the full baseline binary.

Next optimization candidate: separate foreground acceleration from background resource
permission, preserving safe background behavior. Before adopting it, compare complete
tracking/count output on this source and representative clips, and measure thermal and
memory changes. Do not reduce frame rate, model quality or resolution to obtain speed.
This clip alone does not justify removing duration limits or increasing the mask budget.

Local evidence (ignored by Git): `artifacts/performance/20261010-IMG8652/` contains the
sanitized source metadata, source SHA-256, raw report/samples, graph, counter trace,
track masks, build verification and partial compute probe. The original video was not
copied into the repository.

### Foreground acceleration experiment and processor evidence

An explicitly flagged Debug experiment allowed the existing foreground model/image
pipeline to use its normal accelerators despite a CPU-only background lease. It paused
instead of performing unauthorized GPU work in the background and bypassed all analysis
cache reads/writes. This is **not enabled for normal launches**.

The original full clip finished in **494.49 s (8m14s)** versus 1,332.24 s (22m12s),
a 2.69× observed improvement on this device. It processed the same 7,314 composition
frames and made the same 7,336 model calls / 22 crop retries. Both runs produced
**39 touches with exactly matching timestamps**. All 4,056 baseline detection-frame
identities were present, plus two detections at source indices 3,850 and 3,851.
The common boxes had median IoU 1.0, fifth-percentile IoU 0.9804 and minimum 0.9028.
Numerical/mask output is not bit-identical; this comparison does not replace human-labelled
accuracy checks or qualify other videos/devices.

App CPU time fell from 1,060.55 s to 118.02 s; this is process CPU execution, not total
system energy. The 1 Hz whole-app footprint peak rose from 170.39 to 192.94 MiB
(the analyzer also sampled 193.25 MiB). Retained masks were 14.705 MiB and thermal
pacing waits 167.03 s. Both runs started at nominal pressure and reached serious pressure.
The experiment reached elevated pressure after about 45 s and serious after about 214 s,
then returned to elevated near 439 s. **It is not a solved-heat claim**: starting temperature
within each pressure band, other workloads and charging were not controlled.

Separate Instruments Power Profiler captures, outside the full timing comparison:

- Post-analysis idle: 16.10 s trace, 0.00538 app CPU seconds and 7.64 million CPU
  instructions in exported counters. CPU/GPU impact scores were zero at their displayed
  precision. The app was not continuing heavy CPU processing after completion.
- Active model-acceleration probe: 21.04 s trace, 5.364 app CPU seconds and 35.916
  billion instructions; reported CPU impact scores 1–4 and GPU impact 2–9. Scores
  are Instruments power-impact estimates, **not watts or utilization percentages**.
- Display brightness was 78%; the device was plugged in. The zero battery-drain metric
  while charging must not be interpreted as zero energy consumption. These traces do not
  provide a physical temperature in °C or identify the sole source of retained heat.
- The added Core ML instrument exported no model-event rows in this attach capture.
  GPU activity is observed, but exact model-layer GPU/Neural Engine placement is **not
  established** by this trace.

See [Apple's Power Profiler guidance](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler)
for interpretation. Raw traces, XML counters, output comparisons and the comparison
plot are retained under the ignored `artifacts/performance/20261010-IMG8652/` directory.

The narrower next candidate accelerates only model prediction while preserving the
CPU image/Vision pipeline, then switches the model to CPU when the app becomes inactive
without background GPU permission. It preserves tracker/counter state and retries the
same immutable prediction input once if an app-state transition invalidates GPU submission.
Normal jobs retain their original backend. Experiments remain isolated behind Debug-entry
flags and cannot write production analysis caches. Cancellation (including an operation's
own CancellationError), failed model reload and background-policy unit checks passed.

### Full model-only acceleration with app switching

The narrower candidate completed the same original source in **552.44 s (9m12s)**,
starting and ending at **fair/elevated** pressure, never reaching serious or critical in
this run. It used 157.90 app CPU seconds, with 135.69 s thermal pacing. Sampled whole-app
peak was **208.78 MiB** and retained masks 14.705 MiB. It started warm and included app
switches, so its time and heat must not be treated as a controlled head-to-head comparison
against the nominal-start full-acceleration experiment.

Acceptance evidence for this source:

- Same **7,314 analysis frames, 7,336 model calls, 22 crop retries, 39 touches and all
  39 exact touch timestamps** as the CPU baseline. Zero detector/contact errors.
- All 4,056 baseline detection-frame identities retained; the same two additional
  detections at indices 3,850/3,851 as the broader acceleration experiment. Common box
  IoU median 1.0, fifth percentile 0.9806, minimum 0.9028. Numerical outputs/masks still
  differ, so this is output parity at the counted-event level, not bitwise equivalence.
- Measured lifecycle samples contain **25.61 s in background across two intervals**,
  with inactive transitions as well. The controller requested a 30 s interval, but the
  app returned active earlier and entered another background interval later; use the
  measured lifecycle, not the planned duration. No claim of a sustained locked-phone
  endurance test is made.
- The model used CPU while backgrounded and returned to acceleration in foreground;
  nine backend switches (including initial inactive startup and other inactive transitions)
  totalled 0.576 s of model reload time. Tracker/counter state was retained. CPU work
  continued during background samples; frame progress is published every 15 frames,
  so a temporarily flat progress sample does not by itself establish a stalled worker.

**Decision:** prioritize this model-only policy for qualification, preserving the existing
CPU image/Vision path and thermal safeguards. Keep it opt-in until representative,
human-labelled clips and lock/lease-expiration behavior are checked. Do not reduce frame
rate/resolution, replace the model, or raise video/mask limits on the strength of this one
source. Live camera heat/throughput remains a separate launch concern.

Validation: **11 focused unit tests passed**, including operation cancellation, cancellation
before retry, failed backend reload, scope isolation and background permission. Optimized
Debug physical-device build passed. The final build adds explicit CancellationError
pass-through to the tested handoff implementation; this addition has unit coverage.
The latest build was installed and relaunched with no diagnostic arguments after evidence
was copied. Pro bypass, the 8,000-frame profiling allowance and experimental compute flags
are not enabled for normal launches. Results, lifecycle samples, config and build logs are
in `artifacts/performance/20261010-IMG8652/model-handoff/` and its parent directory.

### Release model packaging reduction — build 6 (10 October)

A fresh signed Release archive excludes nine experimental Core ML packages through the app target’s Release-only `EXCLUDED_SOURCE_FILE_NAMES`. All packages remain available on disk and to Debug builds. The actual archive contains exactly `KickLabYOLO26MotionSegmentation.mlmodelc` and `PersonBoundaryMatte.mlmodelc`; both compiled weight files have identical SHA256 hashes to build 5. Tracking/counting and model accuracy settings were not changed for this packaging update.

Measured uncompressed app bundle: **196,260,224 bytes (196.3 MB)** versus build 5’s **522,008,655 bytes (522.0 MB)**, a **62.4% reduction**. This is archive size, not a prediction of Apple’s device-specific download size. Version remains 1.0; build is 6. The previously reviewed OS-only/exempt encryption setting is now recorded as `ITSAppUsesNonExemptEncryption = false`. Release archive and configuration validation passed; only Xcode’s unused AppIntents metadata notice appeared. No repeated video/StoreKit test run was needed for this resource-exclusion change; build 5’s recorded purchase/restore verification limitation remains. Evidence: `artifacts/releases/20261010-testflight-build6/`.

Build 6 upload succeeded at 19:23 CEST. App Store Connect confirmed version 1.0 (6) as Processing. The existing Friends and Family internal group has automatic distribution for Xcode builds enabled; no users, invitations or access permissions were changed.

### TestFlight cleanup and unrestricted juggling (10 October)

The user explicitly requested removing the two-minute recording/import limit and the retained-mask cutoff after the outdoor tests. Removed the live duration stop, import/cache/runtime frame-count checks, and 64 MiB mask stop. Input duration must still be valid; startup disk reserve, export space checks, encoder failure handling and analysis error handling remain. Recorder startup now checks the disk reserve without estimating a fixed recording duration. Model, detector, counting, inference cadence, mask data and the per-chunk fingerprint autorelease-pool fix are unchanged.

Removed temporary outdoor profiling state, persistent five-/ten-minute modes, memory/countdown HUD, extra diagnostic capture files, fingerprint comparison harness, and the profiling Pro bypass. Development review routes and CSV logging are excluded from Release. Existing unit-test helpers remain DEBUG-only. A prior build 4 archive contained the two-minute/mask cutoffs; its upload was interrupted after the user clarified the desired policy. Build 5 supersedes it and is the intended TestFlight candidate.

Build 5 Release archive succeeded with no app-source warnings (only Xcode’s unused AppIntents metadata notice). The compiled binary contains neither temporary profiling switches/harness names nor the old duration/mask-limit error strings. All 40 focused LaunchReliability, ReplayAccess, SessionAnalysis and CaptureAnalysisEvidence tests passed, including acceptance of longer durations and unchanged fingerprint/cache evidence checks. SubscriptionStore tests could not load their StoreKit configuration: `SKInternalErrorDomain Code=3` on configuration, storefront and transaction setup, persisting after a simulator restart. The resulting catalog assertions are not a passing purchase/restore check; verify this flow through TestFlight. No production subscription code or test expectations were changed to hide the environment failure. Evidence: `artifacts/releases/20261010-testflight-build5/`.

Build 5 uploaded successfully to App Store Connect at 18:50 on 10 October; App Store Connect’s Build Uploads list confirmed version 1.0 build 5 as Processing. This is a normal App Store Connect upload eligible for internal and external testing, not an internal-only archive. No tester invitations were sent.

The successful ten-minute run does not establish a flat 300 MB ceiling: retained masks grew to 62.72 MiB and sampled recording footprint peaked at 406.6 MB on that device. Removing app cutoffs does not remove iOS memory pressure termination. Longer/multi-device sessions and the full end-to-end Stop peak after the fingerprint fix still need beta coverage. Earlier notes below describe historical diagnostic settings and limits, not the current shipping policy.

### Model acceleration enabled for normal video processing (10 October, 16:04)

**Confirmed finalization contributor fixed:** `SessionAnalysisStore.sourceDigest` read the source in 1 MiB chunks but FileHandle’s autoreleased buffers accumulated across the loop, briefly retaining approximately the movie’s size. A per-chunk autorelease pool now releases each temporary read buffer after SHA256 consumes it. The digest, masks, retained-mask limit, detector, counting and capture cadence are unchanged. An isolated Mac replay of the actual 234.8 MB five-minute file dropped from 237.8 MB process peak to 4.4 MB with an identical fingerprint. On the actual phone, separate fresh processes fingerprinting the saved 469 MB ten-minute file showed 47.9 → 509.3 MB for the old loop versus 47.2 → 47.2 MB before/after the production fix. The fixed run did not increase its pre-existing 77.4 MB lifetime startup peak; this is not a claim of zero transient allocations. Both phone digests matched exactly.

The fixed optimized Debug build is installed and was reopened normally after the opt-in, read-only fingerprint comparison. All 26 SessionAnalysis/CaptureAnalysisEvidence tests passed, including new chunk-boundary SHA256 equality and cancellation checks plus existing lossless-mask/cache/timeline round trips. Evidence and repeatable isolated benchmarks: `artifacts/performance/20261010-finalization-fingerprint/`. A fresh full recording is still needed to measure the new end-to-end Stop peak; cache serialization/replay allocations were not eliminated or changed. This fixes the confirmed fingerprinting contributor to the earlier 855 MB spike while leaving mask storage and the 64 MiB guard alone, as requested.


**Ten-minute outdoor result:** `76ED2504` completed approximately 600 seconds with 36,004 written video frames, zero writer drops, one capture drop, and 12,467 analyzed frames (20.78 FPS average). The 212 reported touches are unverified, not an accuracy score. All 594 recording samples were nominal/fair thermal pressure (313/281); no errors or memory-warning events were recorded. Median sampled recording footprint was 336.5 MB, peak 406.6 MB; the lifetime kernel peak at stop was 422.3 MB. Minute-average footprint rose from 301.5 to 374.8 MB, so this is not a flat-memory result. Retained mask payload reached **62.72 / 64 MiB (98%)**, leaving only 1.28 MiB of headroom.

**Priority remains mask retention and finalization:** the first post-stop sample reached 797.9 MB, and the kernel lifetime peak rose to **855.3 MB**, versus 569.5 MB after the five-minute run. It fell to 258.5 MB by the third post-stop sample. Preserve counting/model accuracy while investigating bounded, lossless disk-backed mask retention and the finalization allocation spike; neither root cause nor a fix has been established by this review. Do not infer unrestricted-duration or multi-device launch readiness from this one successful take. Evidence: `artifacts/performance/20261010-outdoor-ten-minute-results/`. The 469 MB raw video remains retained on the phone; this review copied only logs/reports and did not change app settings or code.


**Five-minute outdoor completion and ten-minute test prepared:** the retained `DF083C95` recording is 300.001667 seconds, 720×1280 at approximately 60 FPS (234.8 MB). Capture reported 18,001 written frames, zero writer drops, one capture drop, and 6,084 analyzed frames (20.28 FPS average). Its 59 reported touches are not a ground-truth accuracy result. Recording samples were 273–362 MB (median 313 MB); minute averages rose from 290 to 328 MB, with 29.39 MiB retained masks. Kernel lifetime peak at stop was 380 MB. All recording samples were nominal/fair thermal pressure, with no memory-warning events, stop errors, or critical heat. A manually interrupted ~32-second take is excluded from the completed-run assessment. Model loading and hand-verifier warmup occur before the first saved frame, so they do not consume recording time.

**Unresolved priority:** immediately after Stop, sampled footprint reached 565.7 MB (kernel lifetime peak 569.5 MB), then fell below 200 MB on the following sample. This is a distinct finalization/persistence/replay issue to investigate; hashing and capture-cache serialization overlap the stage, but no allocation trace establishes the cause. It is not evidence of a flat long-term footprint. Logs, raw video, cadence, review, summary and a memory chart are in `artifacts/performance/20261010-outdoor-five-minute-success/`.

The new explicit DEBUG `--profile-live-session --profile-live-10min --profile-pro` configuration persists 600 seconds across reopening, shows a 10:00 countdown, allows 605-second/36,300-frame result handling, and records preparation state separately. The 350 MB app stop remains disabled; the 64 MiB mask guard, storage reserve, and critical-thermal guard remain. Detector, counting, model and frame scheduling were not changed. Build and source-policy checks passed; installed and launched on the phone with its stored 600-second setting verified. No ten-minute recording has been completed yet. Leave the app open at least 30 seconds after Stop to capture finalization and recovery. Evidence: `artifacts/performance/20261010-outdoor-ten-minute/`.


Outdoor countdown and restart fix: the phone process had changed after the flags-enabled launch, so the previous test configuration could be lost when reopening the app. Explicit DEBUG outdoor-test activation now persists locally across launches (including the separately requested Pro override); Release ignores these preferences. The camera shows a prominent 05:00 countdown driven by recording elapsed time, resetting before each take. “End outdoor test mode” is available while idle and clears both preferences. The manual test still stops at 300 seconds, keeps the 64 MiB mask/storage/critical-thermal guards, logs memory once per second, and has no 350 MB app-memory stop. Detector-review enablement now follows current test state so ending this mode does not leave the old memory guard active. Actual source compiled and checked in separate macOS processes for enable → reopen → end → reopen, plus Release flag rejection; device build/install evidence is under `artifacts/performance/20261010-outdoor-countdown/`.


Outdoor test revision (10 October, 16:57): at the user's explicit request,
removed the **350 MB whole-app stop** from both the per-frame review guard
and the one-second manual monitor when `--profile-live-session` is active.
The purpose is to measure whether the working set plateaus through five minutes.
The camera banner now explicitly says `no 350 MB stop`; the JSONL header records
`app_memory_stop_enabled: false` and a null threshold. iOS memory warnings are
logged as separate events. The five-minute recording timer, retained raw videos,
CPU/memory/thermal samples, 64 MiB mask guard, storage guard and critical-heat stop
remain. The older automatic benchmark's 350 MB guard is unchanged and is not
launched. Normal launch/Release behavior is unchanged. Optimized Debug build
passed, installed, and launched with `--profile-live-session --profile-pro`.
Evidence: `artifacts/performance/20261010-outdoor-no-cap/`. A completed five-minute
recording and its peak memory remain pending; this change does not establish
that the working set will plateau or that iOS cannot terminate the process.

Outdoor results follow-up: retrieved three completed user recordings without
restarting the phone. All three stopped with the diagnostic **350,000,000-byte
current whole-app memory guard** message, at **66.83s, 3.10s and 81.54s**.
Retained mask payloads were only **14.20, 1.33 and 17.13 MiB**, respectively;
the 64 MiB mask cap did not trigger. Every thermal sample was **nominal**.
The one-second memory samples mostly occupied 300–340 MB while active, then
fell below approximately 100 MB within ten seconds of stopping. Per-frame
checks can observe short peaks missed by one-second logging; report-at-stop
memory is measured after cleanup has started. The process lifetime peak reached
373.25 MB and must not be interpreted as a fresh peak for each recording.
This supports investigating working-set spikes and the diagnostic ceiling,
not inferring a universal duration limit or attributing all growth to masks.
No allocation backtrace yet identifies the responsible detector/Vision/render
stage; reduced memory after stopping does not rule out every retained resource.

All raw videos were successfully retained. They contain 4,009 / 186 / 4,893
saved frames at approximately 60 FPS, with zero writer drops; the first take
had one capture drop, the other two zero. Live analysis averaged 25.50 / 29.52 /
24.29 FPS, reflecting the existing 30 FPS cap and pending-frame replacements.
Reported live counts (64 / 1 / 65) are not independently reviewed ground truth.
Evidence, three videos, cadence reports, diagnostic JSONL and a memory plot:
`artifacts/performance/20261010-outdoor-results/`. No safeguard was raised or
removed during this read-only investigation. A full five-minute ball-present
recording and exact memory-allocation attribution remain unqualified.

Outdoor follow-up (10 October, 16:39): installed and launched an optimized Debug
build with `--profile-live-session --profile-pro` for the user's manual test.
This explicit Debug mode allows **300 seconds of live recording**, with 305
seconds / 18,300 frames permitted for subsequent 60 FPS review processing.
Normal launches retain the existing limits; Release ignores the override.
No automatic recording or diagnostic movie deletion occurs. The camera shows
the five-minute test banner, existing performance HUD, mask usage and log sharing;
the screen stays awake while the test view is active. Glow Trail remains default.
Pro access is overridden only for this explicitly flagged Debug launch.

The 64 MiB mask and storage safeguards remain active. Current app footprint over
350,000,000 bytes or critical thermal pressure stops the test early. The outdoor
memory check uses current footprint rather than a prior session's lifetime peak.
One-second JSONL samples record memory/peak, cumulative CPU time, mask bytes,
thermal pressure, battery, detector FPS/timing, frame drops and recording state.
Existing capture cadence and counter trace persistence remain enabled. On finish,
a same-volume hard link retains the raw recording under
`Documents/OutdoorJugglingTests/<run>/`; failures are reported in the HUD/log.
Thermal pressure is not a temperature measurement, and CPU time excludes GPU/ANE
utilization. Two focused limit tests passed and the phone build succeeded.
Evidence: `artifacts/performance/20261010-outdoor-test/`. Actual five-minute
ball-present results are **pending the user's recording**, not established by
installation or by the earlier empty-scene benchmark.

After the paired phone corpus and independent Python comparison below, the user
requested promotion for outdoor recording tests. Ordinary video-work leases now
enable model acceleration in the foreground and use the tested CPU fallback
when inactive without a background GPU grant. Image/Vision policy, live-camera
configuration, model weights, counting rules and frame cadence are unchanged.
CPU comparison diagnostics remain explicitly selectable; normal jobs retain
cache behavior. Denied background runtime still pauses work, and expiration
still cancels it. No processing permission is created by this optimization.

All **14** focused background-policy/backend-switch tests passed, including new
normal-launch policy and denied-background cases. The optimized Debug device
build succeeded and was installed on Hewa's iPhone 17 Pro Max, then launched
with **no diagnostic arguments** (PID 35943). Fresh outdoor recording accuracy,
sustained heat and live-camera throughput remain user/device validation items.
The **120-second duration, 7,200 analysis-frame and 64 MiB mask guards remain**;
120 FPS imports therefore reach the frame limit at approximately 60 seconds.
Build, test, install, launch and source-hash evidence is saved in
`artifacts/performance/20261010-model-promotion/`.

### Multi-clip juggling accuracy qualification (before promotion)

The accuracy set uses actual juggling, not ground-dribbling or power-shot footage:
`eighteen` (indoor ~30 FPS), `34dd` (indoor ~60 FPS), and two original outdoor
4K/120 FPS sources (`normal_juggling_2` and `juggling_second_ball_very_far`).
A held-ball clip and ground-dribbling clip are separate negative controls. They do
not contribute to positive juggling recall. Source hashes and review provenance
are frozen in `artifacts/performance/20261010-juggling-accuracy/manifest.json`.

This is a **development regression corpus, not held-out accuracy**. The outdoor
sources also occur in the lab's field training/review corpus. Existing indoor
labels were visually reviewed previously; the outdoor references were reviewed
from complete source-only 12 FPS contact sheets and dense 60 FPS contact
neighborhoods before reading current phone output. These review images do not
change the original files fed to the app. Labels are assistant-reviewed, not
independent human annotations. The second outdoor clip excludes uncertain
opening/offscreen intervals; two baseline counts fall in those intervals.

The Debug-only `--profile-accuracy-comparison` entry pins image/Vision work to CPU
in both arms even when iOS declines a background lease, and bypasses all analysis
cache reads/writes. The candidate adds `--profile-model-accelerated`; normal
launches keep their existing policy. No source trimming, model replacement,
resolution/cadence reduction or raised safeguards is used. The ordinary 7,200
frame and 64 MiB mask limits remain active.

CPU baseline completed all six sources / **6,500 analysis frames**. Both indoor
clips matched 18/18 reference contacts without extra events. `normal_juggling_2`
matched 22/24: the high foot touch at 12.16s was rejected as `handContact` despite
36/36 surrounding frames having ball detections; the final shallow sideways
contact at 14.48s was followed by `trackLost`. The other outdoor source matched
22/22 reviewed contacts, but falsely counted a visually confirmed ground bounce
at 4.083s. The held-ball and dribbling controls both counted zero. These are
existing baseline counting failures, not acceleration-induced failures.

Python follow-up (10 October): fresh PyTorch inference on all **1,978**
`normal_juggling_2` composition frames, using the phone model's Motion parent
and reviewed-mask delta, produced 1,755 ball detections. The current Python
batch counter with torchvision pose also matched **22/24**, with no extra
events and the same misses: `hand_touch` at 12.15s and `track_lost` after the
14.48s sideways contact. Python streaming with the app's basic thresholds but
without pose counted 23; lab-default streaming/batch counted 22 but missed
2.335s instead of 12.16s. Therefore totals alone are insufficient. Replaying
the phone's saved detector inputs through Python reproduced the corresponding
streaming results. This supports separating these accuracy failures from the
compute optimization; it does not establish general pipeline equivalence or
identify the exact pose-versus-geometry cause of the hand veto. Python does
not use the app's Apple Vision estimator, follower, marginal retry or newer
contact safeguards. No production algorithms changed. Evidence and executable
diagnostics: `../kicklab-lab/runs/normal2-python-count-20261010/comparison.json`.
The older image-generator helper rejected this edited MOV's timestamps;
the completed run uses the app's actual `EffectVideoGeometry` composition.
All decoded frame indices/times were validated against the phone trace
(at most 1ms integer-rounding difference). Temporary lossless working video
was removed after retaining contact stills, detections, pose joints and results.

Both arms completed. Model acceleration preserved **all 83 emitted touch timestamps
exactly**, all 6,500 source-frame indices/timestamps and the counter configuration.
All four juggling clips retained exactly the same detection-frame sets. Both arms
reported zero detection/contact errors and bypassed caches.

| Source / reviewed scope | Reference contacts | CPU matched / missed / extra | Model-only matched / missed / extra |
| --- | ---: | --- | --- |
| Indoor ~30 FPS | 18 | 18 / 0 / 0 | 18 / 0 / 0 |
| Indoor ~60 FPS | 18 | 18 / 0 / 0 | 18 / 0 / 0 |
| Outdoor normal juggling 2 | 24 | 22 / 2 / 0 | 22 / 2 / 0 |
| Outdoor second ball, visible events only | 22 | 22 / 0 / 1 | 22 / 0 / 1 |
| Held-ball negative control | 0 | 0 emitted | 0 emitted |
| Ground-dribbling negative control | 0 | 0 emitted | 0 emitted |

The second outdoor clip emitted 25 total counts: 22 matched, one ground-bounce
false count and two excluded/uncertain edge-of-frame counts. Do not call all 25
correct or compare that total directly to the 22-reference subset. Across the
four positive clips, the reviewed scope contains **80/82 matched contacts and
one extra event**, identically in both arms. This is not a general accuracy claim.

Tracking/mask evidence: no baseline detections were lost. The candidate added
one held-ball frame (53) and four ground-dribbling frames (108, 171, 236, 278).
Source-image review places all five boxes on the actual ball. The dribbling
candidate used 30 marginal crop retries versus 29 for CPU; total model calls
were 6,530 versus 6,529. Small backend numerical differences can change retry
selection. On the four juggling clips, minimum common-box IoU ranged from
0.9551–0.9735. Approximate shared-image-ROI weighted mask IoU medians ranged
0.9955–0.9969, with a minimum of 0.9494. These are pairwise overlaps, not accuracy
against segmentation ground truth. The distant dribble mask at frame 199 changed
more (approximate weighted IoU 0.4072, confidence 0.313→0.870), so masks must not
be described as identical. No mask availability changed on common frames.

Descriptive performance: CPU took **1,183.95s (19m44s)** versus candidate
**564.64s (9m25s)**; app CPU time 914.17s versus 143.79s. Sampled memory peaks
were **163.81 MiB versus 234.59 MiB**; largest retained-mask footprint stayed
about **25.945 MiB**, below 64 MiB. CPU started nominal and ended serious; the
candidate started serious and ended fair. Neither reached critical. Six baseline
samples were backgrounded; the candidate had no background samples (one initial
inactive sample). Thus these are not controlled cold-start speed/heat comparisons
or a new background qualification. Thermal pacing, cache rebuilding and unchanged
source decoding remain part of the measured runtime.

**Decision:** no counted-event regression observed on this development set, but
keep model acceleration opt-in. Prioritize the existing high-foot hand-veto false
rejection, ground-bounce false count and shallow sideways/edge-of-frame miss.
Do not disable hand/ground checks or loosen global thresholds merely to fit these
clips; preserve the negative controls and add unseen people/scenes for validation.
No counter changes were made during this compute comparison. The normal app was
relaunched without diagnostic flags after both arms; temporary phone inputs and
copied diagnostic folders were removed after local evidence validation.

Reviewable source contact sheets, event timeline and full reports:
`artifacts/performance/20261010-juggling-accuracy/review.html`.
`scripts/compare-juggling-accuracy.py` checks completed/uncached/error-free runs,
unchanged counter configuration and exact per-frame source indices/timestamps,
then compares event matches and detection geometry. Event matching maximizes
one-to-one correspondence within 0.12s and then minimizes timing error, with
excluded intervals applied to both references and predictions. Partial labels
are refused for full precision/recall. Five synthetic scoring checks passed.
Optimized Debug device build and **12 compute-policy/cancellation tests passed**.

### Five-minute stationary-camera follow-up

The phone did not return to nominal thermal pressure during a five-minute cooldown.
A further 60-second quiet diagnostic (no detector/camera, 1.06 CPU seconds total,
13.4 MiB app memory) still reported serious/high pressure. The subsequent camera run
was explicitly a **warm-start** test, not a cold-start measurement. The device remained
connected; room temperature, case, display brightness and other system workloads were
not controlled. This result cannot attribute all heating to the app or predict a cool
phone's endurance.

The real RecordView/preview/HUD recorded for 301.40 seconds, using its existing 720p
back-camera configuration. An explicit Debug launch temporarily extended the duration
stop to 305 seconds and enabled Pro access for this diagnostic only; production limits,
model, thermal behavior and analysis cadence were unchanged. The benchmark's early
stops were 350,000,000 bytes lifetime app footprint or critical thermal pressure.

| Measurement | Observed result |
| --- | --- |
| Recording result | Completed the five-minute target; writer finalized successfully |
| Saved video | 18,085 frames, about 60 FPS; **zero writer drops**, one capture drop |
| Analysis | 4,525 frames after finalization, about **15.01 FPS** average |
| Tracking throughput | Minute-one median 26.20 FPS; minute-five median **10.67 FPS** |
| Memory | Sampled peak 258.16 MiB; kernel lifetime peak **260.02 MiB** |
| Steady memory | Minute-one median 208.97 MiB; minute-five median 216.05 MiB |
| After stopping | **85.88 MiB** with preview still active; detector unloaded |
| Masks | Zero accumulated in this stationary scene |
| Thermal pressure | High throughout; never critical |

The existing live buffer targets 30 analysis FPS from a 60 FPS recording. It intentionally
throttled 9,042 camera frames, then replaced 4,517 pending observations when inference
could not keep up. No new frame-skipping policy was introduced by this profiling work.
The 4,523 HUD/benchmark count was sampled just before stopping; the finalized capture
ledger reports 4,525 after pending work completed. Use the latter for total analyzed frames.

This establishes five-minute recording/finalization and controlled baseline memory on
one warm device. It does **not** test dense ball-mask retention or prove touch accuracy.
The analysis slowdown is an accuracy risk requiring real juggling footage and a cool-start
repeat; a smooth 60 FPS recording alone does not establish adequate live tracking.
Do not remove the normal recording limit based on this stationary run. Next steps are
foreground/background compute policy investigation, paired output comparisons, then a
long ball-in-view live run with count ground truth and memory/thermal logging.

The diagnostic recording was deleted by the benchmark after inspecting its duration;
user recordings and the original `IMG_8652.MOV` were untouched. Metrics, capture cadence,
CSV and graphs are retained in the evidence folder. The app was relaunched without
profiling arguments, removing the temporary Pro bypass and duration override. Diagnostic
build and whitespace validation passed; no automated UI test was used for these runs.

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

## Shipping resource cleanup — 10 October 2026

Moved optional `PersonBoundaryMatte.mlpackage` and its licenses out of the app target into `resource-backups/20261010-shipping-cleanup/Models/`. Release also excludes this package by name if it is restored for research. This is person-boundary refinement for background replacement, not the ball detector. The existing Apple Vision foreground/person segmentation path handles an absent refiner; its edge quality can differ. The model name lookup remains optional.

Kept all 14 `.jdmaterial` files: the picker, replay and video exporter use them. Moved ten source JPGs into `BallMaterialSources/` under the backup because only the macOS baker needs them. `JUGGLE_DUDE_PRINT_SOURCES` selects that directory; the old environment-variable fallback still works. Rebuilding Classic from its backed-up source produced an identical SHA-256 to the shipped material.

Moved 15 unreferenced image sets into the backup: `bg-stadium-dark`, `bg-stadium-light`, `effect-fire`, `effect-ice`, `effect-galaxy`, `effect-neon`, `icon-free-kick`, `icon-juggling`, `icon-penalties`, `icon-stats`, `icon-target-shoot`, `replay-tool-ball-v1`, `stat-icon-cleat`, `stat-icon-combo`, and `stat-icon-height`. Retained the 33 other image sets, including referenced scene backgrounds for saved-scene compatibility.

The backup manifest records original and backup paths, byte sizes and SHA-256 hashes for 46 files; all hashes were verified after moving. This backup is local to this Mac. Core ML packages remain ignored by Git. No files were discarded. The nine research models excluded in build 6 remain outside Release.

The new Release bundle was inspected: it contains only `KickLabYOLO26MotionSegmentation.mlmodelc`, its weights match build 6, all 14 material hashes match build 6, no source print JPGs remain, all 15 obsolete image sets are absent, and all 33 retained image sets are compiled. No detector, counting, recording-limit or paywall changes were made as part of this cleanup.

Validation: Release build and local unsigned Release archive succeeded. The archived app is 133,624,501 bytes versus build 6's signed archive at 196,260,224 bytes: about 62.6 MB smaller (31.9%). This is uncompressed bundle size, not Apple's device-specific download size; signing and build contents can introduce small differences. Repeated the resource/hash checks against the final archive.

All 17 selected simulator checks passed: three BallCollectionTests (including actual exports for all 14 skins), ten ForegroundMattingTests, and four ScenePreparationTests. An initial Release test build could not compile existing tests that call Debug-only benchmark helpers; the successful run used Debug with the same model exclusions and arm64 only. This does not establish person-cutout edge quality or live performance on an iPhone 11. No tracking weights changed.

Evidence: `artifacts/releases/20261010-resource-cleanup/`, plus durable backup `verification.json`. The local archive is `/tmp/juggledude-resource-audit-20261010/JuggleDude.xcarchive`. No version bump, TestFlight upload, commit or push was performed for this cleanup.
