# Profiles, avatars and juggling results

The Juggle Dude backend uses Supabase Auth for identity, `public.profiles` for app-specific account details, and `public.juggling_sessions` for durable results. The `avatars` Storage bucket holds profile pictures. The migration was applied to project `shbdsjvpjdtqbiaevrxy` on 2026-10-09 through the SQL Editor; the app uses its existing publishable key and the Auth SDK's current access token. No new client credentials are required.

## Data model

| Resource | Purpose | Access |
| --- | --- | --- |
| `auth.users` | Sign-in identity, email and provider metadata | Supabase Auth only |
| `public.profiles` | One row per Auth UUID; display name, optional country, avatar path and leaderboard opt-in | Owner reads/edits; database-created on signup |
| `public.juggling_sessions` | Each completed session: stable UUID, owner, total touches, duration, source, completion time and app/counter versions | Owner reads; immutable inserts through an authenticated RPC |
| Private `avatars` bucket | A 512 px JPEG at `<user UUID>/avatar.jpg`; maximum 2 MiB | Owner writes; owner or opted-in public profile can obtain a five-minute download link |
| `public.juggling_leaderboard` RPC | Top 50 and the current player's neighboring ranks; at most 100 requested | Public, exposes only opted-in display information and eligible scores |

Profiles start with `Player` and sharing off. OAuth names, emails and provider photos are not copied to the public leaderboard. Existing accounts are backfilled, and new accounts get a profile through a tested signup trigger. Profile editing lets the player choose a name, country and sharing explicitly. Turning off sharing immediately removes the player from new leaderboard queries and prevents new public avatar links; already-issued avatar links expire within five minutes.

## Score rules

- Ranking uses total touches in the **best completed recorded session**. The current detector does not provide reliable drop-separated streaks, so this is not advertised as a consecutive-streak record.
- Only `source = recording` results count. Gallery imports are saved to private account history and can contribute to that account's personal best, but never to the leaderboard.
- Weekly ranking starts Monday at 00:00 UTC; all-time ranking retains the history. Equal scores are ordered by the earlier achievement, then user UUID for deterministic ordering.
- Each player appears once. Country filtering uses the profile's self-selected country. The UI falls back to the device region when choosing which country board to browse; it does not assign that region to the profile.
- The database binds submission ownership to `auth.uid()`. It rejects invalid counts/durations, materially future-dated results, and changes to an existing result. Repeating the same payload with the same UUID succeeds without another row.
- Results are explicitly `device_reported`, not verified. RLS protects account ownership; it does not prove a claimed camera source, score or timestamp. A tampered client can submit invented results. Server video validation/App Attest and abuse controls are future work before a prize-bearing or verified competition.
- The trusted service role can mark a session `rejected` or `verified`. App clients cannot set or change moderation status.

## App behavior

New recordings and completed import analyses open the editor immediately when their video is ready. Saving history never gates presentation. A root-owned task captures only small metadata and the source URL, writes a recovery journal/history/outbox off the main thread, and starts the local copy and cloud sync independently. The capture view can close or start another recording while saving continues. UUID video filenames prevent a fast second take from replacing the first source.

The outbox is stored in Application Support, protected on disk, under the recording account's UUID. Failed requests retry quietly with exponential backoff (3 seconds up to 180 seconds); foregrounding, account activation and network recovery trigger an immediate attempt. Successful uploads remove only the outbox record and retain local history. Routine pending uploads produce no banners, dialogs or retry prompts. The detail screen distinguishes a result on this phone from an account-confirmed result. Actual local save failures remain visible in History. No video or analysis frames are uploaded.

Guest training remains local. Signing in never claims an old device-wide personal best or another account's queue. Switching accounts clears displayed profile/photo/best state and prevents late responses from replacing the new account. Signed-in personal bests are loaded from that account's session history and pending results; guest records retain their existing local behavior.

The leaderboard uses live data with loading, empty and retry states. Sample players are available only in Debug with `--leaderboard-samples`, for design reviews and existing visual UI tests. Pull to refresh loads scores and renews avatar URLs.

## Session history

Home and Profile now open History. It lists completed juggling sessions by day, with All/Recorded/Imported filters, total touches, duration, source, local completion time and account-sync status. Details explain leaderboard eligibility without claiming that device-reported scores are verified. History includes imports and rejected results; those remain excluded from public rankings.

