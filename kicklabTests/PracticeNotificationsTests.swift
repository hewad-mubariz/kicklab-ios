import XCTest
import UserNotifications
@testable import kicklab

@MainActor
final class PracticeNotificationsTests: XCTestCase {
    private var suite = ""
    override func setUp() { super.setUp(); suite = "PracticeNotificationsTests." + UUID().uuidString }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suite); super.tearDown() }

    private func make(_ supplied: NotificationClientStub? = nil) -> (PracticeNotifications, NotificationClientStub) {
        let client = supplied ?? NotificationClientStub()
        return (PracticeNotifications(defaults: UserDefaults(suiteName: suite)!, client: client), client)
    }

    func testOpeningSettingsNeverRequestsPermissionOrSchedulesByDefault() async {
        let (store, client) = make()
        await store.refresh()
        XCTAssertFalse(store.practiceEnabled); XCTAssertFalse(store.exportsEnabled)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(client.reminders.isEmpty)
    }

    func testEnablingPracticeRequestsPermissionAndStoresTimeWithoutSchedulingLocalDuplicates() async {
        let (store, client) = make()
        await store.setPracticeEnabled(true)
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertTrue(store.practiceEnabled)
        XCTAssertTrue(client.reminders.isEmpty)
        await store.setTime(hour: 7, minute: 35)
        XCTAssertEqual(store.minuteOfDay, 7 * 60 + 35)
        await store.refresh()
        XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertEqual(client.permissionRequests, 1)
        await store.setPracticeEnabled(false)
        XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertFalse(store.practiceEnabled)
    }

    func testExistingOptInKeepsSavedTimeWhileRemovingTheOldLocalSchedule() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "juggledude.notifications.daily")
        defaults.set(7 * 60 + 35, forKey: PracticeNotifications.timeKey)
        let client = NotificationClientStub(); client.status = .authorized
        client.reminders = PracticeNotifications.reminders(minuteOfDay: 1080)
        let (store, _) = make(client)
        await store.refresh()
        XCTAssertTrue(store.practiceEnabled)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertEqual(store.minuteOfDay, 7 * 60 + 35)
        let (reopened, _) = make(client)
        XCTAssertTrue(reopened.practiceEnabled)
        await reopened.setPracticeEnabled(false)
        let (disabled, _) = make(client)
        XCTAssertFalse(disabled.practiceEnabled)
    }

    func testExportOptInDoesNotEnablePracticeAndChoicesSurviveRelaunch() async {
        let (store, client) = make()
        await store.setExportsEnabled(true)
        await store.setTime(hour: 21, minute: 15)
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertTrue(client.reminders.isEmpty)
        let (reopened, _) = make(client)
        XCTAssertTrue(reopened.exportsEnabled); XCTAssertFalse(reopened.practiceEnabled)
        XCTAssertEqual(reopened.minuteOfDay, 21 * 60 + 15)
    }

    func testDeniedPermissionKeepsPreferenceButRemovesScheduledReminderAndDoesNotReprompt() async {
        let client = NotificationClientStub(); client.status = .authorized
        let (store, _) = make(client)
        await store.setPracticeEnabled(true)
        XCTAssertTrue(client.reminders.isEmpty)
        client.status = .denied
        await store.refresh()
        XCTAssertTrue(store.practiceEnabled); XCTAssertFalse(store.isAllowed)
        XCTAssertTrue(client.reminders.isEmpty)
        await store.setExportsEnabled(true)
        XCTAssertEqual(client.permissionRequests, 0)
        client.status = .authorized
        await store.refresh()
        XCTAssertTrue(client.reminders.isEmpty)
    }

    func testDisablingWhilePermissionDialogIsPendingWins() async {
        let client = NotificationClientStub()
        client.holdsPermission = true
        let asked = expectation(description: "Permission opened")
        client.didRequest = { asked.fulfill() }
        let (store, _) = make(client)
        let enabling = Task { await store.setPracticeEnabled(true) }
        await fulfillment(of: [asked], timeout: 2)
        let disabling = Task { await store.setPracticeEnabled(false) }
        // Let the disable update the desired preference before the OS responds.
        while store.practiceEnabled { await Task.yield() }
        client.permissionResponse?.resume(); client.permissionResponse = nil
        await enabling.value; await disabling.value
        XCTAssertFalse(store.practiceEnabled)
        XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertFalse(store.isUpdating)
    }

    func testScheduleFailureIsVisibleAndRetryDoesNotRequestPermissionAgain() async {
        let client = NotificationClientStub(); client.failsScheduling = true
        let (store, _) = make(client)
        await store.setPracticeEnabled(true)
        XCTAssertNotNil(store.errorMessage)
        client.failsScheduling = false
        await store.refresh()
        XCTAssertNil(store.errorMessage); XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testInvalidSavedTimeFallsBackAndInvalidEditDoesNotChangeIt() async {
        UserDefaults(suiteName: suite)!.set(1600, forKey: PracticeNotifications.timeKey)
        let (store, _) = make()
        XCTAssertEqual(store.minuteOfDay, 1080)
        await store.setTime(hour: 24, minute: 0)
        XCTAssertEqual(store.minuteOfDay, 1080)
    }

    func testSessionCompletionOnlyMakesPromptEligibleAndAllowEnablesPracticeOnce() async {
        let (store, client) = make()
        await store.requestAfterSessionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 0)
        store.sessionCompleted()
        XCTAssertTrue(store.shouldAskAfterSession)
        XCTAssertEqual(client.permissionRequests, 0, "Completion must not interrupt the replay")
        let (reopened, _) = make(client)
        XCTAssertTrue(reopened.shouldAskAfterSession)
        await reopened.requestAfterSessionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertTrue(reopened.practiceEnabled)
        XCTAssertTrue(reopened.presentedSessionPromptThisLaunch)
        XCTAssertFalse(reopened.shouldAskAfterSession)
        XCTAssertEqual(reopened.minuteOfDay, 18 * 60)
        XCTAssertTrue(client.reminders.isEmpty)
        let (nextLaunch, _) = make(client)
        await nextLaunch.requestAfterSessionIfNeeded()
        XCTAssertTrue(nextLaunch.practiceEnabled)
        XCTAssertFalse(nextLaunch.presentedSessionPromptThisLaunch)
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testSessionPromptDenialKeepsPracticeOffAndNeverAutomaticallyAsksAgain() async {
        let client = NotificationClientStub(); client.permissionResult = .denied
        let (store, _) = make(client)
        store.sessionCompleted()
        await store.requestAfterSessionIfNeeded()
        XCTAssertFalse(store.practiceEnabled)
        XCTAssertFalse(store.isAllowed)
        let (reopened, _) = make(client)
        reopened.sessionCompleted()
        await reopened.requestAfterSessionIfNeeded()
        XCTAssertFalse(reopened.shouldAskAfterSession)
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testSessionPromptPreservesExistingPracticeChoicesAndTime() async {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(7 * 60 + 35, forKey: PracticeNotifications.timeKey)
        for enabled in [false, true] {
            defaults.set(enabled, forKey: PracticeNotifications.enabledKey)
            let (store, client) = make()
            store.sessionCompleted()
            await store.requestAfterSessionIfNeeded()
            XCTAssertEqual(store.practiceEnabled, enabled)
            XCTAssertEqual(store.minuteOfDay, 7 * 60 + 35)
            XCTAssertEqual(client.permissionRequests, 0)
        }
    }

    func testPreviousSystemPermissionDoesNotSilentlyEnrollPractice() async {
        let client = NotificationClientStub(); client.status = .authorized
        let (store, _) = make(client)
        await store.setExportsEnabled(true)
        store.sessionCompleted()
        await store.requestAfterSessionIfNeeded()
        XCTAssertTrue(store.exportsEnabled)
        XCTAssertFalse(store.practiceEnabled)
        XCTAssertFalse(store.shouldAskAfterSession)
        XCTAssertFalse(store.presentedSessionPromptThisLaunch)
        XCTAssertEqual(client.permissionRequests, 0)
    }

    func testLeavingHomeBeforePermissionCheckFinishesDoesNotConsumeThePrompt() async {
        let client = NotificationClientStub(); client.holdsAuthorization = true
        let checking = expectation(description: "Checking existing permission")
        client.didCheckAuthorization = { checking.fulfill() }
        let (store, _) = make(client)
        store.sessionCompleted()
        let pending = Task { await store.requestAfterSessionIfNeeded() }
        await fulfillment(of: [checking], timeout: 2)
        pending.cancel()
        client.authorizationResponse?.resume(); client.authorizationResponse = nil
        client.holdsAuthorization = false
        await pending.value
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertTrue(store.shouldAskAfterSession)
        XCTAssertFalse(store.isRequestingSessionPermission)
        await store.requestAfterSessionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testConcurrentHomeRequestsAndOptOutWhilePromptIsOpenDoNotReenablePractice() async {
        let client = NotificationClientStub(); client.holdsPermission = true
        let asked = expectation(description: "Permission opened")
        client.didRequest = { asked.fulfill() }
        let (store, _) = make(client)
        store.sessionCompleted()
        let pending = Task { await store.requestAfterSessionIfNeeded() }
        await fulfillment(of: [asked], timeout: 2)
        await store.requestAfterSessionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 1)
        await store.setPracticeEnabled(false)
        pending.cancel() // System dialogs can make Home inactive; still save the response.
        client.permissionResponse?.resume(); client.permissionResponse = nil
        await pending.value
        XCTAssertFalse(store.practiceEnabled)
        XCTAssertTrue(store.isAllowed)
        XCTAssertFalse(store.isRequestingSessionPermission)
        XCTAssertFalse(store.shouldAskAfterSession)
    }

    func testPermissionFailureDoesNotEnrollOrRepeatAutomaticPrompt() async {
        let client = NotificationClientStub(); client.failsPermission = true
        let (store, _) = make(client)
        store.sessionCompleted()
        await store.requestAfterSessionIfNeeded()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.practiceEnabled)
        await store.requestAfterSessionIfNeeded()
        XCTAssertEqual(client.permissionRequests, 1)
        // Settings remains an explicit retry route.
        client.failsPermission = false
        await store.setPracticeEnabled(true)
        XCTAssertEqual(client.permissionRequests, 2)
        XCTAssertTrue(store.practiceEnabled)
    }
}

