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

    func testEnablingPracticeSchedulesOnlyMondayWednesdaySundayAndTimeChangesReplaceThem() async throws {
        let (store, client) = make()
        await store.setPracticeEnabled(true)
        XCTAssertEqual(client.permissionRequests, 1)
        XCTAssertEqual(client.reminders.count, 3)
        let identifiers = client.reminders.map(\.identifier)
        XCTAssertEqual(Set(identifiers).count, 3)
        var weekdays = Set<Int>()
        for request in client.reminders {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertTrue(trigger.repeats)
            weekdays.insert(try XCTUnwrap(trigger.dateComponents.weekday))
            XCTAssertEqual(trigger.dateComponents.hour, 18)
            XCTAssertEqual(trigger.dateComponents.minute, 0)
            XCTAssertNil(trigger.dateComponents.timeZone)
            XCTAssertNil(trigger.dateComponents.day)
            XCTAssertNil(trigger.dateComponents.month)
            let next = try XCTUnwrap(trigger.nextTriggerDate())
            XCTAssertEqual(Calendar.current.component(.weekday, from: next), trigger.dateComponents.weekday)
        }
        XCTAssertEqual(weekdays, [1, 2, 4])
        await store.setTime(hour: 7, minute: 35)
        XCTAssertEqual(client.reminders.map(\.identifier), identifiers)
        for request in client.reminders {
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertEqual(trigger.dateComponents.hour, 7)
            XCTAssertEqual(trigger.dateComponents.minute, 35)
        }
        await store.refresh()
        XCTAssertEqual(client.reminders.count, 3)
        XCTAssertEqual(client.permissionRequests, 1)
        await store.setPracticeEnabled(false)
        XCTAssertTrue(client.reminders.isEmpty)
        XCTAssertFalse(store.practiceEnabled)
    }

    func testExistingDailyOptInMigratesToThreeWeeklyRemindersAtSavedTime() async throws {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: "juggledude.notifications.daily")
        defaults.set(7 * 60 + 35, forKey: PracticeNotifications.timeKey)
        let client = NotificationClientStub(); client.status = .authorized
        let (store, _) = make(client)
        await store.refresh()
        XCTAssertTrue(store.practiceEnabled)
        XCTAssertEqual(client.permissionRequests, 0)
        XCTAssertEqual(client.reminders.count, 3)
        for request in client.reminders {
            XCTAssertNotEqual(request.identifier, "juggledude.daily-practice")
            let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
            XCTAssertNotNil(trigger.dateComponents.weekday)
            XCTAssertEqual(trigger.dateComponents.hour, 7)
            XCTAssertEqual(trigger.dateComponents.minute, 35)
        }
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
        XCTAssertEqual(client.reminders.count, 3)
        client.status = .denied
        await store.refresh()
        XCTAssertTrue(store.practiceEnabled); XCTAssertFalse(store.isAllowed)
        XCTAssertTrue(client.reminders.isEmpty)
        await store.setExportsEnabled(true)
        XCTAssertEqual(client.permissionRequests, 0)
        client.status = .authorized
        await store.refresh()
        XCTAssertEqual(client.reminders.count, 3)
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
        XCTAssertNil(store.errorMessage); XCTAssertEqual(client.reminders.count, 3)
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
    var reminders: [UNNotificationRequest] = []
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
    func setReminders(_ requests: [UNNotificationRequest]) async throws {
        if failsScheduling { throw NSError(domain: "Test scheduling", code: 1) }
        reminders = requests
    }
}
