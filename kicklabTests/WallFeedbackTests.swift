#if DEBUG
import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class WallFeedbackTests: XCTestCase {
    func testArmourCrackAndBreakUseDistinctCues() {
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 1, cleared: false), .armourCrack)
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 0, cleared: false), .brickBreak)
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 0, cleared: false, brokenBricks: 3), .brickSmash)
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 1, cleared: false, brokenBricks: 0), .armourCrack)
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 0, cleared: true, brokenBricks: 5), .brickClear)
        XCTAssertEqual(WallHitSound.forHit(game: .brickBlast, remainingHealth: 0, cleared: true), .brickClear)
        XCTAssertEqual(WallHitSound.forHit(game: .clearTheWall, remainingHealth: 0, cleared: false), .targetHit)
        XCTAssertEqual(WallHitSound.forHit(game: .clearTheWall, remainingHealth: 0, cleared: true), .targetClear)
    }

    func testEveryBrickCueShipsAsDecodableShortPCM() throws {
        for cue in WallHitSound.allCases {
            for name in cue.assets {
                let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "wav"), name)
                let file = try AVAudioFile(forReading: url)
                XCTAssertEqual(file.processingFormat.channelCount, 1)
                XCTAssertEqual(file.processingFormat.sampleRate, 44100)
                let duration = Double(file.length) / file.processingFormat.sampleRate
                XCTAssertGreaterThan(duration, 0.15)
                XCTAssertLessThan(duration, 1.2)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
                try file.read(into: buffer)
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                let peak = (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }.max() ?? 0
                XCTAssertGreaterThan(peak, 0.2, "Silent cue: \(name)")
                XCTAssertLessThan(peak, 0.95, "Clipped cue: \(name)")
                XCTAssertEqual(samples[Int(buffer.frameLength) - 1], 0, accuracy: 0.001)
            }
        }
    }

    func testSlowAudioDoesNotBlockUIAndKeepsCrackBeforeBreak() async {
        let entered = expectation(description: "Audio work started")
        let finished = expectation(description: "Crack and break delivered in order")
        let output = SlowOutput(entered: entered, finished: finished)
        let feedback = WallTargetsFeedback(output: output)
        feedback.prepare()
        feedback.play(cleared: false, game: .brickBlast, remainingHealth: 1)
        feedback.play(cleared: false, game: .brickBlast, remainingHealth: 0)
        // The fake output is still blocked. Reaching this line proves the UI
        // can continue without waiting for AVAudioPlayer's route operation.
        await fulfillment(of: [entered], timeout: 2)
        output.release.signal()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testProductionDetectorIsBundled() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: BallDetector.productionResourceName, withExtension: "mlmodelc"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path))
    }
}
/// Accessed only by the delivery queue, apart from the thread-safe semaphore.
nonisolated private final class SlowOutput: WallFeedbackOutput {
    let release = DispatchSemaphore(value: 0)
    let entered: XCTestExpectation
    let finished: XCTestExpectation
    private var calls: [Int] = []
    init(entered: XCTestExpectation, finished: XCTestExpectation) {
        self.entered = entered; self.finished = finished
    }
    func prepare() {
        XCTAssertFalse(Thread.isMainThread)
        calls.append(-1)
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
    }
    func play(cleared: Bool, game: WallGame, remainingHealth: Int, brokenBricks: Int) {
        XCTAssertFalse(Thread.isMainThread)
        calls.append(remainingHealth)
        if calls.count == 3 {
            XCTAssertEqual(calls, [-1, 1, 0])
            finished.fulfill()
        }
    }
    func invalidatePreparation() {}
    func playArcade(_ cue: WallArcadeCue) {}
}
#endif
