import Foundation
import Testing
@testable import kicklab

struct JugglingCounterTests {
    private let person = PersonBox(x: 0.5, y: 0.45, width: 0.8, height: 0.9)
    private let arc = [0.35, 0.4, 0.46, 0.53, 0.60, 0.67, 0.73, 0.76,
                       0.74, 0.70, 0.63, 0.55, 0.46, 0.38, 0.32]

    private func push(_ counter: StreamingCounter, frame: Int, time: Int, y: Double,
                      offset: Double = 0, reliable: Bool = true) -> [Touch] {
        counter.push(frameIndex: frame, timestampMs: time,
            ball: BallObservation(frameIndex: frame, timestampMs: time,
                                  x: 0.5, y: y, width: 0.05, height: 0.03, confidence: 0.9),
            person: person, cameraOffsetY: offset, reliable: reliable)
    }

    @Test func countsObservedArcAndFlushDoesNotDuplicate() {
        let counter = StreamingCounter()
        var emitted: [Touch] = []
        for (i, y) in arc.enumerated() {
            emitted += push(counter, frame: i, time: i * 33, y: y)
        }
        emitted += counter.flush()
        #expect(counter.count == 1)
        #expect(emitted.count == counter.count)
        #expect(counter.flush().isEmpty)
    }

    @Test func skippedFramesCannotCompleteAnOldFall() {
        let counter = StreamingCounter()
        for (i, y) in arc.prefix(8).enumerated() {
            _ = push(counter, frame: i, time: i * 33, y: y)
        }
        for (i, y) in arc.dropFirst(8).enumerated() {
            _ = push(counter, frame: i + 50, time: (i + 50) * 33, y: y)
        }
        counter.flush()
        #expect(counter.count == 0)
    }

    @Test func timestampStallCannotCompleteAnOldFall() {
        let counter = StreamingCounter()
        for (i, y) in arc.enumerated() {
            _ = push(counter, frame: i, time: i * 33 + (i >= 8 ? 2000 : 0), y: y)
        }
        counter.flush()
        #expect(counter.count == 0)
    }

    @Test func unreliableFramesBreakAnArcButAllowTheNextRealTouch() {
        let counter = StreamingCounter()
        for (i, y) in arc.enumerated() {
            _ = push(counter, frame: i, time: i * 33, y: y, reliable: i != 8)
        }
        counter.flush()
        #expect(counter.count == 0)
        for (i, y) in arc.enumerated() {
            _ = push(counter, frame: i + arc.count, time: (i + arc.count) * 33, y: y)
        }
        counter.flush()
        #expect(counter.count == 1)
    }

    @Test func personAndBallUseSameCoordinatesAndEventsReturnToVideo() {
        let base = StreamingCounter(), shifted = StreamingCounter()
        for (i, y) in arc.enumerated() {
            _ = push(base, frame: i, time: i * 33, y: y)
            _ = push(shifted, frame: i, time: i * 33, y: y, offset: 0.25)
        }
        base.flush(); shifted.flush()
        #expect(base.count == 1)
        #expect(shifted.count == base.count)
        if let a = base.touches.first, let b = shifted.touches.first {
            #expect(abs(a.y - b.y) < 0.000001)
            #expect(a.frameIndex == b.frameIndex)
        }
    }

    @Test func genuineGroundReversalDoesNotCount() {
        let counter = StreamingCounter()
        for (i, y) in arc.enumerated() {
            _ = push(counter, frame: i, time: i * 33, y: y + 0.16)
        }
        counter.flush()
        #expect(counter.count == 0)
    }
}
