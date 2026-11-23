import XCTest
import AVFoundation
import SceneKit
import simd
@testable import kicklab

final class LearningCoachTests: XCTestCase {
    @MainActor
    func testHumanAssetContainsTexturedSkinnedGeometry() throws {
        let rig = try HumanCoachRig(url: XCTUnwrap(HumanCoachRig.assetURL))
        var skinnedMeshes = 0
        rig.node.enumerateChildNodes { node, _ in
            guard let skinner = node.skinner else { return }
            skinnedMeshes += 1
            XCTAssertGreaterThan(skinner.bones.count, 20)
            XCTAssertTrue(node.geometry?.materials.contains { $0.diffuse.contents != nil } == true)
        }
        XCTAssertGreaterThan(skinnedMeshes, 0, "The shipping bundle must load the real rig, not just a scene shell.")
    }

    @MainActor
    func testRetargetedHumanMaintainsBoneLengthsAndContinuousBallPaths() throws {
        let rig = try HumanCoachRig(url: XCTUnwrap(HumanCoachRig.assetURL))
        let chains = ["L", "R"].flatMap { side in
            [("Thigh", "Calf"), ("Calf", "Foot"), ("UpperArm", "Forearm"), ("Forearm", "Hand")].map {
                ("Bip01_\(side)_\($0.0)", "Bip01_\(side)_\($0.1)")
            }
        }
        let lengths = try chains.map { try simd_distance(XCTUnwrap(rig.position(of: $0.0)), XCTUnwrap(rig.position(of: $0.1))) }
        for lesson in LearnLesson.all {
            var previous: SIMD3<Float>?
            for frame in 0...200 {
                let progress = Double(frame) / 200
                rig.update(CoachPose.sample(lesson.motion, progress: progress), time: progress * lesson.motion.duration, speaking: false)
                let ball = rig.ballPosition
                XCTAssertTrue(ball.x.isFinite && ball.y.isFinite && ball.z.isFinite, lesson.id)
                XCTAssertGreaterThanOrEqual(ball.y, 0.114, lesson.id)
                if let previous { XCTAssertLessThan(simd_distance(ball, previous), 0.1, lesson.id) }
                previous = ball
                for (index, chain) in chains.enumerated() {
                    let length = try simd_distance(XCTUnwrap(rig.position(of: chain.0)), XCTUnwrap(rig.position(of: chain.1)))
                    XCTAssertEqual(length, lengths[index], accuracy: 0.001, lesson.id)
                }
            }
        }
    }

    @MainActor
    func testHumanCatchesAndBootContactRespectModelProportions() throws {
        let rig = try HumanCoachRig(url: XCTUnwrap(HumanCoachRig.assetURL))
        for (motion, side) in [(CoachMotion.touchCatch, "L"), (.otherFootCatch, "R")] {
            rig.update(CoachPose.sample(motion, progress: 0.34), time: 0, speaking: false)
            let ankle = try XCTUnwrap(rig.position(of: "Bip01_\(side)_Foot"))
            let toe = try XCTUnwrap(rig.position(of: "Bip01_\(side)_Toe0"))
            let laces = ankle * 0.45 + toe * 0.55
            XCTAssertGreaterThan(rig.ballPosition.y - laces.y, 0.12)
            XCTAssertLessThan(simd_distance(rig.ballPosition, laces), 0.19)
            rig.update(CoachPose.sample(motion, progress: 0.8), time: 0, speaking: false)
            for sign: Float in [-1, 1] {
                let hand = try XCTUnwrap(rig.position(of: "Bip01_\(sign > 0 ? "L" : "R")_Hand"))
                let target = rig.ballPosition + SIMD3<Float>(sign * 0.17, 0.025, 0.01)
                XCTAssertLessThan(simd_distance(hand, target), 0.01)
            }
        }
        rig.update(CoachPose.sample(.bounceCatch, progress: 0.4), time: 0, speaking: false)
        XCTAssertEqual(rig.ballPosition.y, 0.115, accuracy: 0.001)
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

    func testBallNeverPassesThroughFloorAndLoopsContinuously() {
        for lesson in LearnLesson.all {
            for sample in 0..<1000 {
                let pose = CoachPose.sample(lesson.motion, progress: Double(sample) / 1000)
                XCTAssertGreaterThanOrEqual(pose.ball.y, 0.114, lesson.id)
                XCTAssertTrue(pose.ball.x.isFinite && pose.ball.y.isFinite && pose.ball.z.isFinite)
            }
            let first = CoachPose.sample(lesson.motion, progress: 0)
            let last = CoachPose.sample(lesson.motion, progress: 0.99999)
            XCTAssertEqual(first.ball.x, last.ball.x, accuracy: 0.002, lesson.id)
            XCTAssertEqual(first.ball.y, last.ball.y, accuracy: 0.002, lesson.id)
        }
    }

    func testTouchAndCatchHaveDifferentSuccessBoundaries() {
        let contact = CoachPose.sample(.touchCatch, progress: 0.34)
        XCTAssertEqual(contact.ball.y, 0.325, accuracy: 0.001)
        XCTAssertEqual(contact.rightLift, 0.085, accuracy: 0.001)
        XCTAssertEqual(contact.held, 0)
        let catchPose = CoachPose.sample(.touchCatch, progress: 0.80)
        XCTAssertEqual(catchPose.held, 1)
        XCTAssertEqual(catchPose.phase, "Catch & reset")
        let bounce = CoachPose.sample(.bounceCatch, progress: 0.40)
        XCTAssertEqual(bounce.ball.y, 0.115, accuracy: 0.001)
        XCTAssertEqual(bounce.leftLift + bounce.rightLift, 0)
    }

    func testEasierRoutesResolveAndBothFeetAreDemonstrated() {
        let ids = Set(LearnLesson.all.map(\.id))
        XCTAssertEqual(ids.count, LearnLesson.all.count)
        for lesson in LearnLesson.all { XCTAssertTrue(ids.contains(lesson.easierID)) }
        let otherFoot = CoachPose.sample(.otherFootCatch, progress: 0.34)
        XCTAssertLessThan(otherFoot.ball.x, 0)
        XCTAssertGreaterThan(otherFoot.leftLift, otherFoot.rightLift)
        let first = CoachPose.sample(.alternatingCatch, progress: 0.34)
        let second = CoachPose.sample(.alternatingCatch, progress: 0.55)
        XCTAssertGreaterThan(first.ball.x, 0)
        XCTAssertLessThan(second.ball.x, 0)
        XCTAssertGreaterThan(second.leftLift, second.rightLift)
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
