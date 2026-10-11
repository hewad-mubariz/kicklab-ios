import XCTest
@testable import kicklab

final class SavedShotPhaseTests: XCTestCase {
    func testMarksRequireActualFramesAndLandingAfterKick() {
        let times = [0.0, 0.017, 0.034, 0.070]
        XCTAssertTrue(SavedShotPhaseMarks(kick: 0.017, landing: 0.070).isValid(frameTimes: times))
        for marks in [SavedShotPhaseMarks(kick: nil, landing: 0.034),
                      .init(kick: 0.034, landing: 0.017), .init(kick: 0.034, landing: 0.034),
                      .init(kick: .nan), .init(kick: 0.02), .init(kick: -1)] {
            XCTAssertFalse(marks.isValid(frameTimes: times))
        }
        var marks = SavedShotPhaseMarks(kick: 0.017, landing: 0.034)
        marks.setKick(0.070)
        XCTAssertNil(marks.landing)
    }

    func testPhaseBoundariesAndFlightTimeExcludeLaterRolling() throws {
        let marks = SavedShotPhaseMarks(kick: 2, landing: 2.6)
        XCTAssertEqual(try XCTUnwrap(marks.flightSeconds), 0.6, accuracy: 0.000_001)
        XCTAssertEqual(marks.phase(at: 1.999), "Before kick")
        XCTAssertEqual(marks.phase(at: 2), "Flight · distance pending")
        XCTAssertEqual(marks.phase(at: 2.6), "After landing · roll / bounce")
        XCTAssertEqual(marks.phase(at: 15), "After landing · roll / bounce")
    }

    func testGroundSpanUsesWorldEndpointsAndIgnoresFlightPeaksAndLaterRoll() throws {
        let marks = SavedShotPhaseMarks(kick: 1, landing: 2)
        let points: [SavedDistanceTestTimeline.Position] = [
            .init(time: 0.99, point: SIMD3(3, 0, 4), segment: 1),
            .init(time: 1.5, point: SIMD3(0, 0, 25), segment: 1),
            .init(time: 2.03, point: SIMD3(0, 0, 5), segment: 1),
            .init(time: 3, point: SIMD3(-10, 0, 12), segment: 1)]
        let span = try XCTUnwrap(marks.groundSpan(positions: points))
        XCTAssertEqual(span.distanceM, sqrt(10), accuracy: 0.000_001,
            "Both endpoints are 5 m from the original origin; subtracting radial distances would incorrectly give zero")
        XCTAssertEqual(span.end.time, 2.03)
    }

    func testMissingObservationsOrNewStartsCannotCreateAGroundSpan() {
        let marks = SavedShotPhaseMarks(kick: 1, landing: 2)
        let start = SavedDistanceTestTimeline.Position(time: 0.95, point: .zero, segment: 1)
        XCTAssertNil(marks.groundSpan(positions: [start]))
        XCTAssertNil(marks.groundSpan(positions: [start, .init(time: 1.99, point: SIMD3(0, 0, 5), segment: 1)]),
            "Do not use a point from before ground contact as the landing endpoint")
        XCTAssertNil(marks.groundSpan(positions: [start, .init(time: 2.2, point: SIMD3(0, 0, 5), segment: 1)]))
        XCTAssertNil(marks.groundSpan(positions: [start, .init(time: 2.01, point: SIMD3(0, 0, 5), segment: 2)]))
    }

    func testMarksSurviveReloadAndAreBoundToTheirOriginalRecording() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let evidence = SavedShotPhaseStore.Evidence(videoSHA256: "video", distanceSHA256: "log")
        let times = [0.0, 1, 2, 3]
        let original = Data("original evidence".utf8)
        let video = folder.appendingPathComponent("video.mov"); try original.write(to: video)
        let marks = SavedShotPhaseMarks(kick: 1, landing: 2)
        try SavedShotPhaseStore.save(marks, directory: folder, evidence: evidence, frameTimes: times)
        XCTAssertEqual(try SavedShotPhaseStore.load(directory: folder, evidence: evidence, frameTimes: times), marks)
        XCTAssertThrowsError(try SavedShotPhaseStore.load(directory: folder,
            evidence: .init(videoSHA256: "different", distanceSHA256: "log"), frameTimes: times))
        XCTAssertThrowsError(try SavedShotPhaseStore.load(directory: folder, evidence: evidence, frameTimes: [0, 3]))
        XCTAssertEqual(try Data(contentsOf: video), original)
        try SavedShotPhaseStore.save(.init(), directory: folder, evidence: evidence, frameTimes: times)
        XCTAssertEqual(try SavedShotPhaseStore.load(directory: folder, evidence: evidence, frameTimes: times), .init())
    }

    func testFrameSteppingUsesPresentationTimesInsteadOfAssumingConstantFPS() {
        let frames = [0.0, 0.016, 0.035, 0.082, 0.1]
        XCTAssertEqual(SavedShotPhasePlayer.frameIndex(at: 0.035, times: frames), 2)
        XCTAssertEqual(SavedShotPhasePlayer.frameIndex(at: 0.060, times: frames), 2)
        XCTAssertEqual(SavedShotPhasePlayer.frameIndex(at: 0.082, times: frames), 3)
        XCTAssertEqual(SavedShotPhasePlayer.frameIndex(at: -1, times: frames), 0)
        XCTAssertEqual(SavedShotPhasePlayer.frameIndex(at: 1, times: frames), 4)
    }
}
