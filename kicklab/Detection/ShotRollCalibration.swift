import CoreGraphics
import Foundation
import simd

/// Edit the selected location in upright image pixels, then save sensor pixels.
nonisolated enum ShotRollCalibrationPointEditing {
    enum Direction: CaseIterable { case up, down, left, right }

    static func uprightSize(_ sensorSize: CGSize, rotation: ShotRollRotation) -> CGSize {
        rotation == .right || rotation == .left
            ? CGSize(width: sensorSize.height, height: sensorSize.width) : sensorSize
    }

    static func uprightPoint(_ sensor: CGPoint, rotation: ShotRollRotation) -> CGPoint {
        let inverse: ShotRollRotation = rotation == .right ? .left : rotation == .left ? .right : rotation
        return inverse.sensorPoint(sensor)
    }

    static func nudged(_ sensor: CGPoint, direction: Direction, imageSize: CGSize,
                       rotation: ShotRollRotation) -> CGPoint? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              sensor.x.isFinite, sensor.y.isFinite,
              (0...1).contains(sensor.x), (0...1).contains(sensor.y) else { return nil }
        let size = uprightSize(imageSize, rotation: rotation)
        var point = uprightPoint(sensor, rotation: rotation)
        switch direction {
        case .up: point.y -= 1 / size.height
        case .down: point.y += 1 / size.height
        case .left: point.x -= 1 / size.width
        case .right: point.x += 1 / size.width
        }
        point.x = min(1, max(0, point.x)); point.y = min(1, max(0, point.y))
        return rotation.sensorPoint(point)
    }
}

