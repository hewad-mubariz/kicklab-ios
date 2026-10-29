import Foundation
import Testing
@testable import kicklab

struct SettledReboundProbeTests {
    private final class Resources {}
    private struct Fixture: Decodable {
        let targetMs: Int
        var config: CounterConfig
        let operations: [CounterTrace.Operation]
        let foot: FootContactEvidence
    }
    private func fixtures() throws -> [Fixture] {
        let url = try #require(Bundle(for: Resources.self).url(
            forResource: "outdoor-settled-rebound-20261029", withExtension: "json"))
        return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    }
    @Test func realMissedReboundsRequestEvidenceButCannotCountWithoutIt() throws {
        for f in try fixtures() {
            var config=f.config; config.probesSettledMeasuredRebound=true
            var requested: [Int] = []
            let c=StreamingCounter(config:config,rejectsHandContact:{_ in false},recordTrace:true,
                footContactEvidence:{ frame in requested.append(frame);return nil },allowsBodyContact:{_ in true})
            for op in f.operations { if let i=op.input {
                c.push(frameIndex:i.frameIndex,timestampMs:i.timestampMs,ball:i.ball,person:i.person,
                    cameraOffsetY:i.cameraOffsetY,reliable:i.reliable,sourceFrameIndex:i.sourceFrameIndex,player:i.player)
            } }
            c.flush(); let trace=try #require(c.traceSnapshot())
            let target=try #require(f.operations.compactMap(\.input).first { $0.timestampMs==f.targetMs })
            #expect(requested.filter { $0==target.frameIndex }.count == 1)
            #expect(!trace.touches.contains { $0.timestampMs==f.targetMs })
            #expect(try trace.replay()==trace.touches)
        }
        #expect(!MeasuredReboundPolicy.settledProbe(arguments:[]))
    }

    @Test func savedKickNeedsMeasuredReleaseAndKeepsContactVetoes() throws {
        let fixture = try #require(fixtures().first { $0.targetMs == 11650 })
        let target = try #require(fixture.operations.compactMap(\.input).first {
            $0.timestampMs == fixture.targetMs
        })
        func run(enabled: Bool = true, hand: Bool = false, body: Bool = true,
                 holding: Bool = false, missingRelease: Bool = false) throws -> CounterTrace {
            var config = fixture.config
            config.probesSettledMeasuredRebound = enabled ? true : nil
            let held = BallHandlingEvidence(contactMs: fixture.targetMs, samples: [-100, -50, 0, 50, 100].map { dt in
                .init(timestampMs: fixture.targetMs + dt, ball: .init(x: 0.5, y: 0.6),
                    width: 0.18, height: 0.1, confidence: 0.9, imageAspect: 0.5625,
                    wrists: [.left: .init(x: 0.4, y: 0.56, confidence: 0.9),
                             .right: .init(x: 0.6, y: 0.56, confidence: 0.9)])
            })
            #expect(held.state == .held)
            let counter = StreamingCounter(config: config, rejectsHandContact: { _ in hand },
                recordTrace: true,
                footContactEvidence: { $0 == target.frameIndex ? fixture.foot : nil },
                allowsBodyContact: { _ in body }, handlingEvidence: { _ in holding ? held : nil })
            for operation in fixture.operations {
                if let input = operation.input {
                    let hide = missingRelease && (11651...11850).contains(input.timestampMs)
                    counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                        ball: hide ? nil : input.ball, person: input.person,
                        cameraOffsetY: input.cameraOffsetY, reliable: input.reliable,
                        sourceFrameIndex: input.sourceFrameIndex, player: input.player)
                }
            }
            counter.flush()
            let trace = try #require(counter.traceSnapshot())
            #expect(try trace.replay() == trace.touches)
            return trace
        }
        #expect(try run().touches.filter { $0.timestampMs == fixture.targetMs }.count == 1)
        for trace in try [run(enabled: false), run(hand: true), run(body: false),
                          run(holding: true), run(missingRelease: true)] {
            #expect(!trace.touches.contains { $0.timestampMs == fixture.targetMs })
        }
    }

    @Test func raisedToeNeedsStableSupportAndTwoMeasuredReleaseViews() throws {
        let fixture = try #require(fixtures().first { $0.targetMs == 112510 })
        var foot = fixture.foot
        #expect(!foot.confirms)
        foot.allowsRaisedForefoot = true
        #expect(foot.confirmsRaisedForefoot)
        var missing = foot
        missing.continuation = nil
        #expect(!missing.confirmsRaisedForefoot)
        let release = try #require(foot.continuation)
        missing.continuation = .init(timestampMs: release.timestampMs,
            ballX: release.ballX, ballY: foot.contact.ballY,
            width: release.width, height: release.height, confidence: release.confidence,
            ankles: release.ankles, hips: release.hips)
        #expect(!missing.confirmsRaisedForefoot)
        var movingSupport = release.ankles
        movingSupport[.left] = .init(x: 0.5, y: 0.73, confidence: 0.9)
        missing.continuation = .init(timestampMs: release.timestampMs,
            ballX: release.ballX, ballY: release.ballY,
            width: release.width, height: release.height, confidence: release.confidence,
            ankles: movingSupport, hips: release.hips)
        #expect(!missing.confirmsRaisedForefoot)
        let target = try #require(fixture.operations.compactMap(\.input).first {
            $0.timestampMs == fixture.targetMs
        })
        var config = fixture.config
        config.probesSettledMeasuredRebound = true
        let counter = StreamingCounter(config: config, rejectsHandContact: { _ in false },
            recordTrace: true, footContactEvidence: { $0 == target.frameIndex ? foot : nil },
            allowsBodyContact: { _ in true })
        for operation in fixture.operations {
            if let input = operation.input {
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs,
                    ball: input.ball, person: input.person, cameraOffsetY: input.cameraOffsetY,
                    reliable: input.reliable, sourceFrameIndex: input.sourceFrameIndex, player: input.player)
            }
        }
        counter.flush()
        let trace = try #require(counter.traceSnapshot())
        #expect(trace.touches.filter { $0.timestampMs == fixture.targetMs }.count == 1)
        #expect(try trace.replay() == trace.touches)
        #expect(!MeasuredReboundPolicy.raisedForefoot(arguments: []))
    }
}
