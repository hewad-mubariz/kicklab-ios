# Juggle Dude account deletion

## Replacement release audit — 2026-10-19

The existing main branch had a separate display-cache bug: opening a signed-in
juggling replay also wrote that account's score into the device-wide guest personal
best. Returning to guest mode after deleting the account could therefore display the
old count even after its history and server account had been removed.

The replacement candidate passes the recording's original account ownership into
the replay and only writes guest scores into the guest cache. After confirmed account
deletion, cleanup rebuilds that cache from retained guest history (zero if none),
while preserving other accounts and Photos exports. Older guest best values without
a retained guest history entry cannot be distinguished from contaminated account
values and are not carried through that cleanup.

The read-only production audit found one account, one profile, 36 session rows,
no profiles without Auth users, no sessions without profiles, and no pending account
deletions. No production account was deleted for this audit. The local SQL test now
creates both recorded/imported results before deleting a disposable Auth user,
asserts their counts cascade away, and verifies another account's result survives.
All 117 selected iOS regression checks passed, including both deletion UI tests
and the new legacy-count checks, with no failures or skipped tests. The 15
deletion/recovery function tests and isolated PostgreSQL suite also passed. Results
are saved under `artifacts/releases/20261019-replacement/`. The deletion confirmation
now says “Confirm your identity with Apple to delete your Juggle Dude account.”
Apple's native sheet and verification flow are unchanged.
After installing the updated local candidate, the user explicitly authorized upload.
A fresh Release archive from main commit `713c757` passed package checks and uploaded
as 1.0.0 (26) on 2026-10-19. Archive and upload evidence is saved under
`artifacts/releases/20261019-upload26/`. Apple processing completed and build 26
is available to the two existing members of the internal Early testers group.
App Review submission remains on hold.
A fresh physical-device Apple authorization/revocation flow remains a separate check.

## Historical status — 2026-10-11

The signed-in Profile screen includes Delete account, a destructive confirmation, progress and recoverable errors. After the server confirms deletion, the app clears its local Auth session, removes that account's local history/outbox/replays and returns to guest mode. TestFlight 1.0 (8) is installed and opens on the owner's iPhone; its live account-deletion check is still outstanding.

Migration `202610090002_account_deletion.sql` and the `delete-account` Edge Function are deployed to Supabase project `shbdsjvpjdtqbiaevrxy`. The migration was applied through the dashboard, not CLI migration history; reconcile both existing migrations before a future `db push`.

**Apple server configuration is complete.** Key `Y8Y2T23D7C` is registered as Juggle Dude Account Deletion. All four Apple secrets below are saved in Supabase, with their displayed SHA-256 digests checked against the intended values. The private key is a valid P-256 PEM and is backed up as `config/local/AuthKey_Y8Y2T23D7C.p8`, git-ignored and owner-readable only. The supplied Downloads copy is also owner-readable only. No real account has been deleted or Apple authorization revoked during this implementation; a disposable-account device test remains outstanding.

## Data and authentication

- The client sends its publishable key and current Supabase access token. The server resolves the caller through Auth; no request can choose another user's UUID.
- Apple-linked accounts require a fresh native Apple authorization code. The server exchanges it, verifies Apple's signed ID token and checks its subject against the linked identity before revoking the resulting refresh/access token. A failure stops deletion.
- The server marks the profile as deleting, removes it from new leaderboard queries, and blocks subsequent profile/avatar/result writes. It deletes `<user UUID>/avatar.jpg` through Storage, then hard-deletes the Auth user. Foreign keys remove the profile and juggling results.
- The app requires a successful receipt for the same account before clearing account data. Cancellation or unconfirmed server failure keeps the local account and replays available for retry.
- A lost successful response can be retried using the original unexpired, cryptographically verified JWT plus an Admin Auth check that the account is absent. A rejected token for an existing account does not count as deletion.
- Local cleanup cancels/drains background work and guards late writes. A deletion journal supports retry after interrupted cleanup. Guest sessions, another account's library, and clips exported to Photos are preserved.
- Apple subscriptions are managed separately. The screen explains this and offers Manage Apple subscriptions. StoreKit Pro status is not fabricated or cleared by account deletion.

The dashboard's “Verify JWT with legacy secret” switch is off because it accepts legacy HS256 tokens. The function itself verifies identity through Supabase Auth before any account operation. Do not remove this verification or replace it with unverified JWT decoding. The app never holds an admin key.

## Apple server configuration

Store these in this project's Edge Function secrets, never in the iOS plist or tracked source:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `G276PSQ2LH` |
| `APPLE_KEY_ID` | `Y8Y2T23D7C` |
| `APPLE_CLIENT_ID` | `com.juggledude` |
| `APPLE_PRIVATE_KEY` | Full downloaded `.p8` PEM, with actual newlines or escaped `\n` |

The key must target the existing primary Apple App ID group containing `com.juggledude`. Keep the `.p8` backup owner-readable in git-ignored `config/local/`; Apple permits downloading a new key only once. Do not modify unrelated Apple keys. Native Apple sign-in's existing Supabase provider configuration stays in place.

The 2026-10-09 bundle migration updated `APPLE_CLIENT_ID` to `com.juggledude`. The saved Supabase SHA-256 digest matches that value. The existing Apple key and app grouping were retained, and all twelve endpoint tests passed using the new client ID. Real Apple sign-in and revocation still need a fresh device check on the new installation.

## Verification

- 41 Swift unit tests passed: 14 AccountStore, 9 PlayerStore, 15 SessionHistory and 3 AccountDeletionAPI tests. They cover identity binding, receipts, failure/cancellation, account isolation, cleanup and late background writes.
- Two isolated deletion UI tests passed: cancel then confirm returns to guest; server failure retains the account. Debug fixtures use a separate temporary library and fake account service, without production requests.
- Twelve Deno endpoint tests passed, including Apple identity mismatch, revocation-before-deletion, failure handling and retry after a lost response.
- The disposable PostgreSQL suite passed, covering existing profile/result policies plus deletion write restrictions. It never connects to the production database.
- Live endpoint requests without a user token and with a forged user token both returned 401 `sign_in_required`.
- The four saved Apple secret digests match their intended values, and OpenSSL validates the local private key. A non-destructive Apple token request using a deliberately invalid authorization code returned `invalid_grant`; a deliberately invalid-signature control returned the same response. This probe confirms endpoint reachability only, not acceptance of the key/client pairing. A fresh real Apple authorization code is required to test that pairing. See [Apple response error documentation](https://developer.apple.com/documentation/technotes/tn3107-resolving-sign-in-with-apple-response-errors).
- Simulator tests and the signed iPhone build passed; the latter was installed and launched normally. A successful live authenticated deletion and real Apple revocation remain untested.

Commands for focused backend checks:

```sh
bash scripts/test-account-backend.sh
npx --yes deno@2.9.6 test --config supabase/functions/deno.json supabase/functions/delete-account/index_test.ts
```

Use only a deliberately disposable account for the final device deletion check. A linked Apple account should present native Apple confirmation, then return to guest with its server profile/results/avatar gone. Cancel and network-failure paths must preserve the account. Do not delete the owner's existing account as a test.

The published privacy and terms pages were checked live on 2026-10-11 and describe account deletion, subscription-link deletion and separate Apple billing. The 15 deletion/reconciliation backend tests passed again during build-8 preflight. A real disposable Apple-linked account deletion and authorization revocation on the release candidate remain unverified; mocked tests do not establish that end-to-end result.
