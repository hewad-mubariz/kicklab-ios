# Juggle Dude Pro: App Review checklist

The paywall (kicklab/Pro, "Pro Pass") is UI only: nothing is connected to the App Store.
✅ is already in the UI. ⏳ must be done when purchases are connected, before submitting.

## Paywall screen (Guideline 3.1.2 and the subscription disclosure rules)

- ✅ The close button shows immediately and is never delayed or hidden.
- ✅ Each plan shows its name, the billed price and the period ("€24.99 / year"). The billed amount is the most prominent price; the per-month figure is secondary.
- ✅ The purchase button says what will be charged ("Get Pro · €24.99/year") and follows the selected plan.
- ✅ Renewal terms sit beside the button: the amount and period billed to the Apple Account, automatic renewal unless cancelled at least 24 hours before the period ends, and where to manage or cancel.
- ✅ A Restore purchases button.
- ✅ No countdowns, fake discounts or pressure.
- ⏳ Terms of Use and Privacy Policy must open real pages; today they show a placeholder. Add the same links in App Store Connect: the Privacy Policy URL, and either Apple's standard EULA or your own.
- ⏳ Prices, periods and the saving must come from StoreKit (`Product.displayPrice`, `subscription.subscriptionPeriod`), not the hard-coded euro values. Reviewers use other storefronts. Recompute "Save 48%" from the real prices, or drop it.
- ⏳ If a free trial is added, show its length and the price after it as clearly as the price itself.
- ⏳ The three features must be exactly what Pro unlocks, and the free app must stay complete and useful (Guidelines 2.1 and 3.1.2).

## Purchases

- ⏳ StoreKit 2 auto-renewable subscriptions: monthly and yearly in one subscription group.
- ⏳ Don't require signing in to buy (Guideline 5.1.1(v)). The purchase belongs to the Apple Account; linking it to a Juggle Dude account can come after.
- ⏳ Restore with `AppStore.sync()`; read access from `Transaction.currentEntitlements` and listen to `Transaction.updates`.
- ⏳ "Manage subscription" in Profile or Settings (`manageSubscriptionsSheet`).
- ⏳ Handle Ask to Buy (pending), refunds and revocations, and billing grace periods.
- ⏳ Submit the subscriptions together with the app version, each with a review screenshot of this paywall.
- ⏳ Review notes: where the paywall is (Profile → Juggle Dude Pro) and which features it unlocks.

## Content

- ✅ The hero uses the app's own juggling photo with no brand logos (Guideline 5.2).
- ⏳ The prices are samples; confirm the final prices and the feature list.
