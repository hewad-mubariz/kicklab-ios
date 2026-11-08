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
    func testDefaultOffDoesNotEnrollOrRequestPermission() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        await store.refresh()
        XCTAssertFalse(store.enabled); XCTAssertNil(vault.value)
        XCTAssertEqual(platform.prompts, 0); XCTAssertEqual(platform.registrations, 0); XCTAssertTrue(client.requests.isEmpty)
    }
    func testGuestWaitsForAppleTokenThenRegistersAndOptOutClearsToken() async throws {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        await store.setEnabled(true)
        XCTAssertEqual(platform.prompts, 1); XCTAssertEqual(platform.registrations, 1); XCTAssertTrue(client.requests.isEmpty)
        store.receivedToken(Data(repeating: 0xab, count: 32))
        await store.refresh()
        let first = try XCTUnwrap(client.requests.last)
        XCTAssertTrue(first.trainingEnabled); XCTAssertEqual(first.token, String(repeating: "ab", count: 32))
        XCTAssertNil(client.tokens.last!); XCTAssertTrue(store.synchronized)
        await store.setEnabled(false)
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
        store.receivedToken(Data(repeating: 1, count: 32)); await store.setEnabled(true)
        platform.status = .denied; await store.refresh()
        XCTAssertTrue(store.enabled); XCTAssertFalse(client.requests.last!.trainingEnabled)
        XCTAssertNil(client.requests.last!.token); XCTAssertEqual(platform.prompts, 1)
    }
    func testOfflineOptOutIsSavedAndRetriedWithNewerRevision() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await store.setEnabled(true)
        client.fails = true; await store.setEnabled(false)
        XCTAssertFalse(store.enabled); XCTAssertFalse(store.synchronized); XCTAssertNotNil(store.errorMessage)
        let failedRevision = vault.value!.revision
        client.fails = false; await store.refresh()
        XCTAssertTrue(store.synchronized); XCTAssertNil(store.errorMessage)
        XCTAssertGreaterThan(client.requests.last!.revision, failedRevision)
        XCTAssertFalse(client.requests.last!.trainingEnabled)
    }
    func testDisablingDuringPermissionPromptWinsAndDoesNotEnroll() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        platform.holdPermission = true
        let store = make(vault, client, platform)
        let enabling = Task { await store.setEnabled(true) }
        while platform.continuation == nil { await Task.yield() }
        let disabling = Task { await store.setEnabled(false) }
        while store.enabled { await Task.yield() }
        platform.continuation?.resume(); platform.continuation = nil
        await enabling.value; await disabling.value
        XCTAssertFalse(store.enabled); XCTAssertNil(vault.value); XCTAssertTrue(client.requests.isEmpty)
    }
    func testAccountDeletionDisablesAndDailyPreferenceIsSent() async {
        let vault = PushVaultStub(), client = PushClientStub(), platform = PushPlatformStub()
        UserDefaults(suiteName: suite)!.set(true, forKey: PracticeNotifications.dailyKey)
        let store = make(vault, client, platform)
        store.receivedToken(Data(repeating: 1, count: 32)); await store.setEnabled(true)
        XCTAssertTrue(client.requests.last!.dailyReminderEnabled)
        await store.accountWasDeleted()
        XCTAssertFalse(store.enabled); XCTAssertFalse(client.requests.last!.trainingEnabled)
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
    var status: UNAuthorizationStatus = .notDetermined
    var prompts = 0; var registrations = 0; var holdPermission = false
    var continuation: CheckedContinuation<Void, Never>?
    func authorization() async -> UNAuthorizationStatus { status }
    func requestPermission() async throws {
        prompts += 1
        if holdPermission { await withCheckedContinuation { continuation = $0 } }
        status = .authorized
    }
    func register() { registrations += 1 }
}
