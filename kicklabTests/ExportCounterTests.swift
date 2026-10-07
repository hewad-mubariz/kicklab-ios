import CoreGraphics
import Foundation
import Testing
@testable import kicklab

struct ExportCounterTests {
    private func touch(_ time: Double) -> RecordedTouch {
        RecordedTouch(index: 0, time: time, x: 0.5, y: 0.5)
    }

    @Test func recordedTouchesAdvanceExactlyAndSeekingDoesNotAccumulate() {
        let counter = ExportCounterTimeline(touches: [touch(3), touch(1), touch(2)], total: 3)
        #expect(counter.state(at: 0).count == 0)
        #expect(counter.state(at: 0.999).count == 0)
        #expect(counter.state(at: 1).count == 1)
        #expect(counter.state(at: 2.5).count == 2)
        #expect(counter.state(at: 9).count == 3)
        #expect(counter.state(at: 1.5).count == 1)
        #expect(counter.state(at: 1.5).age == 0.5)
        #expect(!counter.state(at: 1.5).isTotal)
    }

    @Test func missingTimesUseAnExplicitTotalAndInvalidTimesAreIgnored() {
        let total = ExportCounterTimeline(touches: [], total: 24)
        #expect(total.state(at: 0).count == 24)
        #expect(total.state(at: 5).label == "TOTAL TOUCHES")
        let valid = ExportCounterTimeline(touches: [touch(.nan), touch(-1), touch(.infinity), touch(1)], total: 1)
        #expect(valid.times == [1])
        #expect(valid.state(at: .nan).count == 0)
        #expect(ExportCounterTimeline(touches: [], total: -5).state(at: 0).count == 0)
    }

    @Test func badgeIsDeterministicReadableAndStaysInFrameAtBothQualities() throws {
        let timeline = ExportCounterTimeline(touches: [touch(1), touch(2)], total: 2)
        let first = try #require(ExportCounterRenderer.image(state: timeline.state(at: 1.5)))
        let repeated = try #require(ExportCounterRenderer.image(state: timeline.state(at: 1.5)))
        let second = try #require(ExportCounterRenderer.image(state: timeline.state(at: 2.5)))
        let bytes = try #require(first.dataProvider?.data) as Data
        #expect(bytes == (repeated.dataProvider!.data! as Data))
        #expect(bytes != (second.dataProvider!.data! as Data))
        #expect(bytes.contains { $0 > 200 })
        for size in [CGSize(width: 720, height: 1280), CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            let rect = ExportCounterRenderer.rect(in: size)
            #expect(CGRect(origin: .zero, size: size).contains(rect))
            #expect(abs(rect.midX-size.width/2) < 0.01)
        }
    }
}
