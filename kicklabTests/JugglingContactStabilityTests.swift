import Foundation
import Testing
@testable import kicklab

struct JugglingContactStabilityTests {
    @Test func firstFootSurvivesBriefBodyBoxCollapseAndAcquisitionDoesNotCount() throws {
        let url = try #require(Bundle(for: FixtureBundle.self)
            .url(forResource: "contact-counter-34dd", withExtension: "json"))
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let counter = StreamingCounter()
        for row in raw["rows"] as! [[String: Any]] {
            let frame = row["frame"] as! Int, ms = Int((row["time"] as! Double) * 1000)
            let ball = (row["ball"] as? [Double]).map {
                BallObservation(frameIndex: frame, timestampMs: ms, x: $0[1], y: $0[2],
                                width: $0[3], height: $0[4], confidence: $0[0])
            }
            let person = (row["person"] as? [Double]).map {
                PersonBox(x: $0[1], y: $0[2], width: $0[3], height: $0[4])
            }
            counter.push(frameIndex: frame, timestampMs: ms, ball: ball, person: person,
                cameraOffsetY: row["offset"] as? Double ?? 0, reliable: row["reliable"] as? Bool ?? true)
        }
        counter.flush()
        // Event identities matter: the old total was also two, at frames 70/284.
        #expect(counter.touches.map(\.frameIndex) == [247, 284])
    }

    private func reversal(sizeAfter: Double, observedApex: Bool = false,
                          ground: Double = 0.9, collapsed: Bool = false) -> TouchStateMachine {
        let machine = TouchStateMachine(config: CounterConfig())
        for i in 0...8 {
            let bottom = collapsed && (2...4).contains(i) ? 0.6 : ground
            machine.personBoxes[i] = PersonBox(x: 0.5, y: bottom / 2, width: 0.8, height: bottom)
        }
        machine.detectedFrames = [0, 1, 2, 6, 7, 8]
        machine.ballHeights = [0: 0.04, 1: 0.04, 2: 0.04, 6: sizeAfter, 7: sizeAfter, 8: sizeAfter]
        if observedApex { machine.detectedFrames.insert(3); machine.ballHeights[3] = 0.04 }
        for (i, y) in [0.4, 0.45, 0.55, 0.6, 0.58, 0.55].enumerated() {
            _ = machine.push(TrajectoryPoint(frameIndex: i, timestampMs: i * 33,
                x: 0.5, y: y, vy: i < 4 ? 0.5 : -0.5, confidence: 0.9,
                valid: true, motion: i < 4 ? .falling : .rising))
        }
        return machine
    }

    @Test func consistentShortOcclusionStillCounts() {
        #expect(reversal(sizeAfter: 0.045).count == 1)
    }

    @Test func unseenReversalBetweenInconsistentSizesIsUnsupported() {
        let machine = reversal(sizeAfter: 0.1)
        #expect(machine.count == 0)
        #expect(machine.rejected.last?.reason == .unsupportedByDetection)
    }

    @Test func observedReversalIsNotRemovedByNearbySizeChange() {
        #expect(reversal(sizeAfter: 0.1, observedApex: true).count == 1)
    }

    @Test func transientBodyTruncationDoesNotReplaceTheFloor() {
        #expect(reversal(sizeAfter: 0.04, collapsed: true).count == 1)
    }

    @Test func persistentGroundContactStillRejected() {
        let machine = reversal(sizeAfter: 0.04, ground: 0.62)
        #expect(machine.count == 0)
        #expect(machine.rejected.last?.reason == .groundBounce)
    }

    private final class FixtureBundle {}
}
