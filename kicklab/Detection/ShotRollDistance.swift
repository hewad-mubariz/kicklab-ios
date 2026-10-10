import CoreGraphics
import Foundation
import ImageIO
import simd

nonisolated private func rollXYZ(_ value: SIMD4<Float>) -> SIMD3<Float> {
    SIMD3(value.x, value.y, value.z)
}

/// Experimental ground-contact geometry, conditional on a spherical rolling ball.
/// A model box is only an approximate silhouette; this never validates scale or speed.
nonisolated enum ShotRollRotation: Int, CaseIterable, Sendable {
    case up = 0, right = 90, down = 180, left = 270

    var imageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .right: .right
        case .down: .down
        case .left: .left
        }
    }

    static func upright(worldFromCamera: simd_float4x4) -> Self {
        let rotation = simd_float3x3(columns: (rollXYZ(worldFromCamera.columns.0),
            rollXYZ(worldFromCamera.columns.1), rollXYZ(worldFromCamera.columns.2)))
        let gravity = rotation.transpose * SIMD3<Float>(0, -1, 0)
        let angle = atan2(gravity.y, gravity.x) * 180 / .pi
        let degrees = Int(((90 - angle) / 90).rounded()) * 90
        return Self(rawValue: (degrees % 360 + 360) % 360) ?? .up
    }

    /// Normalized continuous image coordinates, with a top-left origin.
    func sensorPoint(_ upright: CGPoint) -> CGPoint {
        switch self {
        case .up: upright
        case .right: CGPoint(x: upright.y, y: 1 - upright.x)
        case .down: CGPoint(x: 1 - upright.x, y: 1 - upright.y)
        case .left: CGPoint(x: 1 - upright.y, y: upright.x)
        }
    }

    func sensorRect(_ upright: CGRect) -> CGRect {
        let corners = [CGPoint(x: upright.minX, y: upright.minY),
            CGPoint(x: upright.maxX, y: upright.minY),
            CGPoint(x: upright.maxX, y: upright.maxY),
            CGPoint(x: upright.minX, y: upright.maxY)].map(sensorPoint)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
            width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

nonisolated struct ShotRollFloor: Sendable {
    let id: String
    let worldFromPlane: simd_float4x4
    let boundary: [SIMD3<Float>]

    var normal: SIMD3<Float> { simd_normalize(rollXYZ(worldFromPlane.columns.1)) }
    var offset: Float { simd_dot(normal, rollXYZ(worldFromPlane.columns.3)) }

    func cameraHeight(_ worldFromCamera: simd_float4x4) -> Float {
        simd_dot(normal, rollXYZ(worldFromCamera.columns.3)) - offset
    }

    func contains(_ point: SIMD3<Float>) -> Bool {
        guard boundary.count >= 3 else { return false }
        let local = worldFromPlane.inverse * SIMD4(point, 1)
        var inside = false
        for i in boundary.indices {
            let a = boundary[i], b = boundary[(i + 1) % boundary.count]
            let edge = SIMD2(b.x - a.x, b.z - a.z)
            let delta = SIMD2(local.x - a.x, local.z - a.z)
            let lengthSquared = simd_length_squared(edge)
            if lengthSquared > 0 {
                let t = max(0, min(1, simd_dot(delta, edge) / lengthSquared))
                if simd_length(delta - t * edge) < 0.001 { return true }
            }
            if (a.z > local.z) != (b.z > local.z),
               local.x < (b.x - a.x) * (local.z - a.z) / (b.z - a.z) + a.x {
                inside.toggle()
            }
        }
        return inside
    }

    func stableRelative(to previous: Self) -> Bool {
        id == previous.id && abs(offset - previous.offset) <= 0.04 &&
            simd_length(normal - previous.normal) <= 0.02
    }
}

nonisolated enum ShotRollGeometry {
    struct Projection: Sendable {
        let worldContact: SIMD3<Float>
        let sensorContact: CGPoint
        let radiusM: Float
        let cameraHeightM: Float
        let edgeRMSPixels: Float
        let insideMappedFloor: Bool
    }

    /// Four tangent-edge planes determine a sphere centre in radius units.
    /// Floor tangency then eliminates unknown ball radius. Adapted from the
    /// measured rolling-reference lab method, not a box-bottom raycast.
    static func project(sensorBounds bounds: CGRect, imageSize: CGSize,
                        intrinsics k: simd_float3x3, worldFromCamera camera: simd_float4x4,
                        floor: ShotRollFloor) -> Projection? {
        let edges = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]
        guard edges.allSatisfy(\.isFinite), imageSize.width > 0, imageSize.height > 0,
              bounds.width >= 4, bounds.height >= 4,
              bounds.minX > 1, bounds.minY > 1,
              bounds.maxX < imageSize.width - 1, bounds.maxY < imageSize.height - 1,
              k.columns.0.x > 0, k.columns.1.y > 0,
              abs(k.columns.1.x) < 1e-5, abs(k.columns.0.y) < 1e-5,
              floor.normal.y >= 0.98 else { return nil }
        let height = floor.cameraHeight(camera)
        guard height.isFinite, (0.3...3).contains(height) else { return nil }
        let left = (Float(bounds.minX) - k.columns.2.x) / k.columns.0.x
        let right = (Float(bounds.maxX) - k.columns.2.x) / k.columns.0.x
        let top = (Float(bounds.minY) - k.columns.2.y) / k.columns.1.y
        let bottom = (Float(bounds.maxY) - k.columns.2.y) / k.columns.1.y
        let tangents = [SIMD3<Float>(1, 0, -left), SIMD3<Float>(1, 0, -right),
                        SIMD3<Float>(0, 1, -top), SIMD3<Float>(0, 1, -bottom)]
        let target: [Float] = [hypot(1, left), -hypot(1, right),
                              hypot(1, top), -hypot(1, bottom)]
        var normalMatrix = simd_float3x3(0)
        var rhs = SIMD3<Float>(repeating: 0)
        for (a, b) in zip(tangents, target) {
            for column in 0..<3 { normalMatrix[column] += a * a[column] }
            rhs += a * b
        }
        guard abs(normalMatrix.determinant) > 1e-9 else { return nil }
        let centrePerRadius = normalMatrix.inverse * rhs
        let rotation = simd_float3x3(columns: (rollXYZ(camera.columns.0),
            rollXYZ(camera.columns.1), rollXYZ(camera.columns.2)))
        let normalCamera = rotation.transpose * floor.normal
        let denominator = 1 - simd_dot(normalCamera, centrePerRadius)
        guard denominator.isFinite, denominator > 1e-5, centrePerRadius.z > 1 else { return nil }
        let radius = height / denominator
        let centre = radius * centrePerRadius
        let contact = centre - radius * normalCamera
        guard radius.isFinite, (0.025...0.35).contains(radius), contact.z > 0,
              [contact.x, contact.y, contact.z].allSatisfy(\.isFinite) else { return nil }
        // A loose fit check rejects non-spherical or truncated detections. It
        // cannot establish that a ball is on the floor rather than airborne.
        func limits(_ lateral: Float, focal: Float, principal: Float) -> (Float, Float)? {
            let z = centre.z, square = z * z - radius * radius
            let radical = lateral * lateral + square
            guard square > 0, radical > 0 else { return nil }
            let spread = radius * sqrt(radical)
            return (focal * (lateral * z - spread) / square + principal,
                    focal * (lateral * z + spread) / square + principal)
        }
        guard let x = limits(centre.x, focal: k.columns.0.x, principal: k.columns.2.x),
              let y = limits(centre.y, focal: k.columns.1.y, principal: k.columns.2.y) else { return nil }
        let predicted = [x.0, y.0, x.1, y.1]
        var squaredError: Float = 0
        for (predictedEdge, observedEdge) in zip(predicted, edges) {
            let error = predictedEdge - Float(observedEdge)
            squaredError += error * error
        }
        let rms = sqrt(squaredError / 4)
        guard rms.isFinite, rms <= max(3, Float(min(bounds.width, bounds.height)) * 0.12) else { return nil }
        let pixel = k * contact
        let world = rollXYZ(camera.columns.3) + rotation * contact
        return Projection(worldContact: world,
            sensorContact: CGPoint(x: CGFloat(pixel.x / pixel.z), y: CGFloat(pixel.y / pixel.z)),
            radiusM: radius, cameraHeightM: height, edgeRMSPixels: rms,
            insideMappedFloor: floor.contains(world))
    }
}