Account history reads the existing owner-protected `juggling_sessions` table. No additional Supabase configuration or migration is needed. Pages contain 30 results, ordered by completion time and UUID descending. The cursor preserves the server timestamp's microseconds and uses UUID to break ties; `Load older sessions` continues until the server returns no next page. Filtering applies to loaded results, and the load-older action remains available when a filter has no matches. Cached and pending entries merge by UUID. Refresh failures retain loaded records, and changing accounts resets navigation/data and discards late network responses.

`JuggleDudeResults/History/<account UUID or guest>/` in Application Support keeps small protected JSON entries and original videos. History can play the ready source file immediately while its permanent copy runs off the main thread. Copies are moved into place only after a complete write; videos are excluded from device backups. A small save-request journal survives an interrupted copy and resumes on account activation/foregrounding. Recovery preserves server-confirmed/moderated results and does not resubmit a confirmed score. iOS background-task grace time helps an in-flight save finish; force-quitting does not allow unlimited background execution. Recovery needs the original file still to exist.

Playback uses the original video; edited overlays and effect settings are not archived. A detail action can remove a completed local replay without changing its saved result or the Photos library. Video-copy failures leave the result intact and report the failure in History. There is no automatic video eviction; users can remove replays to reclaim storage.

Guest sessions use a separate device-only library and are never uploaded or assigned to a later login. New sessions preserve replay videos outside temporary storage. Earlier Supabase results still appear, but their original temporary videos cannot reliably be recovered. Other devices can load account results, not videos. Only fetched account results are available offline; this is not a full automatic account backup.

`SessionHistoryTests` covers old-outbox recovery, sync/restart persistence, pagination, offline caching, account and refresh races, date decoding, request authentication/encoding, moderation status, video retention/removal and guest isolation. `SessionHistoryUITests` exercises home/Profile entry, source filters, empty/detail states, replay and relaunch in both appearances. Its Debug-only `--history-review` fixtures use a separate library and disable account/network services; they never create production scores.

The nonblocking regression tests deliberately stall both a video copy and a server submission, verify immediate source playback, confirm cloud completion does not wait for copying, and exercise quiet automatic retry. The UI test adds a 60-second archive delay and still opens/plays the editor and History replay, then terminates/relaunches to verify recovery. `--history-save-delay` is available only with the isolated Debug history review store.

## Schema and validation

- Migration: `supabase/migrations/202610090001_profiles_and_juggling.sql` (apply once).
- Isolated PostgreSQL tests: `bash scripts/test-account-backend.sh`. The script creates and removes its own temporary cluster and never uses the existing local database. The local Storage fixture checks SQL policies; it does not emulate the Storage HTTP service.
- Swift tests: `PlayerStoreTests` covers durable queuing, retry identity, account separation, late responses, sign-out and profile validation. `AccountStoreTests` retains the authentication checks.
- The live anonymous API was checked: reading the leaderboard succeeds, reading profiles/session tables is denied, and submitting a complete score payload is denied.
- A real signed-in phone test is still needed to confirm photo upload and a newly recorded session across devices. Do not treat SQL policy tests as proof of a completed device upload.

The SQL Editor application was not registered in Supabase CLI migration history. Before the first future CLI push, link the project and reconcile this migration as already applied; do not run its CREATE statements against the existing tables again. Keep all future schema changes in additional migrations.

Account deletion now uses the authenticated `delete-account` Edge Function. It removes the avatar through the Storage API before hard-deleting the Auth user; foreign keys then cascade profiles and sessions. Migration `202610090002_account_deletion.sql` blocks profile/avatar/result writes once deletion starts. Both migrations were applied through the SQL Editor and need migration-history reconciliation before a future CLI push. See [account deletion](account-deletion.md) for Apple configuration, local cleanup and verification status. Subscription entitlements remain independent.

Reference: [Supabase user profiles](https://supabase.com/docs/guides/auth/managing-user-data), [Storage access policies](https://supabase.com/docs/guides/storage/security/access-control), [database functions](https://supabase.com/docs/guides/database/functions).

History query reference: [PostgREST filtering and ordering](https://docs.postgrest.org/en/stable/references/api/tables_views.html).
