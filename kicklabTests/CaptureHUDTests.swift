import Foundation
import XCTest
@testable import kicklab

final class CaptureHUDTests: XCTestCase {
    func testRhythmMatchesTheLabRollingFiveTouchAverage() {
        let current = CaptureRhythm(touchTimes: [0, 0.5, 1.1, 1.8, 2.6, 3.5, 9], at: 3.6)
        XCTAssertEqual(current.interval ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(current.perMinute ?? 0, 80, accuracy: 0.0001)
    }

    func testReplayGraphKeepsFullSessionScaleWhileSeekingAndPreservesMissingSamples() {
        let points = [CaptureMotionPoint(time: 0, y: 0.8), .init(time: 0.1, y: 0.6),
                      .init(time: 0.2, y: nil), .init(time: 0.3, y: 0.4), .init(time: 8, y: 0.7)]
        let graph = CaptureGraphLayout(points: points, time: 0.1, duration: 10)
        let later = CaptureGraphLayout(points: points, time: 8, duration: 10)
        XCTAssertEqual(graph.timeRange, 0...10)
        XCTAssertEqual(graph.verticalRange, later.verticalRange)
        XCTAssertEqual(graph.samples.count, 5)
        XCTAssertNil(graph.samples[2].point)
        XCTAssertEqual(graph.cursor, 0.01, accuracy: 0.0001)
        XCTAssertEqual(graph.samples.last?.point?.x ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(graph.status, "RISING ↑")
        XCTAssertEqual(CaptureGraphLayout(points: points, time: 0.2, duration: 10).status, "TRACK LOST")
        XCTAssertNil(CaptureGraphLayout(points: points, time: 5, duration: 10).currentPoint)
    }

    func testLiveGraphUsesOnlyItsRecentWindowAndHandlesEmptyOrInvalidObservations() {
        let points = [CaptureMotionPoint(time: 0, y: 0.1), .init(time: 7, y: .nan),
                      .init(time: 11.9, y: 0.4), .init(time: 12, y: 0.5)]
        let graph = CaptureGraphLayout(points: points, time: 12)
        XCTAssertEqual(graph.timeRange, 6...12)
        XCTAssertEqual(graph.samples.count, 3)
        XCTAssertNil(graph.samples[0].point)
        XCTAssertEqual(graph.status, "FALLING ↓")
        XCTAssertEqual(graph.cursor, 1)
        XCTAssertEqual(CaptureGraphLayout(points: [], time: 0).status, "ACQUIRING")
        XCTAssertNil(CaptureGraphLayout(points: [], time: .nan).currentPoint)
    }

    func testRhythmUsesOnlyConfirmedPastTouchesAndSurvivesSeeking() {
        let times = [0.3, 0.95, 1.6, 2.25, 9.0]
        let current = CaptureRhythm(touchTimes: times, at: 2.3)
        XCTAssertEqual(current.interval ?? 0, 0.65, accuracy: 0.0001)
        XCTAssertEqual(current.perMinute ?? 0, 60 / 0.65, accuracy: 0.0001)
        XCTAssertEqual(CaptureRhythm(touchTimes: times, at: 0.8).intervalLabel, "—")
        XCTAssertEqual(CaptureRhythm(touchTimes: [.nan, .infinity, -1], at: 3).rhythmLabel, "—")
        XCTAssertEqual(CaptureRhythm(touchTimes: times, at: 2.3), current)
    }

    func testOpeningCaptureDoesNotConsumeSessionNumbers() throws {
        let name = "CaptureHUDTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(JugglingSessionIdentity.next(in: defaults), 1)
        XCTAssertEqual(JugglingSessionIdentity.next(in: defaults), 1)
        XCTAssertEqual(JugglingSessionIdentity.begin(in: defaults), 1)
        XCTAssertEqual(JugglingSessionIdentity.next(in: defaults), 2)
        XCTAssertEqual(JugglingSessionIdentity.begin(in: defaults), 2)
        XCTAssertEqual(JugglingSessionIdentity.label(2), "SESSION 02")
        XCTAssertEqual(JugglingSessionIdentity.label(120), "SESSION 120")
    }
}
