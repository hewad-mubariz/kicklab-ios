# Meta install ads: measurement in 1.2.0

Approved by the owner on 2 November 2026 for release 1.2.0. The code is in [MetaAdsMeasurement](../kicklab/Analytics/MetaAdsMeasurement.swift). Meta Facebook iOS SDK 19.0.0 is pinned, and only `FacebookCore` is linked (no Facebook Login).

- Meta app: **Juggle Dude**, ID `1439446130906551`.
- iOS bundle `com.juggledude`; App Store ID `6820780610`.
- Ad account `1708504177514904`.
- Campaign link: `https://apps.apple.com/app/apple-store/id6820780610?pt=127870239&ct=instagram-live&mt=8`.

## What the app does

| | Outside the EEA, UK and Switzerland | Inside them (by App Store country) |
| --- | --- | --- |
| Tracking question not answered yet | Meta's standard setup: events go to Meta's non-tracking endpoint without the advertising ID | Nothing goes to Meta. The first-session event waits for the answer |
| **Allow** | Events go with the advertising ID | Meta starts and the waiting event is sent |
| **Ask App Not to Track** | Events go to the non-tracking endpoint, without the ID, used only in aggregate | Nothing goes to Meta, and waiting events are dropped |
| Apple SKAdNetwork | Registers the install | Registers the install. Apple reports it to the ad network with no data from the app |

**Why the regions differ.** In the EEA, the UK and Switzerland, sharing device data with Meta for advertising needs consent (GDPR and ePrivacy; in Germany, the TTDSG). There, Allow on Apple's tracking question is that consent. An unknown App Store country counts as one of these regions.

**What Meta receives:**
- App install and every app open.
- The first finished training session, sent as `CompletedTutorial` (juggling recording or Ball Distance).
- A Pro free trial (`StartTrial`, with currency) or a paid start (`Subscribe`, with price and currency).

Meta never receives videos, touch counts, account details, email or the purchase's identity. Automatic event logging, metadata collection, codeless logging, product improvement and AEM auto setup stay off. Event data use is limited to analytics and conversions.

**When the tracking question is asked:**
- Once, on a calm home screen.
- After the first finished training, or on the third launch if there's no training by then.
- Profile → Settings → Advertising measurement shows the answer and links to iPhone Settings.

PostHog's separate opt-in is never used as permission for Meta.

The release gate `JuggleDudeMetaAdsEnabled` is **on** in both Info.plists. Debug builds also need the launch argument `--enable-meta-install-measurement`. Tests and previews never start the SDK.

## Before submitting 1.2.0 (owner)

1. **Verify the published privacy policy** on the website. The Meta disclosure and related retention, consent, purchase and local-replay sections were published on 2 November 2026 (website commit `6c0061a`); App Review compares it with the app.
2. **Update the App Store privacy answers** in App Store Connect → App Privacy, as in the table below.
3. **Meta Business:** finish connecting the app to the business portfolio. The connection earlier failed with a technical error; access to portfolio `1096907693082408` is needed. Do not create a new ad account.
4. **Test on a phone** before submitting:
   1. Install the release build with a fresh install, finish one juggling session, and choose **Allow**.
   2. In Meta Events Manager → Juggle Dude → Test events, check that the install/open and Completed Tutorial arrive.
   3. A German App Store account follows the EU column, so only Allow sends anything.
5. **In App Review notes,** say that the app uses App Tracking Transparency for Meta ad measurement and when the question appears: after the first finished training, or on the third launch.

## After 1.2.0 is live

- Meta needs real events before Ads Manager lets you pick the app for the campaign.
- In Events Manager, keep SKAdNetwork and Aggregated Event Measurement as Meta sets them up. Rank the events: Subscribe, then StartTrial, then CompletedTutorial, then app install.
- Then finish the €60 test campaign (audience, dates, Reel creative, Install button) and review it before publishing.

## App Store privacy answers

**Data used to track you** (collected by Meta with Allow):

| Data type | Purpose |
| --- | --- |
| Device ID | Developer's Advertising or Marketing, Analytics |
| Product Interaction | Developer's Advertising or Marketing, Analytics |
| Purchase History | Developer's Advertising or Marketing |

The existing answers for account, training and purchases stay as they are. Check the Xcode privacy report from the archive, which combines the app's and the SDK's manifests, before entering the final answers.

## Published privacy policy and notice checks

The canonical disclosure is [privacy policy section 5a](https://juggledude.com/privacy/#advertising), effective for app version 1.2.0. It replaces the previous blanket claim that the app includes no advertising SDKs. Turning tracking off stops new app events in consent storefronts; outside them, measurement without the advertising identifier can continue. The policy does not promise that permission withdrawal or account deletion erases information already received by Meta, or apply PostHog's retention period to Meta.

The system tracking explanation is one sentence: “This helps us measure and improve our advertising.” It explains the advertising purpose in English, German, Spanish, French and Brazilian Portuguese. Both `Info.plist` and the localized `InfoPlist.xcstrings` must agree: iOS displays the localized value when present. Meta and the full event list stay named in Settings and the privacy policy; the Settings explanation also distinguishes consent storefronts and measurement without the advertising identifier. Apple controls the native prompt's heading, buttons and presentation. This shorter purpose string follows [Apple's guidance to explain the data's purpose](https://developer.apple.com/app-store/user-privacy-and-data-use/); it does not replace the privacy policy or App Store disclosures.

On 2 November, 12 measurement tests and 5 update-notice tests passed, plus the update-notice UI test. They cover permission timing, Allow/denial, withdrawal without backfilling a denied purchase, numeric version comparison, incompatible iOS versions and dismissal persistence. These use a recording transport; they do not prove delivery in Meta Events Manager.

For an owner-requested local phone preview, launch the Debug build with `--app-update-preview --enable-meta-install-measurement -kicklab.meta.launches 2`. The update version is a fixture (`1.3.0`); the notice is the production native SwiftUI alert. It waits for Home and any pending tracking permission prompt. **Update** opens the App Store; **Not now** dismisses that version, while Settings keeps the update link. The tracking question is the real iOS prompt, not a recreated view; iOS only presents it if permission has not been decided and device restrictions allow it. The launch override exercises the existing third-launch trigger without recording a fake training. Normal Debug launches keep Meta disabled. Release builds do not include the update fixture.

The update alert uses a neutral system tint (black in light mode, white in dark mode), scoped to the alert. Preview dismissal now survives relaunch too; only the explicit `--app-update-preview-reset` flag resets its separate test preference. The UI test dismisses the native alert, checks the Settings link, then relaunches and verifies the alert does not return. Clean cache-testing installs must launch without either update-preview flag or any analysis-cache bypass.
