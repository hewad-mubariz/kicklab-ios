import XCTest
import AVFoundation
import SceneKit
import simd
@testable import kicklab

final class LearningCoachTests: XCTestCase {
    @MainActor
    func testHumanSkeletonKeepsItsLimbLengthsAndReachesTheAuthoredTargets() throws {
        let character = try HumanCoachRig(url: XCTUnwrap(HumanCoachRig.assetURL))
        var skinnedMeshes = 0
        character.node.enumerateChildNodes { node, _ in
            if node.skinner != nil { skinnedMeshes += 1 }
            XCTAssertTrue(node.animationKeys.isEmpty, "Embedded clips must not fight the lesson motion.")
        }
        XCTAssertGreaterThan(skinnedMeshes, 0, "Use the textured human model.")
        for lesson in LearnLesson.all {
            for frame in 0..<100 {
                let pose = CoachPose.sample(lesson.motion, progress: Double(frame) / 100)
                character.update(pose, time: 0, speaking: false)
                for side in CoachSide.allCases {
                    let prefix = "Bip01_" + (side == .right ? "L" : "R") + "_"
                    for (a, b, length): (String, String, Float) in [
                        ("Thigh", "Calf", CoachAnatomy.thighLength), ("Calf", "Foot", CoachAnatomy.calfLength),
                        ("UpperArm", "Forearm", CoachAnatomy.upperArmLength), ("Forearm", "Hand", CoachAnatomy.forearmLength)
                    ] {
                        let actual = try simd_distance(XCTUnwrap(character.position(of: prefix + a)), XCTUnwrap(character.position(of: prefix + b)))
                        XCTAssertEqual(actual, length, accuracy: 0.001, "\(lesson.id) \(a)")
                    }
                    for (joint, target) in [("Foot", pose.foot(side).position), ("Hand", pose.hand(side)),
                                            ("Thigh", pose.hip(side)), ("Calf", pose.knee(side))] {
                        let actual = try XCTUnwrap(character.position(of: prefix + joint))
                        XCTAssertLessThan(simd_distance(actual, target), 0.002, "\(lesson.id) \(joint)")
                    }
                }
            }
        }
    }

    func testAllLessonsStayReachableAndLoopWithoutBallOrHandJumps() {
        for lesson in LearnLesson.all {
            let plan = CoachChoreography(lesson.motion)
            var previous: CoachPose?
            for frame in 0...1000 {
                let pose = plan.sample(seconds: Float(frame) / 1000 * plan.duration)
                XCTAssertTrue(pose.ball.x.isFinite && pose.ball.y.isFinite && pose.ball.z.isFinite)
                XCTAssertGreaterThanOrEqual(pose.ball.y, CoachPose.ballRadius - 0.001, lesson.id)
                if let previous {
                    for jump in [simd_distance(previous.ball, pose.ball), simd_distance(previous.leftHand, pose.leftHand),
                                 simd_distance(previous.rightHand, pose.rightHand), simd_distance(previous.pelvis, pose.pelvis)] {
                        XCTAssertLessThan(jump, 0.025, lesson.id)
                    }
                }
                for side in CoachSide.allCases {
                    XCTAssertLessThan(simd_distance(pose.hip(side), pose.foot(side).position), CoachAnatomy.thighLength + CoachAnatomy.calfLength - 0.001, lesson.id)
                    XCTAssertLessThan(simd_distance(pose.shoulder(side), pose.hand(side)), CoachAnatomy.upperArmLength + CoachAnatomy.forearmLength - 0.001, lesson.id)
                }
                previous = pose
            }
        }
    }

    func testFreeBallFlightHasGravityAndARealTimeDrop() {
        for motion in [CoachMotion.touchCatch, .bounceCatch, .twoTouchCatch] {
            let plan = CoachChoreography(motion)
            let dropDuration = plan.contacts[0].time - plan.release
            XCTAssertGreaterThan(dropDuration, 0.35)
            XCTAssertLessThan(dropDuration, 0.50, "The normal-speed ball must not float down for a second.")
            for time in [plan.release + 0.15, plan.contacts[0].time + 0.15] {
                let dt: Float = 0.01
                let before = plan.sample(seconds: time - dt).ball.y
                let at = plan.sample(seconds: time).ball.y
                let after = plan.sample(seconds: time + dt).ball.y
                let acceleration = (after - 2 * at + before) / (dt * dt)
                XCTAssertEqual(acceleration, -9.81, accuracy: 0.05)
            }
        }
    }

