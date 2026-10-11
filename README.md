# Juggle Dude iOS

The [four-week post-launch plan](docs/post-launch/README.md) records the agreed
priority order, weekly shipping scope, leaderboard rules and release checks.

Open `kicklab.xcodeproj` and use the `JuggleDude` scheme. The current target is iOS 26.5;
use Xcode with that SDK. Core ML packages in `kicklab/Models` and local account/analytics
configuration are excluded from Git. Obtain the approved
`KickLabYOLO26MotionSegmentation.mlpackage` before building;
configuration templates are in `config/`. Never put server credentials in the app bundle.

Release ships only that tracking model. Optional person-cutout refinement, unused images,
and offline ball-print sources are backed up outside the app target in
`resource-backups/20261010-shipping-cleanup/` (see its manifest and README.txt).
The model backup is local and remains ignored by Git. All 14 runtime ball materials
remain bundled; material-generation instructions are in
`design/ball-collection-01/material-sources/README.md`.

Local release media, recording investigations, offline material reference images
and resource backups are preserved on this Mac and excluded from Git. Their exact
paths are listed in `.gitignore`; they are not included in a fresh clone. The
material-generation README and bundled runtime materials remain tracked.

Launch validation:

```sh
scripts/validate-launch.sh backend
scripts/validate-launch.sh release
TEST_DESTINATION='platform=iOS Simulator,id=YOUR_SIMULATOR_ID' scripts/validate-launch.sh logic
```

The backend lane requires PostgreSQL command-line tools and Deno (`DENO_BIN` can specify
its path). It creates a disposable local database. Results and logs default to
`/tmp/juggledude-launch-validation`; set `VALIDATION_DIR` to override. Failed checks and
skipped required tests are not a pass. Run the relevant lane after each change.

The automated checks do not replace recording, phone-lock/background, Photos playback,
low-storage, purchase/restore and account-deletion checks on the actual release candidate.
See `docs/code-audit-20261010.md` for findings, implemented safeguards and remaining gates.

The 10 October backend changes were applied through the Supabase Management API. The
existing project has no CLI migration-history table: establish its migration baseline
before using `supabase db push` against that project. Do not replay the initial migrations
against live tables. Deletion reconciliation is deployed separately; its scheduled job
is defined in `supabase/ops/schedule-deletion-recovery.sql`, with a scoped secret in Vault
and Edge Function secrets. Never embed a service-role key in that scheduled HTTP request.
