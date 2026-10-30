import Foundation
import ImageIO
import SwiftUI
import Testing
@testable import kicklab

/// Long sessions scroll the Ball Motion and Comet graphs instead of squeezing the whole clip.
@MainActor
struct GraphWindowTests {
    /// A synthetic juggle: `count` touches `gap` seconds apart, the ball sampled at 30 fps.
    private func session(touches count: Int, gap: Double = 0.62) -> (points: [CaptureMotionPoint], touches: [Double], duration: Double) {
        let touches = (0..<count).map { 0.5 + Double($0) * gap }
        let duration = (touches.last ?? 0) + 1
        let points = stride(from: 0.0, through: duration, by: 1.0 / 30).map { time -> CaptureMotionPoint in
            let phase = (time - 0.5).truncatingRemainder(dividingBy: gap) / gap
            let bounce = 0.32 + 0.06 * sin(time / 7)
            return CaptureMotionPoint(time: time, y: 0.82 - bounce * 4 * phase * (1 - phase), x: 0.5)
        }
        return (points, touches, duration)
    }

    @Test func longSessionsScrollWithThePlayheadAtEightyPercent() {
        let (points, _, duration) = session(touches: 433)
        let window = 20.0
        let early = CaptureGraphLayout(points: points, time: 5, duration: duration, window: window, vertical: 0.4...0.9)
        #expect(early.scrolls && early.timeRange == 0...20, "The window starts at zero")
        #expect(abs(early.cursor - 0.25) < 0.0001)
        let middle = CaptureGraphLayout(points: points, time: 100, duration: duration, window: window, vertical: 0.4...0.9)
        #expect(abs(middle.timeRange.lowerBound - 84) < 0.0001 && abs(middle.timeRange.upperBound - 104) < 0.0001)
        #expect(abs(middle.cursor - 0.8) < 0.0001, "The playhead rests at 80 % across")
        #expect(middle.samples.allSatisfy { middle.timeRange.contains($0.time) })
        #expect(middle.samples.count < 700, "Only the window is drawn: \(middle.samples.count) samples")
        #expect(middle.verticalRange == 0.4...0.9, "The session's scale holds still")
        let end = CaptureGraphLayout(points: points, time: duration, duration: duration, window: window, vertical: 0.4...0.9)
        #expect(abs(end.timeRange.upperBound - duration) < 0.0001, "The window stops at the end of the clip")
        // A clip no longer than the window shows everything, as before.
        let short = CaptureGraphLayout(points: points, time: 5, duration: 18, window: window)
        #expect(!short.scrolls && short.timeRange == 0...18)
        #expect(!CaptureGraphLayout(points: points, time: 5, duration: duration).scrolls)
    }

    @Test func theWindowHoldsAboutThirtyTouches() {
        let thirty = session(touches: 30)
        #expect(MotionStyleTimeline(points: thirty.points, touchTimes: thirty.touches).graphWindow == nil,
                "Thirty touches fit; the whole session shows")
        let long = session(touches: 433)
        let timeline = MotionStyleTimeline(points: long.points, touchTimes: long.touches)
        #expect(abs((timeline.graphWindow ?? 0) - 0.62 * 30) < 0.01)
        let snapshot = timeline.snapshot(at: 200, duration: long.duration)
        #expect(snapshot.graph.scrolls && snapshot.graph.verticalRange == timeline.graphVertical)
        let visibleTouches = long.touches.filter { snapshot.graph.timeRange.contains($0) }.count
        #expect((29...31).contains(visibleTouches), "\(visibleTouches) touches on screen")
        let fast = session(touches: 200, gap: 0.2)
        #expect(MotionStyleTimeline(points: fast.points, touchTimes: fast.touches).graphWindow == 8,
                "Very fast juggling still keeps eight seconds on screen")
    }

    @Test func scrollingIsNoSlowerToDrawThanTheWholeClip() {
        let long = session(touches: 433)
        let timeline = MotionStyleTimeline(points: long.points, touchTimes: long.touches)
        let whole = CaptureGraphLayout(points: timeline.points, time: 250, duration: long.duration)
        let window = timeline.snapshot(at: 250, duration: long.duration).graph
        func cost(_ layout: CaptureGraphLayout) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<20 {
                let renderer = ImageRenderer(content: CaptureMotionGraph(layout: layout, touchTimes: timeline.touches)
                    .frame(width: 314, height: 62))
                renderer.scale = 3
                _ = renderer.cgImage
            }
            return (ProcessInfo.processInfo.systemUptime - start) / 20 * 1000
        }
        _ = cost(window)
        let wholeMS = cost(whole), windowMS = cost(window)
        print("GRAPHCOST whole \(wholeMS) ms, window \(windowMS) ms per frame")
        #expect(windowMS <= wholeMS * 1.1, "Window \(windowMS) ms vs whole clip \(wholeMS) ms")
    }

    /// With GRAPH_SHOTS set, the saved-video graph card for Ball Motion and Comet at a few moments.
    @Test func savesGraphFramesForReview() throws {
        guard let folder = ProcessInfo.processInfo.environment["GRAPH_SHOTS"], !folder.isEmpty else { return }
        let long = session(touches: 433)
        let timeline = MotionStyleTimeline(points: long.points, touchTimes: long.touches)
        for style in [MotionStyle.ballMotion, .comet] {
            for (index, time) in [6.0, 120, long.duration - 1].enumerated() {
                let image = try #require(ExportMotionGraphRenderer.image(style: style,
                    snapshot: timeline.snapshot(at: time, duration: long.duration), size: CGSize(width: 1080, height: 1920)))
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(style.rawValue)-\(index).png")
                let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
        // The same moment the old way, for comparison.
        let whole = MotionStyleSnapshot(timeline: MotionStyleTimeline(points: long.points, touchTimes: Array(long.touches.prefix(30))),
                                        time: 120, duration: long.duration)
        let image = try #require(ExportMotionGraphRenderer.image(style: .ballMotion, snapshot: whole, size: CGSize(width: 1080, height: 1920)))
        let destination = try #require(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: folder).appendingPathComponent("ballMotion-whole-clip.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
