import XCTest
import simd
@testable import kicklab

final class ShotRollDistanceTests: XCTestCase {
    private let size = CGSize(width: 1920, height: 1440)
    private let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))

    private func camera(height: Float = 0.84, roll: Float = 0, tilt: Float = 0) -> simd_float4x4 {
        let base = simd_float3x3(diagonal: SIMD3<Float>(1, -1, -1))
        let turn = simd_float3x3(simd_quatf(angle: roll, axis: SIMD3(0, 0, 1)))
        let pitch = simd_float3x3(simd_quatf(angle: tilt, axis: SIMD3(1, 0, 0)))
        let rotation = pitch * base * turn
        return simd_float4x4(columns: (SIMD4(rotation.columns.0, 0), SIMD4(rotation.columns.1, 0),
            SIMD4(rotation.columns.2, 0), SIMD4(0, height, 0, 1)))
    }

    private func floor(depth: Float = 8, offset: Float = 0) -> ShotRollFloor {
        var pose = matrix_identity_float4x4; pose.columns.3.y = offset
        return ShotRollFloor(id: "floor", worldFromPlane: pose,
            boundary: [SIMD3(-5, 0, -depth), SIMD3(5, 0, -depth), SIMD3(5, 0, 1), SIMD3(-5, 0, 1)])
    }

    // Analytic pinhole silhouette of a sphere whose physical centre/radius are
    // known independently of the estimator. This also covers camera tilt/roll.
    private func sphereBounds(contact: SIMD3<Float>, camera: simd_float4x4, radius: Float = 0.11) -> CGRect {
        let worldCentre = contact + SIMD3<Float>(0, radius, 0)
        let p = camera.inverse * SIMD4(worldCentre, 1)
        func limits(_ v: Float, _ focal: Float, _ principal: Float) -> (CGFloat, CGFloat) {
            let divisor = p.z * p.z - radius * radius
            let spread = radius * sqrt(v * v + divisor)
            return (CGFloat(focal * (v * p.z - spread) / divisor + principal),
                    CGFloat(focal * (v * p.z + spread) / divisor + principal))
        }
        let x = limits(p.x, 1000, 960), y = limits(p.y, 1000, 720)
        return CGRect(x: x.0, y: y.0, width: x.1 - x.0, height: y.1 - y.0)
    }

    func testRecoversKnownFloorContactAndRadiusAtSeveralDepths() throws {
        for depth: Float in [2, 3, 5] {
            let point = SIMD3<Float>(0.15, 0, -depth), pose = camera()
            let result = try XCTUnwrap(ShotRollGeometry.project(sensorBounds: sphereBounds(contact: point, camera: pose),
                imageSize: size, intrinsics: k, worldFromCamera: pose, floor: floor()))
            XCTAssertLessThan(simd_distance(result.worldContact, point), 0.001)
            XCTAssertEqual(result.radiusM, 0.11, accuracy: 0.001)
            XCTAssertTrue(result.insideMappedFloor)
        }
    }

    func testCameraTiltAndAllSensorRollsPreserveGroundContact() throws {
        for roll: Float in [0, .pi/2, .pi, -.pi/2] {
            let pose = camera(roll: roll, tilt: -.pi/12), point = SIMD3<Float>(0.1, 0, -3)
            let result = try XCTUnwrap(ShotRollGeometry.project(sensorBounds: sphereBounds(contact: point, camera: pose),
                imageSize: size, intrinsics: k, worldFromCamera: pose, floor: floor()))
            XCTAssertLessThan(simd_distance(result.worldContact, point), 0.002)
        }
    }

    func testRotationMappingReturnsOriginalSensorRectangle() {
        let raw = CGRect(x: 0.2, y: 0.3, width: 0.15, height: 0.25)
        let upright: [ShotRollRotation: CGRect] = [
            .up: raw, .right: CGRect(x: 0.45, y: 0.2, width: 0.25, height: 0.15),
            .down: CGRect(x: 0.65, y: 0.45, width: 0.15, height: 0.25),
            .left: CGRect(x: 0.3, y: 0.65, width: 0.25, height: 0.15)]
        for rotation in ShotRollRotation.allCases {
            let output = rotation.sensorRect(upright[rotation]!)
            XCTAssertEqual(output.minX, raw.minX, accuracy: 1e-6)
            XCTAssertEqual(output.minY, raw.minY, accuracy: 1e-6)
            XCTAssertEqual(output.width, raw.width, accuracy: 1e-6)
            XCTAssertEqual(output.height, raw.height, accuracy: 1e-6)
        }
        XCTAssertEqual(ShotRollRotation.upright(worldFromCamera: camera()), .up)
        XCTAssertEqual(ShotRollRotation.upright(worldFromCamera: camera(roll: .pi/2)), .right)
        XCTAssertEqual(ShotRollRotation.upright(worldFromCamera: camera(roll: .pi)), .down)
        XCTAssertEqual(ShotRollRotation.upright(worldFromCamera: camera(roll: -.pi/2)), .left)
    }

    func testOutsideMappedBoundaryIsAnExplicitExtrapolation() throws {
        let pose = camera(), point = SIMD3<Float>(0, 0, -5)
        let result = try XCTUnwrap(ShotRollGeometry.project(sensorBounds: sphereBounds(contact: point, camera: pose),
            imageSize: size, intrinsics: k, worldFromCamera: pose, floor: floor(depth: 3)))
        XCTAssertFalse(result.insideMappedFloor)
        XCTAssertLessThan(simd_distance(result.worldContact, point), 0.002)
    }

    func testClippedTinyAndNonsphericalBoxesDoNotCreateMeasurements() {
        for bounds in [CGRect(x: 0, y: 200, width: 30, height: 30),
                       CGRect(x: 700, y: 700, width: 2, height: 2),
                       CGRect(x: 700, y: 700, width: 200, height: 10)] {
            XCTAssertNil(ShotRollGeometry.project(sensorBounds: bounds, imageSize: size,
                intrinsics: k, worldFromCamera: camera(), floor: floor()))
        }
    }

    func testStationaryJitterDoesNotAccumulateDistance() {
        var tracker = ShotRollTracker()
        tracker.arm(point: SIMD3(0, 0, -2), time: 0)
        for i in 1...1000 {
            XCTAssertTrue(tracker.observe(point: SIMD3(i % 2 == 0 ? 0.005 : -0.005, 0, -2), time: Double(i) / 10))
        }
        XCTAssertEqual(tracker.distanceM ?? -1, 0.005, accuracy: 0.0001)
    }

    func testDistanceIsDisplacementAndNewStartResetsIt() {
        var tracker = ShotRollTracker(); tracker.arm(point: SIMD3(0, 0, -2), time: 0)
        for i in 1...10 { XCTAssertTrue(tracker.observe(point: SIMD3(0, 0, -2 - Float(i) * 0.3), time: Double(i)/10)) }
        XCTAssertEqual(tracker.distanceM ?? -1, 3, accuracy: 0.001)
        XCTAssertTrue(tracker.observe(point: SIMD3(0, 0, -4.5), time: 1.1))
        XCTAssertEqual(tracker.distanceM ?? -1, 2.5, accuracy: 0.001)
        tracker.arm(point: SIMD3(0, 0, -4.5), time: 1.2)
        XCTAssertEqual(tracker.distanceM, 0)
        XCTAssertFalse(tracker.needsNewStart)
    }

    func testLostTrackingAndTeleportHoldTheLastValue() {
        for nextTime in [0.2, 1.2] {
            var tracker = ShotRollTracker(); tracker.arm(point: SIMD3(0, 0, -2), time: 0)
            XCTAssertTrue(tracker.observe(point: SIMD3(0, 0, -2.3), time: 0.1))
            XCTAssertFalse(tracker.observe(point: SIMD3(0, 0, -8), time: nextTime))
            XCTAssertTrue(tracker.needsNewStart)
            XCTAssertEqual(tracker.distanceM ?? -1, 0.3, accuracy: 0.001)
        }
    }

    func testFloorOffsetChangeRequiresNewReference() {
        XCTAssertTrue(floor(offset: 0.02).stableRelative(to: floor()))
        XCTAssertFalse(floor(offset: 0.1).stableRelative(to: floor()))
    }
}
