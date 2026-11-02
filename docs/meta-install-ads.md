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

1. **Publish the privacy policy paragraph below** on the website. App Review compares it with the app.
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
| Device ID | Third-Party Advertising measurement (Developer's Advertising or Marketing) |
| Product Interaction | Developer's Advertising or Marketing, Analytics |
| Purchase History | Developer's Advertising or Marketing |

The existing answers for account, training and purchases stay as they are. Check the Xcode privacy report from the archive, which combines the app's and the SDK's manifests, before entering the final answers.

## Privacy policy paragraph (to publish)

> **Advertising measurement (Meta).** To understand which Facebook and Instagram ads bring people to Juggle Dude, the app uses Meta's software development kit. It tells Meta when the app is installed and opened, when you finish your first training session, and when you start a Pro trial or subscription (with its price). Meta also receives device and app information and your IP address when the app contacts it. If you allow tracking in Apple's prompt, this includes your device's advertising identifier, and Meta may link it with information it holds to measure our ads. If you do not allow tracking, it is sent without the advertising identifier and Meta uses it only in aggregate. If your App Store country is in the European Economic Area, the United Kingdom or Switzerland, nothing is shared with Meta unless you allow tracking. Training videos, touch counts and account details are never included. Apple's SKAdNetwork also tells advertising networks, without identifying you, that an install came from an ad. You can change tracking permission at any time in your iPhone's Settings; this stops new sharing but does not delete what Meta already received. This is separate from our optional usage analytics.

Align this with the rest of the policy, Meta's terms, international transfers, retention and the existing contact and deletion process before publishing.
