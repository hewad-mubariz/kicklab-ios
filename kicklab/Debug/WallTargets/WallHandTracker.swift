#if DEBUG
import CoreGraphics
import Foundation
import Vision

nonisolated enum WallHandState: Int, Sendable { case unknown = 0, held = 1, clear = 2 }

/// One analysis-queue owner. Body wrists run at up to 12.5 Hz; their locations
/// are compared with each current ball box, never reused beyond 150 ms.
nonisolated final class WallHandTracker {
    private let request = VNDetectHumanBodyPoseRequest()
    private var lastAttempt = -Double.infinity
    private(set) var snapshot: Snapshot?

    struct Snapshot: Sendable {
        let t: Double
        let wrists: [CGPoint] // normalised, top-left origin
        let personCount: Int
        var bodies: [CGRect] = [] // full-frame pose bounds, never a cropped RF person box

        func state(ball: CGPoint, diameter: Double, aspect: Double, person: CGRect?, now: Double) -> WallHandState {
            guard now >= t, now - t <= 0.15, diameter > 0 else { return .unknown }
            let distance = wrists.map { hypot(($0.x - ball.x) * aspect, $0.y - ball.y) / diameter }.min()
            if let distance, distance <= 1.1 { return .held }
            if let person, !person.insetBy(dx: -diameter / aspect, dy: -diameter).contains(ball) {
                return .clear // A missing wrist on a distant body cannot veto this ball.
            }
            if person == nil, personCount > 0, bodies.count == personCount,
               bodies.allSatisfy({ !$0.insetBy(dx: -diameter / aspect, dy: -diameter).contains(ball) }) {
                return .clear
            }
            // Missing wrists in an overlapping body are unknown, not evidence of release.
            if let person, person.insetBy(dx: -diameter / aspect, dy: -diameter).contains(ball),
               wrists.count < max(2, personCount * 2) { return .unknown }
            if wrists.count < personCount * 2 { return .unknown }
            return .clear
        }
    }

    func reset() { lastAttempt = -.infinity; snapshot = nil }

    @discardableResult
    func observe(_ pixels: CVPixelBuffer, at t: Double) -> Bool {
        guard t - lastAttempt >= 0.08 else { return false }
        lastAttempt = t
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
            let people = request.results ?? []
            var wrists: [CGPoint] = []
            var bodies: [CGRect] = []
            for person in people {
                let points = try person.recognizedPoints(.all)
                let visible = points.values.filter { $0.confidence >= 0.3 }
                    .map { CGPoint(x: $0.location.x, y: 1 - $0.location.y) }
                if visible.count >= 5 {
                    let xs = visible.map(\.x), ys = visible.map(\.y)
                    bodies.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
                }
                for joint in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
                    if let p = points[joint], p.confidence >= 0.3 {
                        wrists.append(CGPoint(x: p.location.x, y: 1 - p.location.y))
                    }
                }
            }
            snapshot = .init(t: t, wrists: wrists, personCount: people.count, bodies: bodies)
        } catch { snapshot = nil }
        return true
    }

    func state(ball: CGPoint, diameter: Double, aspect: Double, person: CGRect?, at t: Double) -> WallHandState {
        snapshot?.state(ball: ball, diameter: diameter, aspect: aspect, person: person, now: t) ?? .unknown
    }
}
#endif
