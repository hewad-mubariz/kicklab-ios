import AVFoundation
import UIKit
import XCTest
@testable import kicklab

final class ShoeContactRecoveryTests: XCTestCase {
    private func fixtures() throws -> [ShoeContactProof] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shoe-contact-frozen-proofs", withExtension: "json"))
        return try JSONDecoder().decode([ShoeContactProof].self, from: Data(contentsOf: url))
    }
    private func player(people: Int = 1, observed: Bool = true, box: PersonBox = .init(x: 0.5, y: 0.5, width: 1, height: 1)) -> ActivePlayerSelection {
        .init(state: .locked, id: 1, box: box, observed: observed, peopleCount: people)
    }
    func testFrozenRecoveredContactsReproduceFromNumericEvidence() throws {
        for proof in try fixtures() {
            XCTAssertTrue(proof.valid)
            let result = ShoeContactRules.proof(proof.samples, at: proof.candidateMs, through: proof.availableMs, player: player())
            XCTAssertEqual(result, proof)
            let roundTrip = try JSONDecoder().decode(ShoeContactProof.self, from: JSONEncoder().encode(proof))
            XCTAssertEqual(roundTrip, proof)
        }
    }
    func testFutureEvidenceCannotRecoverACurrentContact() throws {
        for proof in try fixtures() {
            XCTAssertNil(ShoeContactRules.proof(proof.samples, at: proof.candidateMs, through: proof.availableMs-1, player: player()))
        }
    }
    func testUnknownOtherAndMultiplePlayersAbstain() throws {
        let p = try XCTUnwrap(fixtures().first)
        for selected in [nil, player(people: 2), player(observed: false), player(box: .init(x: 0, y: 0, width: 0.01, height: 0.01))] {
            XCTAssertNil(ShoeContactRules.proof(p.samples, at: p.candidateMs, through: p.availableMs, player: selected))
        }
    }
    func testIncompleteOrDuplicateObservationsCannotBecomeProof() throws {
        let p = try XCTUnwrap(fixtures().first)
        XCTAssertNil(ShoeContactRules.proof(Array(p.samples.dropLast()), at: p.candidateMs, through: p.availableMs, player: player()))
        XCTAssertNil(ShoeContactRules.proof(p.samples+[p.samples[0]], at: p.candidateMs, through: p.availableMs, player: player()))
        let invalid = ShoeContactProof(candidateMs: p.candidateMs, side: p.side,
            samples: p.samples.map { .init(ms: $0.ms, pose: [], ball: $0.ball) })
        XCTAssertFalse(invalid.valid)
    }
    @MainActor
    func testCounterCacheSeparatesExperimentFromCurrentRules() throws {
        try XCTSkipUnless(ShoeRecoveryPolicy.available)
        let defaults = UserDefaults.standard, old = defaults.object(forKey: ShoeRecoveryPolicy.preferenceKey)
        defer { defaults.set(old, forKey: ShoeRecoveryPolicy.preferenceKey) }
        defaults.set(false, forKey: ShoeRecoveryPolicy.preferenceKey)
        let original = SessionAnalysisStore.pipelineSignature()
        defaults.set(true, forKey: ShoeRecoveryPolicy.preferenceKey)
        XCTAssertNotEqual(original, SessionAnalysisStore.pipelineSignature())
        defaults.set(false, forKey: ShoeRecoveryPolicy.preferenceKey)
        XCTAssertEqual(original, SessionAnalysisStore.pipelineSignature())
    }
}

final class ShoeRecoveryPhoneTests: XCTestCase {
    /// Runs real imported-video work using the ordinary RF model, masks and contact gates.
    /// The fixture is the existing 18-touch clip; no network, export or rank submission.
    @MainActor
    func testRealVideoWithAndWithoutShoeRecovery() async throws {
        try XCTSkipUnless(ShoeRecoveryPolicy.available)
        #if targetEnvironment(simulator)
        throw XCTSkip("The real-model performance sample runs on physical phones")
        #endif
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let defaults = UserDefaults.standard, old = defaults.object(forKey: ShoeRecoveryPolicy.preferenceKey)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { defaults.set(old, forKey: ShoeRecoveryPolicy.preferenceKey); UIApplication.shared.isIdleTimerDisabled = idle }
        var rows: [[String: Any]] = []
        for enabled in [false, true] {
            defaults.set(enabled, forKey: ShoeRecoveryPolicy.preferenceKey)
            // Each arm uses the real analyzer but bypasses persistent analysis reuse.
            let analyzer = VideoAnalyzer()
            let start = ProcessInfo.processInfo.systemUptime
            await VideoWorkExecution.$accuracyComparison.withValue(true) {
                analyzer.analyse(url: source)
                await analyzer.waitUntilFinished()
            }
            XCTAssertEqual(analyzer.status, "done")
            XCTAssertGreaterThan(analyzer.framesRead, 30)
            XCTAssertGreaterThan(analyzer.touchCount, 0)
            let metrics = analyzer.profileMetrics
            if enabled {
                XCTAssertGreaterThan(metrics["shoe_calls"] ?? 0, 30)
                XCTAssertEqual(metrics["shoe_errors"], 0)
            }
            let row: [String: Any] = ["shoe_enabled": enabled, "seconds": ProcessInfo.processInfo.systemUptime-start,
                "touches": analyzer.touchCount, "frames": analyzer.framesRead,
                "touch_times": analyzer.recordedTouches.map(\.time), "metrics": metrics,
                "thermal_after": ProcessInfo.processInfo.thermalState.rawValue]
            rows.append(row)
            print("SHOEPHONE " + String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
        }
        let out = URL.documentsDirectory.appending(path: "shoe-recovery-73.json")
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted]).write(to: out)
    }
}

extension ShoeRecoveryPhoneTests {
    @MainActor
    func testNormalForegroundImportWithShoeRecovery() async throws {
        try XCTSkipUnless(ShoeRecoveryPolicy.available)
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-phone check")
        #endif
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let defaults = UserDefaults.standard, old = defaults.object(forKey: ShoeRecoveryPolicy.preferenceKey)
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defaults.set(true, forKey: ShoeRecoveryPolicy.preferenceKey)
        defer { defaults.set(old, forKey: ShoeRecoveryPolicy.preferenceKey); UIApplication.shared.isIdleTimerDisabled = idle }
        let analyzer = VideoAnalyzer(), start = ProcessInfo.processInfo.systemUptime
        analyzer.analyse(url: source)
        await analyzer.waitUntilFinished()
        XCTAssertEqual(analyzer.status, "done")
        XCTAssertGreaterThan(analyzer.touchCount, 0)
        XCTAssertGreaterThan(analyzer.profileMetrics["shoe_calls"] ?? 0, 30)
        XCTAssertEqual(analyzer.profileMetrics["shoe_errors"], 0)
        let row: [String: Any] = ["mode": "normal_foreground", "seconds": ProcessInfo.processInfo.systemUptime-start,
            "frames": analyzer.framesRead, "touches": analyzer.touchCount, "metrics": analyzer.profileMetrics,
            "thermal_after": ProcessInfo.processInfo.thermalState.rawValue]
        print("SHOEFOREGROUND " + String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
        try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .prettyPrinted])
            .write(to: URL.documentsDirectory.appending(path: "shoe-recovery-73-foreground.json"))
    }
}