@MainActor
private final class NotificationClientStub: PracticeNotificationClient {
    var status: UNAuthorizationStatus = .notDetermined
    var permissionRequests = 0
    var reminders: [UNNotificationRequest] = []
    var holdsPermission = false
    var permissionResponse: CheckedContinuation<Void, Never>?
    var didRequest: (() -> Void)?
    var failsScheduling = false
    var permissionResult: UNAuthorizationStatus = .authorized
    var failsPermission = false
    var holdsAuthorization = false
    var authorizationResponse: CheckedContinuation<Void, Never>?
    var didCheckAuthorization: (() -> Void)?
    func authorization() async -> UNAuthorizationStatus {
        if holdsAuthorization {
            await withCheckedContinuation { continuation in
                authorizationResponse = continuation; didCheckAuthorization?()
            }
        }
        return status
    }
    func requestPermission() async throws {
        permissionRequests += 1
        if failsPermission { throw NSError(domain: "Test permission", code: 1) }
        if holdsPermission {
            await withCheckedContinuation { continuation in
                permissionResponse = continuation; didRequest?()
            }
        }
        status = permissionResult
    }
    func setReminders(_ requests: [UNNotificationRequest]) async throws {
        if failsScheduling { throw NSError(domain: "Test scheduling", code: 1) }
        reminders = requests
    }
}
