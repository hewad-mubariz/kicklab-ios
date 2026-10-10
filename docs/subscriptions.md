# Juggle Dude subscriptions

## App Store configuration

- App: **Juggle Dude**, Apple app ID **6820780610**.
- Bundle: **com.juggledude**, team **G276PSQ2LH**.
- Subscription group: **Juggle Dude Pro**, ID **22456385**.
- Monthly: `com.hewad.juggledude.pro.monthly`, Apple ID **6820781795**, one month, **€4.99** in Germany.
- Yearly: `com.hewad.juggledude.pro.yearly`, Apple ID **6820783070**, one year paid upfront, **€29.99** in Germany.
- Both products are level 1 in the same group. No introductory offers or trial. Family Sharing remains off.
- German euro prices are the base; Apple calculated the other storefront prices. Both products have availability in all current storefronts and English (U.S.) display text.
- Paid Apps Agreement is active. An existing German sandbox test account is available under Users and Access → Sandbox.
- Products and app remain in Prepare for Submission. Nothing has been submitted for review or released.

The bundle was changed to `com.juggledude` on 2026-10-09 within the same App Store Connect app record. Subscription product IDs intentionally retain their existing prefix: changing the app bundle does not rename existing products. Earlier sandbox purchase verification below applies to the prior bundle; catalog and purchase behavior must be rechecked on the new identity.

## What the app implements

`SubscriptionStore` owns the transaction listener for the app lifetime. It accepts only StoreKit-verified transactions for the two known products, refreshes access at launch / foreground, and finishes verified transactions after processing access. A just-confirmed subscription is delivered directly from its verified, unrevoked, unexpired transaction if StoreKit has not yet published it in current entitlements; subsequent foreground and restore checks rebuild status from Apple’s current entitlements. Concurrent purchase, listener, and foreground refreshes are coalesced; callers await completion rather than returning while another refresh is still running.

The existing custom paywall fetches StoreKit products. Prices, currency, the approximate yearly monthly equivalent, and savings come from those products. At the German prices the annual saving is €29.89 (approximately 50%) versus twelve monthly payments. Missing prices are never replaced with a fake purchasable price.

Purchase cancellation stays quiet. Pending approval is explained and the transaction listener handles later approval. Restore explicitly calls `AppStore.sync()` only on a user tap. Profile displays active Pro and opens Apple's native subscription management sheet. None of these tasks gates camera capture, replay, local history, or Supabase sync.

As requested, this pass wires billing and Pro status only. Effects, ball styles and graphs are not locked yet. Pro currently follows the App Store account on the device, including when using the guest flow. A signed-in Supabase user UUID is included as `appAccountToken` for future server reconciliation. There is no client-writable Pro flag in Supabase and no server entitlement enforcement yet.

Deleting a Juggle Dude account does not cancel its Apple subscription or invalidate a verified StoreKit entitlement. The account-deletion section links to Apple's subscription management and explains this before confirmation. See [account deletion](account-deletion.md).

## Testing environments

### Local StoreKit testing

Choose the shared **JuggleDude-StoreKit** Xcode scheme to run with the local configuration. `kicklabTests/JuggleDude.storekit` is the scheme's source; the matching UI-test fixture is `kicklabUITests/JuggleDude.storekit`. These fixtures belong to test targets, not the shipping app. Local StoreKit testing does not charge an Apple Account.

