import XCTest
@testable import kicklab

/// Detector output saved from real recordings, replayed through the rule. The
/// saved video look reads the same detections, so it can only ever agree.
final class StreakAbsenceFootageReplayTests: XCTestCase {
    private struct Case: Decodable {
        let clip, run, expect, why: String
        let before, after: Int
        let samples: String
        var timeline: [StreakVisibilityEvidence.Sample] {
            var time = before
            return samples.split(separator: " ").map { entry in
                let parts = entry.split(separator: ":").map { Int($0)! }
                time += parts[0]
                return .init(timeMS: time, personVisible: parts[1] & 2 != 0, ballVisible: parts[1] & 1 != 0)
            }
        }
    }
    private struct File: Decodable { let cases: [Case] }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "streak-absence-cases", withExtension: "json"))
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    private func assess(_ item: Case) -> StreakVisibilityEvidence.Assessment {
        var evidence = StreakVisibilityEvidence()
        let timeline = item.timeline
        for sample in timeline { evidence.record(timeMS: sample.timeMS, personVisible: sample.personVisible, ballVisible: sample.ballVisible) }
        return evidence.assess(touchTimes: [Double(item.before)/1000, Double(item.after)/1000], existingBoundaries: []) { window in
            stride(from: window.startMS+250, to: window.endMS, by: 500).compactMap { target in
                guard let near = timeline.min(by: { abs($0.timeMS-target) < abs($1.timeMS-target) }), abs(near.timeMS-target) <= 100 else { return nil }
                return .init(timeMS: target, personVisible: near.personVisible, ballVisible: near.ballVisible)
            }
        }
    }

    func testValidJugglingNeverEndsTheStreak() throws {
        let valid = try cases().filter { $0.expect == "keep" }
        XCTAssertGreaterThanOrEqual(valid.count, 30)
        XCTAssertGreaterThanOrEqual(Set(valid.map(\.clip)).count, 10)
        for item in valid {
            let result = assess(item)
            XCTAssertTrue(result.decisions.isEmpty, "\(item.clip) \(item.before)-\(item.after): \(item.why): \(result.decisions.map(\.kind))")
        }
    }

    func testRealStopsEndTheStreakOnEveryRunOfTheClip() throws {
        let stops = try cases().filter { $0.expect == "end" }
        XCTAssertGreaterThanOrEqual(stops.count, 6)
        for item in stops {
            let result = assess(item)
            XCTAssertFalse(result.decisions.isEmpty, "\(item.clip) \(item.before)-\(item.after): \(item.why)")
            XCTAssertTrue(Set(result.decisions.map(\.kind)).isSubset(of: [.ballOutOfView, .playerOutOfView]), "\(item.clip)")
        }
    }

    func testTheSixThousandTouchSessionStaysInOnePiece() throws {
        let longest = try XCTUnwrap(cases().first { $0.clip == "long-session" && $0.after-$0.before < 4_000 })
        XCTAssertEqual(longest.expect, "keep")
        XCTAssertTrue(assess(longest).decisions.isEmpty)
    }
}