    func testSupportFeetStayPlantedWhileWeightMovesAndStepsOnlyMoveInAir() {
        for motion in [CoachMotion.touchCatch, .alternating, .moving] {
            let plan = CoachChoreography(motion)
            var previous = plan.sample(seconds: 0)
            var pelvisMin = previous.pelvis.x, pelvisMax = previous.pelvis.x
            for frame in 1...1000 {
                let pose = plan.sample(seconds: Float(frame) / 1000 * plan.duration)
                for side in CoachSide.allCases {
                    let a = previous.foot(side), b = pose.foot(side)
                    if abs(a.position.y - CoachAnatomy.ankleHeight) < 0.00001 && abs(b.position.y - CoachAnatomy.ankleHeight) < 0.00001 {
                        XCTAssertEqual(a.position.x, b.position.x, accuracy: 0.0002, "A planted foot must not skate sideways.")
                        XCTAssertEqual(a.position.z, b.position.z, accuracy: 0.0002)
                        XCTAssertEqual(b.pitch, 0, accuracy: 0.001)
                    }
                }
                pelvisMin = min(pelvisMin, pose.pelvis.x)
                pelvisMax = max(pelvisMax, pose.pelvis.x)
                previous = pose
            }
            XCTAssertGreaterThan(pelvisMax - pelvisMin, 0.06, "The body must transfer weight, not just move the ankles.")
        }
    }

    func testContactsMeetTheBallAndCatchesAbsorbItsArrival() {
        for lesson in LearnLesson.all {
            let plan = CoachChoreography(lesson.motion)
            for contact in plan.contacts {
                let pose = plan.sample(seconds: contact.time)
                XCTAssertLessThan(simd_distance(pose.ball, plan.contactPosition(contact)), 0.001, lesson.id)
                if contact.kind == .foot {
                    XCTAssertLessThan(simd_distance(pose.ball, pose.foot(contact.side).ballContact), 0.001)
                    let before = plan.sample(seconds: contact.time - 0.005).ball.y
                    let after = plan.sample(seconds: contact.time + 0.005).ball.y
                    XCTAssertGreaterThan(before, pose.ball.y, lesson.id)
                    XCTAssertGreaterThan(after, pose.ball.y, lesson.id)
                }
            }
            if let time = plan.catchTime {
                let catchPose = plan.sample(seconds: time)
                let softened = plan.sample(seconds: time + 0.10)
                XCTAssertLessThan(softened.ball.y, catchPose.ball.y - 0.03)
                XCTAssertEqual(softened.held, 1)
                for side in CoachSide.allCases {
                    let reach = simd_distance(softened.hand(side), softened.ball)
                    XCTAssertGreaterThan(reach, 0.13)
                    XCTAssertLessThan(reach, 0.17)
                }
            }
        }
    }

    func testEasierRoutesResolveAndBothFeetAreDemonstrated() {
        let ids = Set(LearnLesson.all.map(\.id))
        XCTAssertEqual(ids.count, LearnLesson.all.count)
        for lesson in LearnLesson.all { XCTAssertTrue(ids.contains(lesson.easierID)) }
        XCTAssertEqual(CoachChoreography(.otherFootCatch).contacts.first?.side, .left)
        XCTAssertEqual(CoachChoreography(.alternatingCatch).contacts.map(\.side), [.right, .left])
    }

    @MainActor
    func testCoachVoiceProducesAudio() async throws {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = try XCTUnwrap(LearningCoach.utterance("Let's try together. A gentle touch. Then catch and reset."))
        let finished = expectation(description: "Speech rendered")
        // Some system voices send more than one empty terminal buffer.
        finished.assertForOverFulfill = false
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("learn-coach-voice.caf")
        var file: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var writeError: Error?
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finished.fulfill(); return }
            do {
                if file == nil { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                try file?.write(from: pcm)
                frames += AVAudioFramePosition(pcm.frameLength)
            } catch { writeError = error }
        }
        await fulfillment(of: [finished], timeout: 45)
        XCTAssertNil(writeError)
        XCTAssertGreaterThan(frames, 1000, "The selected system voice must produce audible-length audio.")
        file = nil
        if frames > 1000 {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = "Learn coach - system voice"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testSilentPracticePauseReflectionAndReset() {
        let coach = LearningCoach()
        coach.voiceEnabled = false
        coach.start(.lesson("touch-catch"))
        XCTAssertEqual(coach.mode, .practice)
        XCTAssertFalse(coach.speaking)
        coach.pause()
        XCTAssertEqual(coach.mode, .demonstration)
        coach.start(.lesson("touch-catch"))
        coach.finish()
        XCTAssertEqual(coach.mode, .reflection)
        coach.reset()
        XCTAssertEqual(coach.mode, .demonstration)
        XCTAssertEqual(coach.round, 0)
    }
}
