import Foundation
import Security
import Testing
@testable import kicklab

/// A reinstall must not come back signed in: Keychain survives app deletion, UserDefaults does not.
@MainActor
struct FreshInstallSessionTests {
    private let service = "juggledude.tests.fresh-install"

    private func defaults() -> UserDefaults {
        let name = "FreshInstallSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func storeSession() {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: "session"]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data("token".utf8)
        #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    }

    private var sessionExists: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "session"]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @Test func freshInstallClearsLeftoverSession() {
        let defaults = defaults()
        storeSession()
        FreshInstallSession.clearIfNeeded(keychainService: service, defaults: defaults)
        #expect(!sessionExists)
        #expect(defaults.bool(forKey: FreshInstallSession.markerKey))
    }

    @Test func relaunchKeepsSession() {
        let defaults = defaults()
        defaults.set(true, forKey: FreshInstallSession.markerKey)
        storeSession()
        FreshInstallSession.clearIfNeeded(keychainService: service, defaults: defaults)
        #expect(sessionExists)
    }

    @Test func updateFromBuildWithoutMarkerKeepsSession() {
        let defaults = defaults()
        defaults.set(true, forKey: FreshInstallSession.welcomeKey)
        storeSession()
        FreshInstallSession.clearIfNeeded(keychainService: service, defaults: defaults)
        #expect(sessionExists)
        #expect(defaults.bool(forKey: FreshInstallSession.markerKey))
    }
}
