import XCTest
import UserNotifications
@testable import kicklab

@MainActor
final class RemotePracticeNotificationsTests: XCTestCase {
    private var suite = ""
    override func setUp() { super.setUp(); suite = "RemotePushTests." + UUID().uuidString }
    override func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suite); super.tearDown() }
    private func make(_ vault: PushVaultStub, _ client: PushClientStub, _ platform: PushPlatformStub) -> RemotePracticeNotifications {
        RemotePracticeNotifications(defaults: UserDefaults(suiteName: suite)!, vault: vault, client: client, platform: platform)
    }
    private func setPractice(_ enabled: Bool, on store: RemotePracticeNotifications) async {
        UserDefaults(suiteName: suite)!.set(enabled, forKey: PracticeNotifications.enabledKey)
        await store.refresh()
    }
    func testDefaultOffDoesNotEnrollOrRequestPermission() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        await store.refresh()
        XCTAssertFalse(store.enabled); XCTAssertNil(vault.value)
        XCTAssertEqual(platform.registrations, 0); XCTAssertTrue(client.requests.isEmpty)
    }
    func testGuestWaitsForAppleTokenThenRegistersAndOptOutClearsToken() async throws {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        await setPractice(true, on: store)
        XCTAssertEqual(platform.registrations, 1); XCTAssertTrue(client.requests.isEmpty)
        store.receivedToken(Data(repeating: 0xab, count: 32))
        await store.refresh()
        let first = try XCTUnwrap(client.requests.last)
        XCTAssertTrue(first.trainingEnabled); XCTAssertEqual(first.token, String(repeating: "ab", count: 32))
        XCTAssertNil(client.tokens.last!); XCTAssertTrue(store.synchronized)
        await setPractice(false, on: store)
        let disabled = try XCTUnwrap(client.requests.last)
        XCTAssertNil(disabled.token); XCTAssertFalse(disabled.trainingEnabled)
        XCTAssertGreaterThan(disabled.revision, first.revision)
        XCTAssertEqual(disabled.installationId, first.installationId)
        let reopened = make(vault, client, platform)
        XCTAssertFalse(reopened.enabled)
        await reopened.refresh()
        XCTAssertGreaterThan(client.requests.last!.revision, disabled.revision)
    }
    func testExternalPermissionRevocationRemovesServerTokenWithoutReprompt() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await setPractice(true, on: store)
        platform.status = .denied; await store.refresh()
        XCTAssertTrue(store.enabled); XCTAssertFalse(client.requests.last!.trainingEnabled)
        XCTAssertNil(client.requests.last!.token)
    }
    func testOfflineOptOutIsSavedAndRetriedWithNewerRevision() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await setPractice(true, on: store)
        client.fails = true; await setPractice(false, on: store)
        XCTAssertFalse(store.enabled); XCTAssertFalse(store.synchronized); XCTAssertNotNil(store.errorMessage)
        let failedRevision = vault.value!.revision
        client.fails = false; await store.refresh()
        XCTAssertTrue(store.synchronized); XCTAssertNil(store.errorMessage)
        XCTAssertGreaterThan(client.requests.last!.revision, failedRevision)
        XCTAssertFalse(client.requests.last!.trainingEnabled)
    }
    func testLegacyTrainingToggleCannotOptInToTheUnifiedPracticeSchedule() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        UserDefaults(suiteName: suite)!.set(true, forKey: "juggledude.notifications.remote-training")
        let store = make(vault, client, platform)
        await store.refresh()
        XCTAssertFalse(store.enabled)
        XCTAssertTrue(client.requests.isEmpty)
    }
    func testScheduleSyncContainsSelectedTimeZoneAndServerModeAndAccountDeletionDisablesIt() async throws {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        UserDefaults(suiteName: suite)!.set(7 * 60 + 35, forKey: PracticeNotifications.timeKey)
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await setPractice(true, on: store)
        let registration = try XCTUnwrap(client.requests.last)
        XCTAssertFalse(registration.dailyReminderEnabled)
        XCTAssertEqual(registration.reminderMinute, 455)
        XCTAssertEqual(registration.timeZone, TimeZone.autoupdatingCurrent.identifier)
        XCTAssertEqual(registration.deliveryMode, "server")
        XCTAssertGreaterThan(platform.clears, 0)
        UserDefaults(suiteName: suite)!.set(20 * 60, forKey: PracticeNotifications.timeKey)
        await store.refresh()
        XCTAssertEqual(client.requests.last?.reminderMinute, 1200)
        await store.accountWasDeleted()
        XCTAssertFalse(store.enabled); XCTAssertFalse(client.requests.last!.trainingEnabled)
        XCTAssertFalse(UserDefaults(suiteName: suite)!.bool(forKey: PracticeNotifications.enabledKey))
    }
    func testCannotEnrollWhileOldLocalRemindersCouldStillBeActive() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        platform.cannotClear = true
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await setPractice(true, on: store)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertNotNil(store.errorMessage)
        platform.cannotClear = false
        await store.refresh()
        XCTAssertTrue(store.synchronized)
    }
    func testOptOutBeforeAppleTokenArrivesDoesNotReenablePractice() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        await setPractice(true, on: store)
        await setPractice(false, on: store)
        store.receivedToken(Data(repeating: 1, count: 32))
        await store.refresh()
        XCTAssertFalse(store.enabled)
        XCTAssertTrue(client.requests.isEmpty)
    }

}

@MainActor private final class PushVaultStub: PushInstallationVault {
    var value: PushInstallationCredential?
    func load() throws -> PushInstallationCredential? { value }
    func save(_ value: PushInstallationCredential) throws { self.value = value }
}
@MainActor private final class PushClientStub: PushRegistrationClient {
    var requests: [PushRegistration] = []; var tokens: [String?] = []; var fails = false
    func synchronize(_ registration: PushRegistration, accessToken: String?) async throws {
        requests.append(registration); tokens.append(accessToken)
        if fails { throw PushRegistrationError.unavailable }
    }
}
@MainActor private final class PushPlatformStub: RemotePushPlatform {
    var status: UNAuthorizationStatus = .authorized
    var registrations = 0
    var clears = 0
    var cannotClear = false
    func authorization() async -> UNAuthorizationStatus { status }
    func clearLocalReminders() async throws {
        clears += 1
        if cannotClear { throw PushRegistrationError.unavailable }
    }
    func register() { registrations += 1 }
}
