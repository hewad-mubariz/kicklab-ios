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
        XCTAssertFalse(store.dailyEnabled); XCTAssertFalse(store.exportsEnabled)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertNil(client.reminder)
    }

    func testEnablingDailyRequestsPermissionAndReplacesOneLocalTimeReminder() async throws {
        let (store, client) = make()
        await store.setDailyEnabled(true)
        XCTAssertEqual(client.permissionRequests, 1)
        var request = try XCTUnwrap(client.reminder)
        XCTAssertEqual(request.identifier, PracticeNotifications.reminderIdentifier)
        var trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 18)
        XCTAssertNil(trigger.dateComponents.timeZone)
        await store.setTime(hour: 7, minute: 35)
        request = try XCTUnwrap(client.reminder)
        trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertEqual(request.identifier, PracticeNotifications.reminderIdentifier)
        XCTAssertEqual(trigger.dateComponents.hour, 7); XCTAssertEqual(trigger.dateComponents.minute, 35)
        XCTAssertEqual(client.permissionRequests, 1)
        await store.setDailyEnabled(false)
        XCTAssertNil(client.reminder)
        XCTAssertFalse(store.dailyEnabled)
    }

    func testExportOptInDoesNotEnableDailyAndChoicesSurviveRelaunch() async {
        let (store, client) = make()
        await store.setExportsEnabled(true)
        await store.setTime(hour: 21, minute: 15)
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertNil(client.reminder)
        let (reopened, _) = make(client)
        XCTAssertTrue(reopened.exportsEnabled); XCTAssertFalse(reopened.dailyEnabled)
        XCTAssertEqual(reopened.minuteOfDay, 21 * 60 + 15)
    }

    func testDeniedPermissionKeepsPreferenceButRemovesScheduledReminderAndDoesNotReprompt() async {
        let client = NotificationClientStub(); client.status = .authorized
        let (store, _) = make(client)
        await store.setDailyEnabled(true)
        XCTAssertNotNil(client.reminder)
        client.status = .denied
        await store.refresh()
        XCTAssertTrue(store.dailyEnabled); XCTAssertFalse(store.isAllowed)
        XCTAssertNil(client.reminder)
        await store.setExportsEnabled(true)
        XCTAssertEqual(client.permissionRequests, 0)
        client.status = .authorized
        await store.refresh()
        XCTAssertNotNil(client.reminder)
    }

    func testDisablingWhilePermissionDialogIsPendingWins() async {
        let client = NotificationClientStub()
        client.holdsPermission = true
        let asked = expectation(description: "Permission opened")
        client.didRequest = { asked.fulfill() }
        let (store, _) = make(client)
        let enabling = Task { await store.setDailyEnabled(true) }
        await fulfillment(of: [asked], timeout: 2)
        let disabling = Task { await store.setDailyEnabled(false) }
        // Let the disable update the desired preference before the OS responds.
        while store.dailyEnabled { await Task.yield() }
        client.permissionResponse?.resume(); client.permissionResponse = nil
        await enabling.value; await disabling.value
        XCTAssertFalse(store.dailyEnabled)
        XCTAssertNil(client.reminder)
        XCTAssertFalse(store.isUpdating)
    }

    func testScheduleFailureIsVisibleAndRetryDoesNotRequestPermissionAgain() async {
        let client = NotificationClientStub(); client.failsScheduling = true
        let (store, _) = make(client)
        await store.setDailyEnabled(true)
        XCTAssertNotNil(store.errorMessage)
        client.failsScheduling = false
        await store.refresh()
        XCTAssertNil(store.errorMessage); XCTAssertNotNil(client.reminder)
        XCTAssertEqual(client.permissionRequests, 1)
    }

    func testInvalidSavedTimeFallsBackAndInvalidEditDoesNotChangeIt() async {
        UserDefaults(suiteName: suite)!.set(1600, forKey: PracticeNotifications.timeKey)
        let (store, _) = make()
        XCTAssertEqual(store.minuteOfDay, 1080)
        await store.setTime(hour: 24, minute: 0)
        XCTAssertEqual(store.minuteOfDay, 1080)
    }
}

@MainActor
private final class NotificationClientStub: PracticeNotificationClient {
    var status: UNAuthorizationStatus = .notDetermined
    var permissionRequests = 0
    var reminder: UNNotificationRequest?
    var holdsPermission = false
    var permissionResponse: CheckedContinuation<Void, Never>?
    var didRequest: (() -> Void)?
    var failsScheduling = false
    func authorization() async -> UNAuthorizationStatus { status }
    func requestPermission() async throws {
        permissionRequests += 1
        if holdsPermission {
            await withCheckedContinuation { continuation in
                permissionResponse = continuation; didRequest?()
            }
        }
        status = .authorized
    }
    func setReminder(_ request: UNNotificationRequest?) async throws {
        if failsScheduling { throw NSError(domain: "Test scheduling", code: 1) }
        reminder = request
    }
}
