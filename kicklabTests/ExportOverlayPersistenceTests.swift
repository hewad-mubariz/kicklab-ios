import Foundation
import XCTest
@testable import kicklab

@MainActor
final class ExportOverlayPersistenceTests: XCTestCase {
    private let key = "kicklab.export.overlays.v1"

    func testRepeatedLoadsDoNotWriteOrChangeLegacyLayout() throws {
        let defaults = try XCTUnwrap(WriteCountingDefaults(suiteName: UUID().uuidString))
        let old = Data(#"{"counter":{"enabled":false,"style":"classic","placement":{"x":0.3,"y":0.6,"scale":1.2,"rotation":10}},"timer":{"enabled":true}}"#.utf8)
        defaults.set(old, forKey: key)
        defer { defaults.removeObject(forKey: key) }
        defaults.writes = 0
        for _ in 0..<100 {
            let restored = ExportOverlaySettings.load(defaults: defaults)
            XCTAssertFalse(restored.counter.enabled)
            XCTAssertFalse(restored.graph.enabled)
            XCTAssertEqual(restored.graph.style, .ballMotion)
            XCTAssertEqual(restored.counter.style, .classic)
            XCTAssertEqual(restored.counter.placement, .init(x: 0.3, y: 0.6, scale: 1.2, rotation: 10))
        }
        XCTAssertEqual(defaults.writes, 0, "A view reading its settings must not invalidate its AppStorage presenter")
        XCTAssertEqual(defaults.data(forKey: key), old)
    }

    func testExplicitEditsPersistOnceAndRemoveRetiredKeys() throws {
        let defaults = try XCTUnwrap(WriteCountingDefaults(suiteName: UUID().uuidString))
        defaults.set(Data(#"{"counter":{"enabled":true,"style":"classic","placement":{"x":0.3,"y":0.6,"scale":1.2}},"timer":{"enabled":true}}"#.utf8), forKey: key)
        defer { defaults.removeObject(forKey: key) }
        var settings = ExportOverlaySettings.load(defaults: defaults)
        settings.counter.style = .goldCoin
        defaults.writes = 0
        settings.save(defaults: defaults)
        settings.save(defaults: defaults)
        XCTAssertEqual(defaults.writes, 1)
        XCTAssertEqual(ExportOverlaySettings.load(defaults: defaults), settings)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
        XCTAssertNil(json["timer"])
    }

    func testLegacyCounterPreferenceLoadsWithoutCreatingNewSettings() throws {
        let defaults = try XCTUnwrap(WriteCountingDefaults(suiteName: UUID().uuidString))
        defaults.set(false, forKey: "kicklab.export.includeCounter")
        defer { defaults.removeObject(forKey: "kicklab.export.includeCounter") }
        defaults.writes = 0
        XCTAssertFalse(ExportOverlaySettings.load(defaults: defaults).counter.enabled)
        XCTAssertEqual(defaults.writes, 0)
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testGraphPreferencesRoundTripAndInvalidateSavedReplay() throws {
        var settings = ExportOverlaySettings()
        settings.counter.enabled = false
        XCTAssertFalse(settings.hasVisibleOverlays)
        let original = settings
        settings.graph.enabled = true
        settings.graph.style = .comet
        XCTAssertTrue(settings.hasVisibleOverlays)
        XCTAssertNotEqual(settings, original)
        XCTAssertEqual(try JSONDecoder().decode(ExportOverlaySettings.self,
            from: JSONEncoder().encode(settings)), settings)
        let oldStyle = Data(#"{"graph":{"enabled":true,"style":"retired"}}"#.utf8)
        let restored = try JSONDecoder().decode(ExportOverlaySettings.self, from: oldStyle)
        XCTAssertTrue(restored.graph.enabled)
        XCTAssertEqual(restored.graph.style, .ballMotion)
    }
}

private final class WriteCountingDefaults: UserDefaults, @unchecked Sendable {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}
