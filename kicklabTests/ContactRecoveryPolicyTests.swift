import Foundation
import XCTest
@testable import kicklab

final class ContactRecoveryPolicyTests: XCTestCase {
    func testBuiltAppContainsSelectiveCounterV2ModelAndRuntime() {
        XCTAssertNotNil(Bundle.main.url(forResource: "pose_landmarker_full", withExtension: "task"))
        XCTAssertNotNil(NSClassFromString("MPPPoseLandmarker"))
        XCTAssertNil(Bundle.main.url(forResource: "pose_landmarker_heavy", withExtension: "task"))
    }

    @MainActor
    func testRetiredPreferencesCannotChangeCounterV2() throws {
        try XCTSkipUnless(ContactRecoveryPolicy.available)
        let defaults = UserDefaults.standard
        let keys = ["juggledude.benchmark.shoe-recovery", "juggledude.preview.shoe-recovery"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
        let signature = SessionAnalysisStore.pipelineSignature()
        let flags = TouchCountingDebugProfile.arguments
        for key in keys { defaults.set(true, forKey: key) }
        XCTAssertEqual(SessionAnalysisStore.pipelineSignature(), signature)
        XCTAssertEqual(TouchCountingDebugProfile.arguments, flags)
        XCTAssertTrue(flags.contains("--visible-foot-recovery-v2"))
        XCTAssertTrue(ContactRecoveryPolicy.usesVisionRevision2)
        XCTAssertTrue(signature.contains("|shoe-recovery-off|visible-foot-v2|pose-r2-"))
        XCTAssertTrue(signature.contains(CounterV2Policy.signature))
        XCTAssertTrue(signature.contains("|mp-full-toes-locked-player-v2"))
        XCTAssertNotEqual(signature, signature.replacingOccurrences(of: CounterV2Policy.signature, with: ""),
            "Native-only saved decisions must not be reused as Counter V2 results")
        XCTAssertNotEqual(signature, signature.replacingOccurrences(of: "|shoe-recovery-off",
            with: "|shoe-recovery-v1|mp-full-4eaa5eb7"), "Saved model-on evidence must not match")
    }

    func testHistoricalModelProofsDecodeButCannotGrantCurrentTouches() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "shoe-contact-frozen-proofs", withExtension: "json"))
        let proofs = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        XCTAssertFalse(proofs.isEmpty)
        for proof in proofs {
            let time = try XCTUnwrap(proof["candidateMs"] as? Int)
            func sample(_ ms: Int) -> FootContactRules.Sample {
                .init(timestampMs: ms, ballX: 0.5, ballY: 0.5, width: 0.1, height: 0.1,
                      confidence: 0.9, ankles: [:])
            }
            let foot = FootContactEvidence(before: sample(time - 99), contact: sample(time), after: sample(time + 99))
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(foot)) as? [String: Any])
            json["shoeProof"] = proof
            let restored = try JSONDecoder().decode(FootContactEvidence.self,
                from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored, foot)
            XCTAssertFalse(restored.confirms, "Retired auxiliary evidence must not restore model-only acceptance")

            let ground = GroundContactEvidence(contactMs: time, samples: [])
            var groundJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ground)) as? [String: Any])
            groundJSON["shoeProof"] = proof
            XCTAssertEqual(try JSONDecoder().decode(GroundContactEvidence.self,
                from: JSONSerialization.data(withJSONObject: groundJSON)), ground)
        }
    }
}