/// A setup-specific floor-height fit. Two measured points constrain scale,
/// conditional on the existing camera intrinsics and floor orientation.
/// Fitting this span is not an independent accuracy check.
nonisolated struct ShotRollCalibration: Sendable {
    enum Change: Equatable {
        case floor, cameraPosition, cameraAngle
        var message: String {
            switch self {
            case .floor: "Scanned floor changed — calibrate again"
            case .cameraPosition: "Camera position changed — calibrate again"
            case .cameraAngle: "Camera angle changed — calibrate again"
            }
        }
    }
    enum FitError: LocalizedError {
        case distance, points, geometry, correction, fittedSpan
        var errorDescription: String? {
            switch self {
            case .distance: "Enter the tape-measured spacing, between 0.50 and 10.00 metres."
            case .points: "Tap two separate paper centres inside the image."
            case .geometry: "Both paper centres must be on the same level floor, below the horizon."
            case .correction: "This setup needs a fresh floor scan. Check the paper centres and spacing."
            case .fittedSpan: "Choose a separate measured gap, such as the 1 m to 2 m tapes."
            }
        }
    }

    let id: String
    let referenceDistanceM: Float
    let originalSpanM: Float
    let heightFactor: Float
    let sourceFloor: ShotRollFloor
    let floor: ShotRollFloor
    let camera: simd_float4x4
    let intrinsics: simd_float3x3
    let imageSize: CGSize
    let sensorPoints: [CGPoint]
    let timestamp: Double
    var independentSpanCheck: SpanCheck?

    struct SpanCheck: Sendable {
        let sensorPoints: [CGPoint]
        let referenceDistanceM: Float
        let estimatedDistanceM: Float
        var errorM: Float { estimatedDistanceM - referenceDistanceM }
        // An experimental setup check, not an accuracy claim for all distances.
        var toleranceM: Float { max(0.1, referenceDistanceM * 0.05) }
        var withinTolerance: Bool { abs(errorM) <= toleranceM }
    }

    /// Check a held-out span without changing the fitted floor or scale.
    func checkSpan(sensorPoints points: [CGPoint], referenceDistanceM: Float) throws -> SpanCheck {
        guard referenceDistanceM.isFinite, (0.5...10).contains(referenceDistanceM) else { throw FitError.distance }
        guard points.count == 2, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            (0...1).contains($0.x) && (0...1).contains($0.y) }) else { throw FitError.points }
        func pixelDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot((a.x - b.x) * imageSize.width, (a.y - b.y) * imageSize.height)
        }
        guard pixelDistance(points[0], points[1]) >= 40 else { throw FitError.points }
        let sameOrder = pixelDistance(points[0], sensorPoints[0]) < 10 && pixelDistance(points[1], sensorPoints[1]) < 10
        let reverseOrder = pixelDistance(points[0], sensorPoints[1]) < 10 && pixelDistance(points[1], sensorPoints[0]) < 10
        guard !sameOrder && !reverseOrder else { throw FitError.fittedSpan }
        guard let a = Self.groundPoint(points[0], imageSize: imageSize, intrinsics: intrinsics, camera: camera, floor: floor),
              let b = Self.groundPoint(points[1], imageSize: imageSize, intrinsics: intrinsics, camera: camera, floor: floor) else {
            throw FitError.geometry
        }
        let distance = simd_distance(a, b)
        guard distance.isFinite, distance > 0 else { throw FitError.geometry }
        return SpanCheck(sensorPoints: points, referenceDistanceM: referenceDistanceM, estimatedDistanceM: distance)
    }

    static func fit(sensorPoints: [CGPoint], referenceDistanceM: Float,
                    imageSize: CGSize, intrinsics: simd_float3x3,
                    camera: simd_float4x4, floor: ShotRollFloor,
                    timestamp: Double) throws -> Self {
        guard referenceDistanceM.isFinite, (0.5...10).contains(referenceDistanceM) else {
            throw FitError.distance
        }
        guard sensorPoints.count == 2,
              sensorPoints.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) }),
              imageSize.width > 0, imageSize.height > 0 else { throw FitError.points }
        let dx = (sensorPoints[0].x - sensorPoints[1].x) * imageSize.width
        let dy = (sensorPoints[0].y - sensorPoints[1].y) * imageSize.height
        guard hypot(dx, dy) >= 40 else { throw FitError.points }
        guard floor.normal.y >= 0.98, timestamp.isFinite,
              let a = groundPoint(sensorPoints[0], imageSize: imageSize,
                  intrinsics: intrinsics, camera: camera, floor: floor),
              let b = groundPoint(sensorPoints[1], imageSize: imageSize,
                  intrinsics: intrinsics, camera: camera, floor: floor) else { throw FitError.geometry }
        let span = simd_distance(a, b)
        let factor = referenceDistanceM / span
        let height = floor.cameraHeight(camera) * factor
        guard span.isFinite, span > 0, factor.isFinite, (0.5...2).contains(factor),
              height.isFinite, (0.3...3).contains(height) else { throw FitError.correction }
        // Change only the floor offset; leave camera rays and its pose intact.
        var corrected = floor.worldFromPlane
        let shift = floor.cameraHeight(camera) - height
        corrected.columns.3 += SIMD4(floor.normal * shift, 0)
        return Self(id: UUID().uuidString, referenceDistanceM: referenceDistanceM,
            originalSpanM: span, heightFactor: factor, sourceFloor: floor,
            floor: ShotRollFloor(id: floor.id, worldFromPlane: corrected, boundary: floor.boundary),
            camera: camera, intrinsics: intrinsics, imageSize: imageSize,
            sensorPoints: sensorPoints, timestamp: timestamp)
    }

    /// Continuous normalized sensor pixels, top-left origin, CV camera axes.
    static func groundPoint(_ point: CGPoint, imageSize: CGSize,
                            intrinsics: simd_float3x3, camera: simd_float4x4,
                            floor: ShotRollFloor) -> SIMD3<Float>? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              abs(intrinsics.determinant) > 1e-6 else { return nil }
        let ray = intrinsics.inverse * SIMD3(Float(point.x * imageSize.width),
                                            Float(point.y * imageSize.height), 1)
        let rotation = simd_float3x3(columns: (xyz(camera.columns.0),
            xyz(camera.columns.1), xyz(camera.columns.2)))
        let direction = rotation * simd_normalize(ray)
        let denominator = simd_dot(floor.normal, direction)
        let height = floor.cameraHeight(camera)
        guard height.isFinite, height > 0, denominator.isFinite, denominator < -0.03 else { return nil }
        let world = xyz(camera.columns.3) - height / denominator * direction
        return [world.x, world.y, world.z].allSatisfy(\.isFinite) ? world : nil
    }

    /// A fixed-phone experiment, not a calibration that follows a moving camera.
    func matches(camera current: simd_float4x4, floor mapped: ShotRollFloor) -> Bool {
        change(camera: current, floor: mapped) == nil
    }

    func change(camera current: simd_float4x4, floor mapped: ShotRollFloor) -> Change? {
        guard mapped.stableRelative(to: sourceFloor) else { return .floor }
        guard simd_distance(Self.xyz(current.columns.3), Self.xyz(camera.columns.3)) <= 0.03 else { return .cameraPosition }
        let reference = simd_float3x3(columns: (Self.xyz(camera.columns.0), Self.xyz(camera.columns.1), Self.xyz(camera.columns.2)))
        let rotation = simd_float3x3(columns: (Self.xyz(current.columns.0), Self.xyz(current.columns.1), Self.xyz(current.columns.2)))
        let delta = reference.transpose * rotation
        let cosine = (delta[0][0] + delta[1][1] + delta[2][2] - 1) / 2
        return cosine.isFinite && cosine >= cos(Float(2) * .pi / 180) ? nil : .cameraAngle
    }

    private static func xyz(_ value: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3(value.x, value.y, value.z)
    }
}