The installed iOS 26.5 simulator exhibits Apple's known `SKInternalErrorDomain Code=3` StoreKit testing issue. The connected iPhone runs iOS 26.6.2 and supports local StoreKit tests. See [Apple's StoreKit testing issue discussion](https://developer.apple.com/forums/thread/826971).

### Apple's sandbox

Use the normal **JuggleDude** scheme (no StoreKit configuration selected) with the newly signed bundle. Local StoreKit tests and Apple's sandbox are separate environments.

1. Select **JuggleDude** in Xcode and run it on the phone, with Run → Options → StoreKit Configuration set to **None**. After local StoreKit tests, run this normal scheme once from Xcode to switch the device back to Apple’s sandbox; installing with the command line alone can retain the local testing environment.
2. Use Settings → Developer → Sandbox Apple Account to sign into the existing German sandbox account. Keep the phone's normal iCloud account signed in. Never share the password in source or chat.
3. Open Profile → Juggle Dude Pro. Confirm the displayed German prices, select a plan, and complete the Apple sandbox confirmation.
4. Confirm Pro Active, relaunch, and check that it remains active. Use Manage subscription to cancel or switch plans. Test Restore purchases, pending approval, expiry and refund as appropriate.

New App Store Connect metadata can take time to propagate. If no prices arrive, the paywall offers retry and remains dismissible. A successful local StoreKit test is not evidence that a real sandbox transaction has completed.

See [Apple's sandbox testing guide](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox).

## Before public release

Finalize actual Pro feature access, finish App Store review assets and submit the initial subscriptions with an app version. The paywall and sign-in screen link to the [Juggle Dude Privacy Policy](https://juggledude.com/privacy/) and [Terms of Use](https://juggledude.com/terms); the Terms page also links to Apple's standard EULA. Both pages were reachable on 2026-10-09 but remain pre-launch drafts with outstanding release details. App Store Connect legal metadata must also be checked before submission. Server-side features must verify Apple transactions / App Store Server Notifications before enforcing account-level Pro access; do not trust a boolean sent by the app. No server secret or App Store API key belongs in the app.

## Automated checks

The subscription suite uses real StoreKit Test transactions, not a fake purchase-success flag. Tests cover localized catalog values and savings, immediate verified purchase delivery with an account token, pending approval, cancellation, rejected verification, refund, expiry, restore, relaunch, and retryable network failures.

Verified on the connected iPhone (iOS 26.6.2): 12 subscription tests, 10 account tests and 2 paywall UI tests passed. The UI checks cover localized prices and savings, purchase, active Pro after relaunch, empty restore and closing the paywall. These transactions use local StoreKit Test.

For a read-only Apple catalog check, install a normal **JuggleDude** Debug build and launch it outside the XCTest runner with `--verify-subscription-catalog`. The console reports `JUGGLE_DUDE_CATALOG` with product, price and numeric Apple product ID. The real catalog IDs must be **6820781795** and **6820783070**, not local fixture IDs **10000001** and **10000002**. XCTest can retain its local catalog even under a scheme without a StoreKit configuration; a passing test-runner catalog request alone does not prove the Apple sandbox is connected. This diagnostic never purchases a product.

The normal build was installed and launched from Xcode on 2026-10-09. A subsequent device catalog check outside XCTest returned the real Apple product IDs **6820781795** (€4.99) and **6820783070** (€29.99). The Apple sandbox catalog is verified. After the user completed the monthly purchase on the phone, a fresh launch returned a StoreKit-verified transaction for `com.hewad.juggledude.pro.monthly`, with environment **Sandbox**, no revocation, and active monthly Pro. This is separate evidence from the local StoreKit tests. The actual Apple sandbox purchase and Pro persistence after relaunch are now verified.

Use the Debug-only launch argument `--verify-subscription-access` to inspect verified current subscriptions and the resulting Pro state. It prints product ID, StoreKit environment and revocation state, without receipts, transaction IDs or account details. Verification output is saved in `artifacts/subscriptions/apple-sandbox-purchase.txt`. The installed app has been relaunched normally without diagnostic arguments.

## Catalog check after bundle simplification

After changing the App Store record to `com.juggledude`, both existing subscription records remain attached to app **6820780610**. The signed new app builds, installs and launches, but two real-device catalog checks (including one after a normal Xcode launch with the JuggleDude scheme) returned zero products. No replacement products were created and no purchase was attempted. Apple metadata propagation is a possible cause, not a confirmed diagnosis. Recheck the real product IDs, purchase and restore on the new bundle before release; the earlier successful sandbox purchase applies to `com.hewad.juggledude`. Evidence: `artifacts/bundle-migration/catalog-after-xcode.log`.