/// A short linear fit of ground contacts against capture timestamps. This is
/// smoothed rolling speed, never launch speed or independently validated scale.
nonisolated struct ShotRollSpeedEstimator {
    static let windowS: Double = 0.6
    static let minimumSpanS: Double = 0.5
    // A 30 fps capture submitted every fourth frame supplies five contacts in
    // this window. Keep elapsed-time and quality gates instead of requiring
    // six contacts that can never coexist at that valid sampling cadence.
    static let minimumSamples = 5
    static let maximumGapS: Double = 0.25
    static let maximumSpeedMPS: Float = 6
    private struct Sample { let point: SIMD3<Float>; let time: Double }
    private var samples: [Sample] = []
    private(set) var speedKMH: Float?
    private(set) var peakKMH: Float?
    private(set) var fitRMSM: Float?
    private(set) var spanS: Double = 0
    var sampleCount: Int { samples.count }
    private(set) var status = "Collecting motion…"

    mutating func reset() { self = Self() }

    mutating func observe(point: SIMD3<Float>, time: Double) {
        speedKMH = nil; fitRMSM = nil; spanS = 0
        guard time.isFinite, [point.x, point.y, point.z].allSatisfy(\.isFinite) else {
            samples = []; status = "Motion unclear — keep the ball visible"; return
        }
        if let last = samples.last {
            let dt = time - last.time
            if dt <= 0 { samples = []; status = "Collecting fresh motion…"; return }
            if dt > Self.maximumGapS { samples = [] }
        }
        samples.append(Sample(point: point, time: time))
        samples.removeAll { time - $0.time > Self.windowS + 1e-6 }
        // Also bound work under unexpected callback rates.
        if samples.count > 32 { samples.removeFirst(samples.count - 32) }
        status = "Collecting motion…"
        guard let first = samples.first else { return }
        spanS = time - first.time
        guard samples.count >= Self.minimumSamples else { return }
        guard spanS + 1e-6 >= Self.minimumSpanS else { return }
        if samples.count == Self.minimumSamples {
            // Five contacts can support a steady lower cadence, but a missed
            // callback at a higher cadence must still collect a sixth contact.
            let denseGapS = Self.windowS / Double(Self.minimumSamples - 1)
            guard zip(samples, samples.dropFirst()).allSatisfy({
                $1.time - $0.time <= denseGapS + 1e-6
            }) else { return }
        }
        let count = Float(samples.count)
        let meanTime = samples.reduce(0.0) { $0 + ($1.time - first.time) } / Double(samples.count)
        let meanPoint = samples.reduce(SIMD3<Float>(repeating: 0)) { $0 + $1.point } / count
        var numerator = SIMD3<Float>(repeating: 0)
        var denominator: Float = 0
        for sample in samples {
            let t = Float(sample.time - first.time - meanTime)
            numerator += t * (sample.point - meanPoint); denominator += t * t
        }
        guard denominator > 1e-8 else { return }
        let velocity = numerator / denominator
        let squaredError = samples.reduce(Float(0)) { total, sample in
            let t = Float(sample.time - first.time - meanTime)
            return total + simd_length_squared(sample.point - meanPoint - velocity * t)
        }
        let rms = sqrt(squaredError / count)
        fitRMSM = rms
        guard rms.isFinite, rms <= 0.025 else {
            status = "Motion unclear — keep the ball visible"; return
        }
        let speed = simd_length(velocity)
        guard speed.isFinite, speed <= Self.maximumSpeedMPS else {
            status = "Roll too fast for this experiment"; return
        }
        // Do not turn small stationary box jitter into apparent motion.
        let estimate: Float = speed * Float(spanS) < 0.03 ? 0 : speed * 3.6
        speedKMH = estimate; peakKMH = max(peakKMH ?? 0, estimate)
        status = "Smoothed rolling estimate"
    }
}

