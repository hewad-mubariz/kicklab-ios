import Foundation
import Testing
@testable import kicklab

struct TimedTrajectoryTests {
    private final class BundleToken {}
    private struct Fixture: Decodable {
        struct Case: Decodable { let id: String; let inputs: [CounterTrace.Input] }
        let cases: [Case]
    }
    private func fixture() throws -> Fixture {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "cadence-fast-inputs", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
    private func replay(_ inputs: [CounterTrace.Input], enabled: Bool, hand: Bool = false,
                        body: Bool = false, floor: Bool = false) -> CounterTrace {
        var config = CounterConfig(); config.timeAwareTrajectory = enabled
        let counter = StreamingCounter(config: config, rejectsHandContact: { _ in hand }, recordTrace: true,
            allowsBodyContact: { _ in body }, groundPolicy: floor ? .legacyCenter : .corroboratedFeet)
        for i in inputs {
            counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs, ball: i.ball,
                person: floor ? .init(x: 0.5, y: 0.225, width: 1, height: 0.45) : i.person,
                cameraOffsetY: floor ? 0 : i.cameraOffsetY, reliable: i.reliable, sourceFrameIndex: i.sourceFrameIndex)
        }
        counter.flush()
        return counter.traceSnapshot()!
    }
    private func candidates(_ trace: CounterTrace) -> [CounterDecision] {
        trace.decisions.map(\.value).filter {
            (1000...19000).contains($0.timestampMs) && $0.rejection == .disallowedBodyContact
        }
    }

    @Test func realFastArcsReachContactValidationAtSparseCadences() throws {
        for item in try fixture().cases {
            let old = replay(item.inputs, enabled: false)
            let updated = replay(item.inputs, enabled: true)
            #expect(updated.touches.isEmpty, "A recovered trajectory cannot bypass body validation")
            #expect(candidates(updated).count >= 54, "\(item.id): must recover the recorded rapid rebounds")
            if item.id.contains("normal") {
                #expect(old.decisions == updated.decisions, "Keep the established 30 FPS decisions exactly")
            } else {
                #expect(candidates(updated).count > candidates(old).count + 20)
            }
            #expect(try updated.replay().isEmpty)
        }
    }

    @Test func recoveredCandidatesStillRespectHandAndGroundVetoes() throws {
        for item in try fixture().cases where item.id.contains("fps15") {
            let hand = replay(item.inputs, enabled: true, hand: true, body: true)
            #expect(hand.touches.isEmpty)
            #expect(hand.decisions.contains { $0.value.rejection == .handContact })
            #expect(try hand.replay().isEmpty)
            let ground = replay(item.inputs, enabled: true, body: true, floor: true)
            #expect(ground.touches.isEmpty)
            #expect(ground.decisions.contains { $0.value.rejection == .groundBounce })
            #expect(try ground.replay().isEmpty)
        }
    }

    @Test func historicalConfigurationsKeepTheirOriginalTrajectory() throws {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(CounterConfig())) as? [String: Any])
        json.removeValue(forKey: "timeAwareTrajectory")
        let decoded = try JSONDecoder().decode(CounterConfig.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.timeAwareTrajectory == nil)
        #expect(CounterConfig().timeAwareTrajectory == true)
    }

    @Test func interpolatedFramesCannotSupplyDirectionDuration() throws {
        let times = [0: 0, 1: 67, 2: 133, 3: 200, 4: 267]
        let ys = [0.4, 0.45, 0.50, 0.55, 0.60]
        let filled = Dictionary(uniqueKeysWithValues: (0...4).map { i in
            (i, BallObservation(frameIndex: i, timestampMs: times[i]!, x: 0.5, y: ys[i],
                                width: 0.05, height: 0.03, confidence: 0.95))
        })
        let missingPrevious = filled.filter { $0.key != 1 }
        let point = try #require(TimedTrajectory.point(at: 2, in: Array(0...4), stamps: times,
            filled: filled, observed: missingPrevious, config: CounterConfig()))
        #expect(point.motion == .falling)
        #expect(point.motionEvidenceMs == 0)
        let real = try #require(TimedTrajectory.point(at: 2, in: Array(0...4), stamps: times,
            filled: filled, observed: filled, config: CounterConfig()))
        #expect(real.motionEvidenceMs == 66)
    }

    @Test func cadenceIgnoresOneDroppedFrameButRecognizesAlternatingIntervals() {
        func usesSparsePath(_ times: [Int], frame: Int) -> Bool {
            let stamps = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($0.offset, $0.element) })
            let balls = Dictionary(uniqueKeysWithValues: times.enumerated().map { i, ms in
                (i, BallObservation(frameIndex: i, timestampMs: ms, x: 0.5, y: 0.4 + Double(i) * 0.01,
                                    width: 0.05, height: 0.03, confidence: 0.95))
            })
            return TimedTrajectory.point(at: frame, in: Array(times.indices), stamps: stamps,
                filled: balls, observed: balls, config: CounterConfig()) != nil
        }
        let dropped = [0, 67, 100, 133, 167, 200, 233, 267, 300]
        for frame in dropped.indices { #expect(!usesSparsePath(dropped, frame: frame)) }
        let alternating = [0, 33, 100, 133, 200, 233, 300, 333, 400]
        for frame in 1...7 { #expect(usesSparsePath(alternating, frame: frame)) }
    }

    @Test func smallStationaryJitterDoesNotBecomeTouches() {
        let inputs = (0..<120).map { i -> CounterTrace.Input in
            let ms = Int((Double(i) * 1000 / 15).rounded())
            return .init(frameIndex: i, timestampMs: ms, sourceFrameIndex: i,
                ball: .init(frameIndex: i, timestampMs: ms, x: 0.5, y: 0.55 + sin(Double(i) * 2) * 0.002,
                            width: 0.06, height: 0.035, confidence: 0.99),
                person: .init(x: 0.5, y: 0.45, width: 0.8, height: 0.9), cameraOffsetY: 0, reliable: true)
        }
        #expect(replay(inputs, enabled: true, body: true).touches.isEmpty)
    }
}
