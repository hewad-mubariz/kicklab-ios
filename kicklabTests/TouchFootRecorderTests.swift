import Foundation
import Testing
@testable import kicklab

/// The foot of each touch from the counter's own contact poses, and how it is saved.
struct TouchFootRecorderTests {
    /// A pose facing the camera: the person's left hip is on the image's right.
    private func pose(raised: BodySide?, facingCamera: Bool = true, swapNames: Bool = false) -> BodyPose {
        var pose = BodyPose()
        let leftX = facingCamera ? 0.56 : 0.44, rightX = facingCamera ? 0.44 : 0.56
        pose.hips[.left] = PoseLandmark(x: leftX, y: 0.55, confidence: 0.9)
        pose.hips[.right] = PoseLandmark(x: rightX, y: 0.55, confidence: 0.9)
        var left = PoseLandmark(x: leftX + 0.02, y: 0.9, confidence: 0.9), right = PoseLandmark(x: rightX - 0.02, y: 0.9, confidence: 0.9)
        if raised == .left { left = PoseLandmark(x: leftX + 0.06, y: 0.78, confidence: 0.9) }
        if raised == .right { right = PoseLandmark(x: rightX - 0.06, y: 0.78, confidence: 0.9) }
        // Vision sometimes swaps the ankle names when the legs cross; the image positions are what count.
        pose.ankles[.left] = swapNames ? right : left
        pose.ankles[.right] = swapNames ? left : right
        return pose
    }

    @Test func raisedFootGivesTheSideFacingTheCamera() {
        let recorder = TouchFootRecorder()
        for ms in [950, 967, 983, 1000] { recorder.record(timestampMs: ms, pose: pose(raised: .left), aspect: 9.0 / 16) }
        for ms in [1950, 1967, 1983, 2000] { recorder.record(timestampMs: ms, pose: pose(raised: .right), aspect: 9.0 / 16) }
        #expect(recorder.feet(atContactMs: [1000, 2000]) == [.left, .right])
    }

    @Test func swappedAnkleNamesDoNotFlipTheFoot() {
        let recorder = TouchFootRecorder()
        for ms in [950, 967, 983, 1000] { recorder.record(timestampMs: ms, pose: pose(raised: .left, swapNames: true), aspect: 9.0 / 16) }
        #expect(recorder.feet(atContactMs: [1000]) == [.left])
    }

    @Test func facingAwayUsesTheHipsOverTheSession() {
        let recorder = TouchFootRecorder()
        for ms in [950, 967, 983, 1000] {
            recorder.record(timestampMs: ms, pose: pose(raised: .left, facingCamera: false), aspect: 9.0 / 16)
        }
        #expect(recorder.feet(atContactMs: [1000]) == [.left])
    }

    @Test func noPoseOrNoLiftLeavesTheFootUnknown() {
        let recorder = TouchFootRecorder()
        for ms in [950, 967, 983, 1000] { recorder.record(timestampMs: ms, pose: pose(raised: nil), aspect: 9.0 / 16) }
        #expect(recorder.feet(atContactMs: [1000, 5000]) == [nil, nil])
        recorder.reset()
        #expect(recorder.counts.ankles == 0)
    }

    @Test func nearestPosesAreUsedWhenTheLabWindowIsEmpty() {
        let recorder = TouchFootRecorder()
        // 30 fps analysis with the contact frame itself missing: only -100 ms and +33 ms poses.
        recorder.record(timestampMs: 900, pose: pose(raised: .right), aspect: 9.0 / 16)
        recorder.record(timestampMs: 1033, pose: pose(raised: .right), aspect: 9.0 / 16)
        #expect(recorder.feet(atContactMs: [1000]) == [.right])
    }

    @Test func lettersRoundTripAndOldDataStaysUnknown() throws {
        let touches = [RecordedTouch(index: 1, time: 1, x: 0.5, y: 0.5, foot: .left),
                       RecordedTouch(index: 2, time: 2, x: 0.5, y: 0.5),
                       RecordedTouch(index: 3, time: 3, x: 0.5, y: 0.5, foot: .right)]
        #expect(TouchFoot.letters(touches) == "LUR")
        let plain = touches.map { RecordedTouch(index: $0.index, time: $0.time, x: $0.x, y: $0.y) }
        #expect(TouchFoot.letters(plain) == nil)
        #expect(TouchFoot.apply("LUR", to: plain).map(\.foot) == [.left, nil, .right])
        #expect(TouchFoot.apply("LU", to: plain).map(\.foot) == [nil, nil, nil])
        #expect(TouchFoot.apply(nil, to: plain).map(\.foot) == [nil, nil, nil])
    }

    @Test func savedAnalysisWithoutFeetStillDecodes() throws {
        let old = #"{"frames":[],"touches":[[1,0.5,0.4,0.6]],"count":1,"detections":0,"rejected":0,"framesRead":0,"duration":2,"peak":0,"model":"m","elapsed":1}"#
        let stored = try JSONDecoder().decode(StoredInference.self, from: Data(old.utf8))
        #expect(stored.feet == nil)
        #expect(stored.recordedTouches.map(\.foot) == [nil])
        var withFeet = stored
        withFeet.feet = "R"
        let again = try JSONDecoder().decode(StoredInference.self, from: JSONEncoder().encode(withFeet))
        #expect(again.recordedTouches.map(\.foot) == [.right])
    }
}
