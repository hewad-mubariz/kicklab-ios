# Juggle Dude account setup

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
