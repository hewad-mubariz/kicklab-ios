# Juggle Dude account setup

## Current rollout status — 2026-10-18

The owner authorized the Google/email rollout on
`codex/post-launch-signin-leaderboard-ball-edges`, with building deferred.
The source now exposes **Apple, Google, email and guest** on the shared welcome/Profile
sign-in screen. Google uses the existing browser OAuth/PKCE flow; email uses the
existing passwordless form, resend cooldown and verified-domain callback. No provider
configuration, authentication protocol or purchase entitlement was changed.

The follow-up source review fixes pending-email recovery: starting Google clears the
old pending email because the SDK replaces its shared PKCE verifier, even if the
browser is subsequently cancelled. A failed resend also clears the previous pending
link and returns to the email form with the error visible. Cancelling native Apple
sign-in preserves a pending email link. The cooldown is preserved across provider
changes; three focused regression cases cover these behaviors.

The existing UI checks now cover all providers, email validation/back navigation,
guest continuation and large-text reachability. They do not submit email requests
or complete external Google authorization. The Swift unit/UI checks have **not been
executed** for this change; syntax-only parsing and `git diff --check` passed. No
project build, device installation, email request or upload was performed.

**Read-only live checks, 18 October:** Supabase `/auth/v1/settings` returned HTTP 200
with Apple, Google and email enabled, sign-ups enabled and email auto-confirmation
disabled. Both the website's association file and Apple's standard association CDN
returned HTTP 200 with `G276PSQ2LH.com.juggledude` and the two `/auth/email` paths.
The owner reconfirmed SES approval and completed Google branding. These checks verify
provider availability and link association, not actual delivery or completion of a
fresh sign-in. Evidence: `artifacts/signin-rollout-20261018/readiness.json`.

Before rollout, build and run the account/link/history/subscription regression checks,
then verify Google authorization/cancellation, email delivery and completion, expired
links, relaunch/session restoration, sign-out and existing purchase access on the
candidate. Provider enablement and link association were checked again above; the
detailed SES quotas and Supabase sending-limit notes below were last inspected on
12 October. Recheck the project-wide email limit and delivery monitoring before
public rollout; SES production approval does not set those Supabase limits.

Guest history is retained in its device-only guest library and becomes visible again
after sign-out. Signing in does not claim guest results or merge different account
histories. This is the existing ownership behavior; automatic migration/account
linking is not part of enabling the provider buttons.

### Provider setup verified — 2026-10-12

The submitted first release offered **Apple sign-in + guest**. At this setup checkpoint,
the Google and email controls remained commented out for a later update. That setup
pass changed no iOS source, build, installation, or App Store submission; the
18 October source rollout above supersedes the hidden-controls status.

Google's setup is ready for that later rollout:

- **Audience:** External, **In production**.
- **Branding:** **Verified and published**. Google confirms: “Your branding has been verified and is being shown to users.”
- **Name and logo:** Juggle Dude, with the existing default app icon.
- **Website:** `https://juggledude.com/`; privacy: `https://juggledude.com/privacy/`; terms: `https://juggledude.com/terms/`.
- **Support and developer contact:** `hewadmubariz@gmail.com`, the eligible Google account already configured.
- **Authorized domains:** `juggledude.com` and the existing `shbdsjvpjdtqbiaevrxy.supabase.co` callback host. Callback and credentials were not changed.
- **Ownership:** `juggledude.com` verified as a Domain property in Google Search Console by a root DNS TXT record at GoDaddy. Keep that verification TXT record.
- **Data access:** only `openid`, `userinfo.email`, and `userinfo.profile`; no sensitive or restricted scopes. Google says data-access verification is not required.

The website privacy policy and terms now describe Google/email sign-in where offered and explicitly say the first App Store release offers Apple sign-in. Website commit `3681e1a` was pushed to `main` and deployed; type checking and the production build passed, and both live policy pages returned HTTP 200 with the 12 October 2026 revision. Local evidence is in `artifacts/google-branding-20261012/`, including `branding-verified-published.png` and `status.json`.

Before the later app rollout, enable the controls only with the owner's instruction and test Google sign-in, cancellation, session recovery, and sign-out on that build. This pass verified the Google configuration, not a newly enabled on-device flow. Google consent-screen branding does not replace the Supabase host used by the iOS browser authentication prompt; a custom auth domain is a separate change.

