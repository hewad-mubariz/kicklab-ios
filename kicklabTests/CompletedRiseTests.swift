import Foundation
import Testing
@testable import kicklab

struct CompletedRiseTests {
    private final class BundleToken {}
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let contact_frame: Int
            let inputs: [CounterTrace.Input]
        }
        let cases: [Case]
    }

    @Test func recordedLowContactsReachValidationWithoutLoweringMovementThresholds() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(
            forResource: "completed-rise-inputs", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        #expect(fixture.cases.count == 3)
        for item in fixture.cases {
            for enabled in [false, true] {
                var config = CounterConfig()
                config.completesRiseWhileSlowing = enabled
                var checked: [Int] = []
                // Candidate generation cannot decide that a new contact is legal.
                let counter = StreamingCounter(config: config, recordTrace: true,
                    allowsBodyContact: { checked.append($0); return false })
                for i in item.inputs {
                    counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs,
                        ball: i.ball, person: i.person, cameraOffsetY: i.cameraOffsetY,
                        reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex)
                }
                counter.flush()
                #expect(checked.contains(item.contact_frame) == enabled)
                #expect(counter.count == 0)
                let trace = try #require(counter.traceSnapshot())
                let restored = try PropertyListDecoder().decode(CounterTrace.self,
                    from: PropertyListEncoder().encode(trace))
                #expect(try restored.replay() == counter.touches)
            }
        }
    }

    @Test func oldConfigurationsKeepTheirOriginalConfirmationRule() throws {
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(CounterConfig())) as? [String: Any])
        json.removeValue(forKey: "completesRiseWhileSlowing")
        let config = try JSONDecoder().decode(CounterConfig.self,
            from: JSONSerialization.data(withJSONObject: json))
        #expect(config.completesRiseWhileSlowing == nil)
        let counter = machine(config: config)
        feed(counter)
        #expect(counter.count == 0)
    }

    private func machine(config: CounterConfig = CounterConfig(), floor: Bool = false) -> TouchStateMachine {
        let machine = TouchStateMachine(config: config)
        for i in 0...12 {
            machine.personBoxes[i] = .init(x: 0.5, y: floor ? 0.225 : 0.45,
                width: 0.8, height: floor ? 0.45 : 0.9)
            machine.detectedFrames.insert(i)
        }
        return machine
    }

    private func feed(_ machine: TouchStateMachine, secondRise: Bool = true,
                      finalY: Double = 0.422, finalVelocity: Double = -0.03,
                      discard: Bool = false) {
        let points: [(Double, Double, MotionState)] = [
            (0.4, 0.2, .falling), (0.42, 0.3, .falling), (0.43, 0, .unknown),
            (0.427, -0.1, .rising),
            (0.425, secondRise ? -0.08 : -0.03, secondRise ? .rising : .unknown),
            (finalY, finalVelocity, .unknown), (finalY, finalVelocity, .unknown)
        ]
        for (i, p) in points.enumerated() {
            if discard && i == 5 { machine.discardPendingArc() }
            _ = machine.push(.init(frameIndex: i, timestampMs: i*33, x: 0.5, y: p.0,
                vy: p.1, confidence: 0.9, valid: true, motion: p.2))
        }
    }

    @Test func slowingAfterAnEstablishedRiseConfirmsOnceAtTheOriginalContact() {
        let counter = machine()
        feed(counter)
        #expect(counter.count == 1)
        #expect(counter.touches.first?.frameIndex == 2)
        #expect(counter.touches.first?.timestampMs == 66)
    }

    @Test func neutralMotionCannotReplaceRisingEvidenceDisplacementOrContinuity() {
        let oneRise = machine(); feed(oneRise, secondRise: false)
        let shortRise = machine(); feed(shortRise, finalY: 0.424)
        let downward = machine(); feed(downward, finalVelocity: 0.03)
        let interrupted = machine(); feed(interrupted, discard: true)
        #expect(oneRise.count == 0)
        #expect(shortRise.count == 0)
        #expect(downward.count == 0)
        #expect(interrupted.count == 0)
    }

    @Test func completedRiseStillRunsBodyHandAndGroundRejections() {
        let body = machine(); body.allowsBodyContact = { _ in false }; feed(body)
        let hand = machine(); hand.allowsBodyContact = { _ in true }
        hand.rejectsHandContact = { _ in true }; feed(hand)
        let floor = machine(floor: true); feed(floor)
        #expect(body.rejected.last?.reason == .disallowedBodyContact)
        #expect(hand.rejected.last?.reason == .handContact)
        #expect(floor.rejected.last?.reason == .groundBounce)
        #expect(body.count == 0 && hand.count == 0 && floor.count == 0)
    }
}
