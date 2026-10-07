import XCTest
import UIKit
import simd
@testable import kicklab

final class ShotRollCalibrationTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1440)
    private let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))

    private func camera(roll: Float = 0, pitch: Float = 0) -> simd_float4x4 {
        let base = simd_float3x3(diagonal: SIMD3<Float>(1, -1, -1))
        let rotation = simd_float3x3(simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))) * base *
            simd_float3x3(simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)))
        return simd_float4x4(columns: (SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0), SIMD4(0, 0.84, 0, 1)))
    }
    private func floor(offset: Float) -> ShotRollFloor {
        var pose = matrix_identity_float4x4; pose.columns.3.y = offset
        return ShotRollFloor(id: "floor", worldFromPlane: pose,
            boundary: [SIMD3(-5, 0, -10), SIMD3(5, 0, -10), SIMD3(5, 0, 1), SIMD3(-5, 0, 1)])
    }
    private func pixel(_ world: SIMD3<Float>, camera: simd_float4x4) -> CGPoint {
        let p = camera.inverse * SIMD4(world, 1)
        let image = k * SIMD3(p.x, p.y, p.z)
        return CGPoint(x: CGFloat(image.x / image.z) / size.width,
                       y: CGFloat(image.y / image.z) / size.height)
    }
    private func fit(pose: simd_float4x4, offset: Float = -0.2) throws -> ShotRollCalibration {
        try ShotRollCalibration.fit(sensorPoints: [pixel(SIMD3(0, 0, -2), camera: pose),
            pixel(SIMD3(0, 0, -5), camera: pose)], referenceDistanceM: 3,
            imageSize: size, intrinsics: k, camera: pose, floor: floor(offset: offset), timestamp: 10)
    }

    func testPrecisionArrowsMoveOneVisibleImagePixelAcrossAllRotations() throws {
        let original = CGPoint(x: 0.37, y: 0.61)
        let steps: [(ShotRollCalibrationPointEditing.Direction, CGPoint,
                     ShotRollCalibrationPointEditing.Direction)] = [
            (.up, CGPoint(x: 0, y: -1), .down), (.down, CGPoint(x: 0, y: 1), .up),
            (.left, CGPoint(x: -1, y: 0), .right), (.right, CGPoint(x: 1, y: 0), .left)
        ]
        for rotation in ShotRollRotation.allCases {
            let uprightSize = ShotRollCalibrationPointEditing.uprightSize(size, rotation: rotation)
            let before = ShotRollCalibrationPointEditing.uprightPoint(original, rotation: rotation)
            for (direction, delta, reverse) in steps {
                let adjusted = try XCTUnwrap(ShotRollCalibrationPointEditing.nudged(original,
                    direction: direction, imageSize: size, rotation: rotation))
                let after = ShotRollCalibrationPointEditing.uprightPoint(adjusted, rotation: rotation)
                XCTAssertEqual((after.x - before.x) * uprightSize.width, delta.x, accuracy: 1e-9)
                XCTAssertEqual((after.y - before.y) * uprightSize.height, delta.y, accuracy: 1e-9)
                XCTAssertEqual(hypot((adjusted.x - original.x) * size.width,
                    (adjusted.y - original.y) * size.height), 1, accuracy: 1e-9)
                let restored = try XCTUnwrap(ShotRollCalibrationPointEditing.nudged(adjusted,
                    direction: reverse, imageSize: size, rotation: rotation))
                XCTAssertEqual(restored.x, original.x, accuracy: 1e-12)
                XCTAssertEqual(restored.y, original.y, accuracy: 1e-12)
            }
            for (direction, edge) in [(ShotRollCalibrationPointEditing.Direction.up, CGPoint(x: 0.5, y: 0)),
                (.down, CGPoint(x: 0.5, y: 1)), (.left, CGPoint(x: 0, y: 0.5)), (.right, CGPoint(x: 1, y: 0.5))] {
                let sensor = rotation.sensorPoint(edge)
                let clamped = try XCTUnwrap(ShotRollCalibrationPointEditing.nudged(sensor,
                    direction: direction, imageSize: size, rotation: rotation))
                XCTAssertEqual(clamped.x, sensor.x, accuracy: 1e-12)
                XCTAssertEqual(clamped.y, sensor.y, accuracy: 1e-12)
            }
        }
        for invalidSize in [CGSize.zero, CGSize(width: -1, height: 1), CGSize(width: CGFloat.nan, height: 1)] {
            XCTAssertNil(ShotRollCalibrationPointEditing.nudged(original,
                direction: .up, imageSize: invalidSize, rotation: .up))
        }
        for invalidPoint in [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: -0.1, y: 0), CGPoint(x: 1.1, y: 0)] {
            XCTAssertNil(ShotRollCalibrationPointEditing.nudged(invalidPoint,
                direction: .up, imageSize: size, rotation: .up))
        }
    }

    @MainActor
    func testLoupeShowsTheSelectedSensorPixelAcrossAllRotations() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let sensorSize = CGSize(width: 8, height: 6)
        let raw = UIGraphicsImageRenderer(size: sensorSize, format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(origin: .zero, size: sensorSize))
            UIColor.green.setFill(); UIRectFill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
        let sensor = CGPoint(x: 1.5 / 8, y: 1.5 / 6)
        let orientations: [(ShotRollRotation, UIImage.Orientation)] = [
            (.up, .up), (.right, .right), (.down, .down), (.left, .left)
        ]
        for (rotation, orientation) in orientations {
            let view = CalibrationPointLoupeView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            view.image = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: orientation)
            view.photoSize = ShotRollCalibrationPointEditing.uprightSize(sensorSize, rotation: rotation)
            view.point = ShotRollCalibrationPointEditing.uprightPoint(sensor, rotation: rotation)
            let rendered = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
                view.draw(view.bounds)
            }
            // The crosshair leaves a central gap so it cannot hide the selected pixel.
            var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
            try bytes.withUnsafeMutableBytes { storage in
                let bitmap = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 100, height: 100,
                    bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                bitmap.draw(try XCTUnwrap(rendered.cgImage), in: view.bounds)
            }
            let centre = (50 * 100 + 50) * 4
            XCTAssertLessThan(bytes[centre], 10, "Unexpected red at \(rotation)")
            XCTAssertGreaterThan(bytes[centre + 1], 245, "Selected pixel missing at \(rotation)")
            XCTAssertLessThan(bytes[centre + 2], 10, "Unexpected blue at \(rotation)")
        }
    }

    func testFittedFloorRecoversSeparateOneAndTwoMetrePointsAcrossRotations() throws {
        for roll: Float in [0, .pi/2, .pi, -.pi/2] {
            let pose = camera(roll: roll, pitch: -.pi/12)
            let result = try fit(pose: pose)
            XCTAssertEqual(result.originalSpanM, 3 * 1.04 / 0.84, accuracy: 0.001)
            XCTAssertEqual(result.floor.cameraHeight(pose), 0.84, accuracy: 0.001)
            // These interior points were NOT used to fit the height.
            for distance: Float in [1, 2] {
                let actual = SIMD3<Float>(0, 0, -2 - distance)
                let recovered = try XCTUnwrap(ShotRollCalibration.groundPoint(pixel(actual, camera: pose),
                    imageSize: size, intrinsics: k, camera: pose, floor: result.floor))
                XCTAssertLessThan(simd_distance(recovered, actual), 0.001)
            }
        }
    }

    func testBallContactUsesFittedFloorRatherThanMultiplyingTheDisplay() throws {
        let pose = camera(), result = try fit(pose: pose)
        let actual = SIMD3<Float>(0.1, 0, -4), radius: Float = 0.11
        let centre = pose.inverse * SIMD4(actual + SIMD3(0, radius, 0), 1)
        func limits(_ lateral: Float, principal: Float) -> (CGFloat, CGFloat) {
            let denominator = centre.z * centre.z - radius * radius
            let spread = radius * sqrt(lateral * lateral + denominator)
            return (CGFloat(1000 * (lateral * centre.z - spread) / denominator + principal),
                    CGFloat(1000 * (lateral * centre.z + spread) / denominator + principal))
        }
        let x = limits(centre.x, principal: 960), y = limits(centre.y, principal: 720)
        let projection = try XCTUnwrap(ShotRollGeometry.project(
            sensorBounds: CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0),
            imageSize: size, intrinsics: k, worldFromCamera: pose, floor: result.floor))
        XCTAssertLessThan(simd_distance(projection.worldContact, actual), 0.001)
        XCTAssertEqual(projection.radiusM, radius, accuracy: 0.001)
    }

    func testCameraTranslationRotationAndFloorChangesInvalidateCalibration() throws {
        let pose = camera(), result = try fit(pose: pose)
        XCTAssertTrue(result.matches(camera: pose, floor: floor(offset: -0.2)))
        var moved = pose; moved.columns.3.x += 0.04
        XCTAssertFalse(result.matches(camera: moved, floor: floor(offset: -0.2)))
        XCTAssertEqual(result.change(camera: moved, floor: floor(offset: -0.2)), .cameraPosition)
        // Rotation around the viewing axis must also invalidate; a check of
        // forward direction alone would miss this change.
        XCTAssertFalse(result.matches(camera: camera(roll: .pi/30), floor: floor(offset: -0.2)))
        XCTAssertEqual(result.change(camera: camera(roll: .pi/30), floor: floor(offset: -0.2)), .cameraAngle)
        XCTAssertFalse(result.matches(camera: pose, floor: floor(offset: -0.3)))
        XCTAssertEqual(result.change(camera: pose, floor: floor(offset: -0.3)), .floor)
        let other = ShotRollFloor(id: "other", worldFromPlane: result.sourceFloor.worldFromPlane, boundary: result.sourceFloor.boundary)
        XCTAssertFalse(result.matches(camera: pose, floor: other))
    }

    func testCalibrationLossBlocksLiveDisplayAndRetainsOnlyDiagnosticLastValue() {
        var state = ShotRollDisplay()
        state.calibrated = true; state.distanceM = 0.000431
        state.isLive = true; state.canSetStart = true
        state.sensorContact = CGPoint(x: 0.5, y: 0.6)
        state.sensorBallRect = CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2)
        state.markCalibrationLost("Camera angle changed")
        XCTAssertTrue(state.requiresCalibration)
        XCTAssertFalse(state.calibrated)
        XCTAssertFalse(state.isLive)
        XCTAssertFalse(state.canSetStart)
        XCTAssertNil(state.sensorContact)
        XCTAssertNil(state.sensorBallRect)
        XCTAssertEqual(state.distanceM, 0.000431)
        XCTAssertEqual(state.status, "Camera angle changed")
        XCTAssertFalse(ShotRollDisplay().requiresCalibration)
    }

    func testInvalidSpacingAndPointsCannotCreateCalibration() {
        let pose = camera()
        let points = [pixel(SIMD3(0, 0, -2), camera: pose), pixel(SIMD3(0, 0, -5), camera: pose)]
        for distance: Float in [.nan, .infinity, 0, -1, 0.49, 10.01, 9] {
            XCTAssertThrowsError(try ShotRollCalibration.fit(sensorPoints: points,
                referenceDistanceM: distance, imageSize: size, intrinsics: k,
                camera: pose, floor: floor(offset: -0.2), timestamp: 10))
        }
        for badPoints in [[], [points[0]], [points[0], points[0]], [CGPoint(x: -0.1, y: 0.8), points[1]],
                          [CGPoint(x: 0.4, y: 0.1), CGPoint(x: 0.5, y: 0.2)]] {
            XCTAssertThrowsError(try ShotRollCalibration.fit(sensorPoints: badPoints,
                referenceDistanceM: 3, imageSize: size, intrinsics: k,
                camera: pose, floor: floor(offset: -0.2), timestamp: 10))
        }
    }

    func testKnownSpanCannotProveAnIncorrectFloorOrientation() throws {
        let pose = camera()
        var tilted = floor(offset: -0.2).worldFromPlane
        let rotation = simd_float3x3(simd_quatf(angle: 0.03, axis: SIMD3(1, 0, 0)))
        for i in 0..<3 { tilted[i] = SIMD4(rotation[i], 0) }
        let wrongFloor = ShotRollFloor(id: "floor", worldFromPlane: tilted, boundary: [])
        let result = try ShotRollCalibration.fit(sensorPoints: [pixel(SIMD3(0, 0, -2), camera: pose),
            pixel(SIMD3(0, 0, -5), camera: pose)], referenceDistanceM: 3,
            imageSize: size, intrinsics: k, camera: pose, floor: wrongFloor, timestamp: 10)
        let a = try XCTUnwrap(ShotRollCalibration.groundPoint(pixel(SIMD3(0, 0, -2), camera: pose),
            imageSize: size, intrinsics: k, camera: pose, floor: result.floor))
        let b = try XCTUnwrap(ShotRollCalibration.groundPoint(pixel(SIMD3(0, 0, -5), camera: pose),
            imageSize: size, intrinsics: k, camera: pose, floor: result.floor))
        XCTAssertEqual(simd_distance(a, b), 3, accuracy: 0.001)
        let middle = try XCTUnwrap(ShotRollCalibration.groundPoint(pixel(SIMD3(0, 0, -3), camera: pose),
            imageSize: size, intrinsics: k, camera: pose, floor: result.floor))
        XCTAssertGreaterThan(abs(simd_distance(a, middle) - 1), 0.01)
    }
}