**AWS — verified later on 12 October:** SES production access is granted in Europe (Stockholm), `eu-north-1`. The console reports **50,000 emails per 24 hours**, **14 emails/second**, and **Healthy** account status. The `juggledude.com` identity is verified; DKIM signing is successful/enabled with 2048-bit keys and custom MAIL FROM `mail.juggledude.com` is successful. Public DNS includes SES SPF and DMARC `p=quarantine`.

Supabase custom SMTP is enabled with the existing Stockholm endpoint, port 587, sender name Juggle Dude, and a 60-second minimum interval per recipient. Its separate project-wide email rate limit is still **30/hour** and was left unchanged. Bounce and complaint suppression is enabled, with no suppressed addresses at inspection. Email feedback forwarding is enabled; no SNS feedback topics are configured, and SES onboarding reports event monitoring not set up. Before enabling email sign-in for a public audience, agree an appropriate Supabase hourly limit and establish a monitored feedback/alert destination. These are separate from the approved SES sending quota.

With the owner's explicit authorization, one test was requested through Supabase Auth for `hewadmubariz@gmail.com` at **09:43 Europe/Berlin**. The request used `create_user: false` and PKCE; HTTP 200 was returned. The delivered message was observed in the Gmail **Inbox**, with subject “Your Juggle Dude sign-in link”, sender `Juggle Dude <noreply@juggledude.com>`, `mailed-by: mail.juggledude.com`, `signed-by: juggledude.com`, and TLS. This proves the current Supabase → SES → Gmail delivery path and branding. The recipient was already verified in SES, so delivery to a previously unverified recipient was not independently exercised; production permission is confirmed by the SES console. The sign-in link was not consumed by the agent, and no app or provider setting was changed. Evidence: `artifacts/ses-production-20261012/`.

Historical sandbox limits below must not be treated as the current verified state. The public support mailbox was confirmed in the later release work; the earlier note below about needing an inbound mailbox is historical.

The sections below record the earlier implementation and tests; this dated rollout status takes precedence over earlier statements about Testing mode, draft policies, and pending AWS approval.

## Projects and callbacks

| Setting | Value |
| --- | --- |
| Google Cloud project | `juggle-dude-auth-shbdsj` — Juggle Dude |
| Supabase project | `shbdsjvpjdtqbiaevrxy` |
| Supabase URL | `https://shbdsjvpjdtqbiaevrxy.supabase.co` |
| Google authorized redirect URI | `https://shbdsjvpjdtqbiaevrxy.supabase.co/auth/v1/callback` |
| Supabase additional redirect URL | `juggledude://auth/callback` |
| Apple app bundle ID | `com.juggledude` |

The app URL scheme is `juggledude`. The Apple bundle ID is `com.juggledude`. The earlier development installation has a separate identity; its local files and Keychain session do not automatically migrate. Keep that installation until any local replays have been exported.

## Google sign-in

The Google Cloud project was created using `gcloud projects create`. The CLI's previous default project was preserved. Standard Google Sign-In OAuth clients must be configured in Google Auth Platform; `gcloud iam oauth-clients` manages Workforce Identity Federation clients instead.

