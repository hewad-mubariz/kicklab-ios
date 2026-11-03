import Foundation
import Testing
@testable import kicklab

@MainActor
struct AppUpdateNoticeTests {
    private func notice(installed: String = "1.2.0", system: String = "18.4", store: AppUpdateNotice.Release?) -> AppUpdateNotice {
        AppUpdateNotice(installed: installed, systemVersion: system, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                        lookup: { _ in store })
    }

    @Test func versionsCompareByNumberNotText() {
        #expect(AppUpdateNotice.isNewer("1.10", than: "1.9"))
        #expect(AppUpdateNotice.isNewer("1.2.1", than: "1.2"))
        #expect(!AppUpdateNotice.isNewer("1.2", than: "1.2.0"))
        #expect(!AppUpdateNotice.isNewer("1.1.9", than: "1.2.0"))
        #expect(AppUpdateNotice.isNewer("2.0", than: "1.99.9"))
    }

    @Test func aNewerInstallableReleaseShowsOnceUntilDismissed() async {
        let update = notice(store: .init(version: "1.3.0", notes: "Crystal and fireworks.\nFixes.", minimumOS: "18.0"))
        await update.check()
        #expect(update.shouldPrompt)
        #expect(update.available?.headline == "Crystal and fireworks.")
        update.dismiss()
        #expect(!update.shouldPrompt, "Not now dismisses that version's alert")
        #expect(update.available?.version == "1.3.0", "Settings still offers the update")
    }

    @Test func theSameOlderOrUninstallableReleaseShowsNothing() async {
        for (store, system) in [("1.2.0", "18.4"), ("1.1.0", "18.4"), ("1.3.0", "17.5")] {
            let update = notice(system: system, store: .init(version: store, notes: nil, minimumOS: "18.0"))
            await update.check()
            #expect(!update.shouldPrompt, "\(store) on iOS \(system)")
            #expect(update.available == nil)
        }
    }

    @Test func aDismissedVersionStaysDismissedButTheNextOneShows() async {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AppUpdateNotice(installed: "1.2.0", systemVersion: "18.4", defaults: defaults,
                                    lookup: { _ in .init(version: "1.3.0", notes: nil, minimumOS: nil) })
        await first.check(); first.dismiss()
        let relaunched = AppUpdateNotice(installed: "1.2.0", systemVersion: "18.4", defaults: defaults,
                                         lookup: { _ in .init(version: "1.3.0", notes: nil, minimumOS: nil) })
        await relaunched.check()
        #expect(!relaunched.shouldPrompt, "Dismissal survives a relaunch")
        let next = AppUpdateNotice(installed: "1.2.0", systemVersion: "18.4", defaults: defaults,
                                   lookup: { _ in .init(version: "1.4.0", notes: nil, minimumOS: nil) })
        await next.check()
        #expect(next.shouldPrompt, "A later version is announced again")
    }

    @Test func checksAtMostEverySixHours() async {
        nonisolated(unsafe) var lookups = 0
        let update = AppUpdateNotice(installed: "1.2.0", systemVersion: "18.4", defaults: UserDefaults(suiteName: UUID().uuidString)!,
                                     lookup: { _ in lookups += 1; return nil })
        let start = Date()
        await update.check(now: start)
        await update.check(now: start.addingTimeInterval(3600))
        await update.check(now: start.addingTimeInterval(7 * 3600))
        #expect(lookups == 2)
    }
}