/// Endpoint displacement, not accumulated path length. Stationary box jitter
/// therefore cannot add metres to a roll. Lost samples never invent motion.
nonisolated struct ShotRollTracker {
    private(set) var origin: SIMD3<Float>?
    private(set) var distanceM: Float?
    private(set) var needsNewStart = false
    private var lastPoint: SIMD3<Float>?
    private var lastTime: Double?
    private var hasLeftStartArea = false
    private(set) var recoveredPreRollGapS: Double?
    private(set) var speed = ShotRollSpeedEstimator()

    mutating func reset() { self = Self() }

    mutating func arm(point: SIMD3<Float>, time: Double) {
        origin = point; lastPoint = point; lastTime = time
        distanceM = 0; needsNewStart = false
        hasLeftStartArea = false; recoveredPreRollGapS = nil
        speed.reset(); speed.observe(point: point, time: time)
    }

    mutating func invalidate() {
        needsNewStart = true; recoveredPreRollGapS = nil; speed.reset()
    }

    mutating func observe(point: SIMD3<Float>, time: Double) -> Bool {
        recoveredPreRollGapS = nil
        guard let origin, !needsNewStart, time.isFinite,
              [point.x, point.y, point.z].allSatisfy(\.isFinite) else { return false }
        let distance = simd_distance(point, origin)
        if let lastTime, let lastPoint {
            let dt = time - lastTime
            guard dt > 0 else { return false }
            let step = simd_distance(point, lastPoint)
            // A hand can briefly hide the resting ball before the push. Only
            // recover near the original start, before leaving that area; never
            // bridge missing motion or keep an old speed window across the gap.
            let recoverAtStart = dt > 0.8 && dt <= 2 && !hasLeftStartArea
                && distance <= 0.08 && simd_distance(lastPoint, origin) <= 0.08
                && step <= 0.03
            guard (dt <= 0.8 || recoverAtStart), step <= Float(dt) * 6 + 0.12 else {
                invalidate(); return false
            }
            if recoverAtStart {
                // observe below clears the live window for this gap while
                // retaining any historical supported peak.
                recoveredPreRollGapS = dt
            }
        }
        distanceM = distance
        lastPoint = point; lastTime = time
        speed.observe(point: point, time: time)
        if distance > 0.08 { hasLeftStartArea = true }
        return true
    }
}

nonisolated struct ShotRollDisplay: Sendable {
    var calibrated = false
    var requiresCalibration = false
    var distanceM: Float?
    var speedKMH: Float?
    var peakRollingSpeedKMH: Float?
    var speedStatus = "Set start to estimate speed"
    var status = "Finding the ball — keep it visible"
    var isLive = false
    var canSetStart = false
    var outsideMappedFloor = false
    var sensorBallRect: CGRect?
    var sensorContact: CGPoint?
    var sampleTimestamp: Double?
    var trial = 0

    mutating func markCalibrationLost(_ reason: String) {
        requiresCalibration = true; calibrated = false
        isLive = false; canSetStart = false
        sensorBallRect = nil; sensorContact = nil
        speedKMH = nil; peakRollingSpeedKMH = nil
        speedStatus = "Recalibrate to estimate speed"
        status = reason
    }
}