1. Open [Google Auth Platform](https://console.cloud.google.com/auth/overview?project=juggle-dude-auth-shbdsj) and register Juggle Dude with an External audience for consumer Google accounts.
2. Request only `openid`, `https://www.googleapis.com/auth/userinfo.email`, and `https://www.googleapis.com/auth/userinfo.profile`.
3. For the planned Supabase browser OAuth flow, create a **Web application** client named **Juggle Dude — Supabase** with the Google redirect URI above. The iOS app opens Google's login through `ASWebAuthenticationSession`; Supabase handles the server-side code exchange.
4. Save the client ID and secret in the Supabase project's Google provider settings. The Google client secret belongs in Supabase, never in the iOS app or its plist.
5. Add `juggledude://auth/callback` to Supabase Authentication → URL Configuration → Redirect URLs.

## App configuration

`kicklab/Account/SupabaseConfig.plist` is git-ignored. It holds the project URL, publishable key, and app redirect URL. Its template is `config/SupabaseConfig.example.plist`. No secret or service-role key belongs in the app.

As of this setup pass, the local publishable key is accepted by Supabase's Auth settings endpoint. Google, native Apple, and email are enabled. The app links the Auth product from the official Supabase Swift SDK (pinned to 2.55.3). Provider buttons call real authentication; guest training remains available.

## References

- [Supabase Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google)
- [Google OAuth client setup](https://support.google.com/cloud/answer/15549257)
- [Google CLI OAuth command scope](https://docs.cloud.google.com/iam/docs/workforce-oauth-app)
- [Supabase native app redirects](https://supabase.com/docs/guides/auth/native-mobile-deep-linking)

## Google configuration completed

The Google project, External app registration, Web application client, callback, and three basic scopes are configured. The client ID is `312611098464-dkqd08atv84ne68qpj772j4t0ivn8qus.apps.googleusercontent.com`. Its secret is saved in Supabase and backed up in `config/local/google-oauth-client.json` (git-ignored, owner-readable, outside the iOS source directory). Google remains in testing mode, with the project owner's account added as a test user. Supabase reports Google sign-in enabled. Public release still requires completing the Google branding/publishing setup.

## Implemented app behavior

- Google opens `ASWebAuthenticationSession` and exchanges the returned code using PKCE.
- Email sends passwordless Universal Links on `https://juggledude.com/auth/email/`. The app verifies them directly with Supabase and exchanges the returned code using its original PKCE verifier. The email sheet validates addresses, supports resending after a cooldown, and shows delivery failures without claiming a link was sent.
- Apple uses the native authorization controller, a cryptographically random nonce and SHA-256 challenge, followed by the Supabase ID-token exchange. A first-login name is saved to account metadata when available.
- Sessions and PKCE state are stored by the SDK in Keychain. Expired stored sessions are refreshed before being presented as signed in. Refresh follows the app lifecycle.
- The profile displays the account email and a separate editable app profile, and signs out the current device. Signed-in names/photos and juggling results now use Supabase; guest profile names/photos remain local. See [player data and leaderboard setup](player-data.md).
- Callbacks are restricted to the configured scheme, host and path. Successfully consumed links are deduplicated in memory. Raw provider errors, codes and tokens are not displayed or logged.

## Device testing

1. Open Profile → Sign in, or the welcome screen on a fresh install.
2. Choose Google and complete authorization with the configured test account. The profile should show the account email.
3. Close and reopen the app. Confirm the account is restored, then sign out and confirm guest training remains available.
4. Choose email and use `hewadmubariz@gmail.com` while SES remains in sandbox (it is the verified test recipient). After AWS grants production access, other recipients can be used. Request a fresh link from the app and open the newest link on the same device that requested it; PKCE requires the original verifier. The delivery-only test sent from the development computer cannot complete an iPhone sign-in.
5. Choose Apple on a signed device build and complete the native prompt. The embedded provisioning profile must include `com.apple.developer.applesignin`.
6. Cancel a provider prompt and try again. Test an expired email link; the app should offer a clear retry message.

## Remaining release setup

Amazon SES custom SMTP and branded templates are deployed and a test email was delivered. AWS production access is still required before arbitrary users can receive email; the request was submitted with the owner's approval on 2026-10-09 and is **Under review**. AWS's confirmation says review may take up to 24 hours. Sandbox restrictions remain until AWS approves it. See [email delivery](#email-delivery) below. Google remains in Testing until its branding/publishing setup is complete. Account deletion is implemented, its backend is deployed, and the Apple revocation key is securely configured in Supabase. A real deletion/revocation test with a disposable account remains outstanding. See [account deletion](account-deletion.md) for exact configuration and verification status. These are separate from exercising the implemented sign-in flows on the development build.

## Email delivery

Configured on 2026-10-09 for Supabase project `shbdsjvpjdtqbiaevrxy`:

| Setting | Value |
| --- | --- |
| Provider / region | Amazon SES / `eu-north-1` |
| SMTP endpoint / port | `email-smtp.eu-north-1.amazonaws.com` / `587` (STARTTLS) |
| Sender | `Juggle Dude <noreply@juggledude.com>` |
| Custom MAIL FROM | `mail.juggledude.com` |
| Site URL and allowed app callback | `juggledude://auth/callback` |
| Supabase limits | 30 emails/hour; 60 seconds between emails to the same user |
| SES sandbox limits | 200 emails/24 hours; 1 email/second; verified recipients only |

The three DKIM CNAMEs and MAIL FROM MX/TXT records are saved at GoDaddy. SES reports identity verified, DKIM successful/enabled, and custom MAIL FROM successful. Existing website and DMARC records were preserved. Account-level suppression is enabled for both bounces and complaints. The operator must monitor SES reputation and suppression records and investigate delivery problems before retrying suppressed recipients.

The `juggledude-supabase-smtp` IAM user belongs to `AWSSESSendingGroupDoNotRename`. Its `AmazonSesSendingAccess` inline policy allows only `ses:SendRawEmail`, with `Resource: "*"` and an exact `ses:FromAddress` condition of `noreply@juggledude.com`. This follows AWS's sender-restriction pattern; restricting only the domain ARN also blocked the verified test recipient and SES's generated configuration set. No administrative SES actions are granted. Credentials are encrypted in Supabase and backed up only in the owner-readable, git-ignored `config/local/ses-smtp-credentials.csv`, outside the app sources.

The [magic-link and confirmation templates](../supabase/templates/README.md) are deployed and contain no external images or tracking assets. They originally used `{{ .ConfirmationURL }}`; later on 2026-10-09 they were changed to verified-domain Universal Links as described below. SES click tracking remains off. Gmail may apply its own link wrapper independently of the sender.

Verification: SMTP authentication returned 235 over TLS; Supabase's passwordless email endpoint returned HTTP 200; one email arrived in the test recipient's Gmail inbox at 23:26 Europe/Berlin. Gmail showed `mailed-by: mail.juggledude.com`, `signed-by: juggledude.com`, and TLS. This proves delivery, not completion of the PKCE sign-in exchange on the new iPhone installation. Request a new link from the app for that check.

AWS's production request was submitted on 2026-10-09 at approximately 23:30 Europe/Berlin for transactional email, website `https://juggledude.com`, and contact `hewadmubariz@gmail.com`. The owner explicitly approved the AWS Service Terms/AUP acknowledgement and confirmed the requested-email and bounce/complaint-handling practices. The console confirmed successful submission and shows **Under review**, with a stated review time of up to 24 hours. Submission does not mean approval; the account remains in sandbox. The root domain currently has no MX record, so `hello@juggledude.com` still needs an inbound mailbox or forwarding service for public support; SES outbound setup does not create one.

## Direct email app links

The browser's “Allow opening another application” prompt came from the legacy HTTPS verification → custom URL scheme handoff. To reduce that browser step, the email button now points directly to `https://juggledude.com/auth/email/#token_hash=…&type=magiclink` (signup uses `type=signup`). Never log, share, or screenshot an actual token-bearing URL.

The website repository at `../juggle-dude-website` deployed commit `430fadc`, which adds the AASA file, a safe browser fallback, response headers, and link-validation checks. The AASA allows only the email paths for `G276PSQ2LH.com.juggledude`; both the origin and Apple's association CDN returned HTTP 200 with the matching JSON. The fallback validates the fragment locally, removes it from browser history, and never consumes a token, stores a session, or makes an authentication request. Its manual custom-scheme button is a fallback and may still need browser confirmation.

The app is signed with `applinks:juggledude.com`, handles `NSUserActivityTypeBrowsingWeb` and incoming URLs, and validates the exact origin, path, parameters, verification type, and PKCE token format. It calls only its configured Supabase verification endpoint using an ephemeral URLSession with redirects disabled. It accepts only the existing `juggledude://auth/callback` response, then lets the Auth SDK perform the original device-bound code exchange. Google OAuth and earlier email callbacks remain supported.

Verification: the signed iOS build and 18 focused account/link tests passed on the physical iPhone. Website type checking, static build, malformed-link tests and browser fallback checks passed. Vercel deployed the website, and both Supabase templates were saved. A delivered email at 00:00 on 2026-10-10 was inspected without opening its token: it contained the new HTTPS app link with the expected PKCE fragment. Previously sent emails retain their old links.

**Root cause confirmed, 2026-10-10:** iOS initially did not approve the domain, so even a token-free link in Notes opened the website. A controlled network probe on the physical iPhone confirmed that the origin serves the correct AASA (200), while Apple's normal association URL returns a cached 404. Maccu's association returns 200 via the same Frankfurt edge, and a single uncached diagnostic request for Juggle Dude also returns the correct file. The failing response was cached at 23:44:56 Berlin, before the AASA deployment at 23:47:32. Its `Cache-Control: max-age=3600` predicts freshness expiry at approximately 00:44:56. This is independent of SES and the internal bundle name. The exact signed identifier and associated domain match the AASA. The diagnostic query is not used in the app; production configuration remains `applinks:juggledude.com`.

For future associated domains, publish the AASA before installing a build that declares the domain. Verify the exact standard Apple CDN URL from the device; a successful origin request or a diagnostic URL with a query does not prove that the device’s normal cache has refreshed. Installing the app before deployment can cache a missing-file response.

Evidence is saved locally in `artifacts/email-setup/association-diagnostic-20261010.txt`. A bounded on-device check recorded the standard CDN URL changing from 404 (Age 3587) at 00:44:43 to 200 (Age 0, matching app ID) at 00:45:44, immediately after cache expiry. The temporary network probe was removed from the test target. The clean build 3 succeeded and was installed at 00:47. The phone’s own `swcd` log then recorded HTTP 200 and `sa = approved`, proving recovery of the production association. The user then requested a fresh email from the updated iPhone app and confirmed: “Opens directly and signs in.” This completes the end-to-end verification of the new email route on this iPhone/Gmail setup. Other email clients and device preferences may still choose the documented browser fallback. Apple documents no direct CDN invalidation API. The manual website fallback may still trigger browser confirmation.

The sign-in screen and paywall now open the published [Privacy Policy](https://juggledude.com/privacy/) and [Terms of Use](https://juggledude.com/terms) in the system browser. Both URLs returned HTTP 200 on 2026-10-09 (Terms redirects to `/terms/`). Both pages currently identify themselves as pre-launch drafts: contact details, processing/retention details, account deletion and final Pro benefits still need completion before public release. Connecting these links does not complete those release tasks.

## Verification from this implementation pass

The simulator build and signed iPhone build succeeded. All 10 account unit tests and all 3 sign-in UI tests passed (dark/light appearance, guest persistence and accessibility text). Following the session-refresh adjustment, the account tests and dark/light account UI test passed again. The signed build was installed and launched on the connected iPhone 17 Pro Max. On 2026-10-09, the user reported “all seems to work” after device testing. This records user-reported success; individual provider and session-lifecycle results were not separately enumerated. The release setup above remains outstanding.

## Bundle migration for Juggle Dude

On 2026-10-09, the bundle was simplified from `com.hewad.juggledude` to `com.juggledude`. The iOS app and its test targets now use `com.juggledude`, `com.juggledude.tests`, and `com.juggledude.uitests`. Apple registered the new app identifier as **Juggle Dude App**, with Sign in with Apple, In-App Purchase, and Background GPU Access enabled. App Store Connect record **6820780610** now uses the new bundle ID; no replacement store record was needed because no build had been uploaded. The new identifier is grouped with the previous development identifier for Apple sign-in continuity. Supabase's native Apple client allow-list includes the new identifier and retains both previous development clients during migration. The deletion function’s `APPLE_CLIENT_ID` is now `com.juggledude`; its existing Apple key remains valid for the same primary App ID group. Account deletion with Apple must be exercised from the new installation. Google uses browser OAuth through Supabase, so its Web client and callback do not depend on this bundle change.

The new app is a separate iOS installation. It requires a new sign-in, and local-only replays from the previous installation are not automatically copied. Keep the old app until those replays are exported. The development installations currently register the `juggledude` URL scheme, so email-link testing should use the new installation and confirm that iOS opens it; avoid requesting simultaneous sign-in links from both apps. User confirmation of Apple/Google/email after this bundle change is still needed.

The signed build with the new bundle passed and was installed on the connected iPhone. Its embedded profile includes Apple sign-in and Background GPU Access, and background video task identifiers now use `com.juggledude.video.*`.

See [subscriptions](subscriptions.md) for App Store product IDs and sandbox setup. Existing subscription product IDs remain unchanged; product IDs are separate from the app bundle identifier.

## Built app name correction — 2026-10-10

The built app was found to have `CFBundleName = kicklab` even though the source Info.plist and display name used Juggle Dude. Both app build configurations now use product name `Juggle Dude`; an explicit Info.plist name setting is also present. The product reference, shared schemes, test-host paths, and phone-install script were updated. The Swift module remains unchanged for existing imports. The signed Debug product was verified with `CFBundleName`, `CFBundleDisplayName`, and `CFBundleExecutable` all set to `Juggle Dude`, then installed and launched on the connected iPhone at approximately 00:17. Bundle ID `com.juggledude`, team ID `G276PSQ2LH`, and the associated-domain entitlement remain unchanged. This fixes the internal naming issue; it does not resolve the observed association CDN 404.

The corrected product was installed as version 1.0, build 2 at approximately 00:20. All 18 focused account and link tests passed on the physical iPhone at 00:23 after retrying a device-connection failure and rebuilding the test host. Final signed metadata confirms all three names, the bundle identifier, team identifier, and associated-domain entitlement.
