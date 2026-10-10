# Juggle Dude product analytics

PostHog iOS 3.92.0 is pinned in the Xcode project and Package.resolved. The current project is hosted in the EU: https://eu.posthog.com/project/300647.

## Configuration and consent

Copy `config/PostHogConfig.example.plist` to `kicklab/Analytics/PostHogConfig.plist` and fill in the project token and ingestion host. The local file is ignored by Git and bundled by Xcode's synchronized app folder. It contains only a public ingestion token (`phc_`), never a personal API key. This checkout is configured for the existing EU project. Missing or invalid configuration makes tracking a no-op.

Usage sharing defaults to off. Users enable it in Profile → Settings → Privacy → Share usage analytics. SDK initialization is deferred until consent, so an opted-out fresh install doesn't contact PostHog. Turning the switch off stops new event capture; it does not delete previously submitted data or revoke an upload already in flight. The SDK handles its own bounded offline queue (300 events).

We use the SDK's random installation ID, without calling identify or creating person profiles. Sign-out and account deletion reset the local analytics identity. Retention therefore measures opted-in installations, not unique accounts across devices. Reinstalling, signing out, or sharing one installation can affect these counts.

No emails, account IDs, auth links, raw error messages, video URLs, images, videos, or per-frame tracking data are sent. Automatic screen/tap capture, session replay, crash capture, push capture, feature flag preloading, and IP geolocation enrichment are disabled. PostHog still receives requests and standard SDK context such as app/OS/device version. The SDK ships its privacy manifest. The published privacy policy and App Store privacy answers should describe this optional analytics collection before releasing it publicly.

## Events

Every event includes `event_schema_version: 1` and `environment` (`production` or `development`). Outcomes are `completed`, `cancelled`, `failed`, or, for purchases, `pending`. Errors never go into event properties.

| Event | Trigger and properties |
| --- | --- |
| `app_opened` | App becomes active, including foreground returns. |
| `sign_in_started` | Apple/Google request begins, or an email callback is handled; `method`. |
| `sign_in_finished` | Auth request completes; `method`, `outcome`. Session restoration does not count as a new sign-in. |
| `email_link_requested` | Email send succeeds/fails; `outcome`. Sending a link is not a completed sign-in. |
| `training_started` | Recording starts; `activity` (`juggling` / `ball_distance`). |
| `training_completed` | A usable recorded session is ready; `activity`, rounded `duration_seconds`. Imports do not count as newly recorded training. |
| `video_import_started` / `video_import_finished` | Juggling gallery import and analysis; `activity`, and terminal `outcome`. |
| `effect_selected` | Trail effect changes; `activity`, catalog `effect` identifier. Intensity slider updates are excluded. |
| `motion_graph_toggled` | Including a graph in the juggling replay changes; `enabled`. |
| `video_export_started` | A new save begins in the juggling/ball-distance replay editors; `activity`, `effect`, `graph_enabled`. |
| `video_export_finished` | Save job ends; `activity`, `outcome`, rounded `elapsed_seconds`. Completion means saved to Photos, not merely rendered. A cancellation after Photos committed remains completed. |
| `paywall_viewed` | Once per paywall view instance. |
| `purchase_started` / `purchase_finished` | A paywall purchase attempt; `plan` (`monthly` / `yearly`), terminal `outcome`. This is a conversion signal, not authoritative revenue accounting: renewals, refunds, restores and later approval of pending purchases are not recorded here. |

These events cover the current primary editors, not every legacy or diagnostic export route. Training without a completed event is a possible abandonment/failure signal, not proof of either. Hard termination/offline queue eviction can also leave an unmatched start. Export outcomes are emitted by the job rather than transient toast presentation.

## First reports

Filter normal reports to `environment = production`.

- Training: `training_started` → `training_completed`, broken down by activity.
- Imports: `video_import_started` → `video_import_finished` with `outcome = completed`.
- Exports: `video_export_started` → `video_export_finished` with `outcome = completed`; separate outcome trends and elapsed-time distributions to inspect friction.
- Subscription: `paywall_viewed` → `purchase_started` → `purchase_finished` with `outcome = completed`.
- Retention: returning to `training_completed` after 1 and 7 days, broken down by activity.

Repeated sessions and successful exports are engagement signals; they do not directly measure enjoyment. These reports represent people who opted in.

## Validation

`ProductAnalyticsTests` covers consent, missing configuration, disabled runtimes, identity reset, bounded numeric fields, and configuration validation using an in-memory transport. `AccountStoreTests` exercises the instrumented authentication flows. Tests never intentionally send production analytics.

Debug builds do not send events unless launched with `--enable-product-analytics`; usage sharing must also be enabled. Previews and XCTest hosts stay disabled. A development smoke check should send an `app_opened` event and verify it in the project's activity feed with `environment = development`. Remove the launch argument afterward; no extra debug instrumentation is needed in the app.

SDK reference: https://posthog.com/docs/libraries/ios

Validated 2026-10-10: iPhone Debug build passed with no source warnings; 20 selected analytics/auth tests passed. The simulator sent `app_opened` through the iOS SDK to EU project 300647, verified in Activity with `environment = development`. Project onboarding is complete on the Free plan, named Juggle Dude. Automatic capture and session replay are disabled in project onboarding as well as in the app. No custom dashboards have been saved yet.
