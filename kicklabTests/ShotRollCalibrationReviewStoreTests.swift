import CoreGraphics
import CryptoKit
import ImageIO
import XCTest
import simd
@testable import kicklab

final class ShotRollCalibrationReviewStoreTests: XCTestCase {
    private var root: URL!
    private let size = CGSize(width: 1920, height: 1440)
    private let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func calibration() throws -> ShotRollCalibration {
        let camera = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0),
                                           SIMD4(0, 0, -1, 0), SIMD4(0, 0.84, 0, 1)))
        var plane = matrix_identity_float4x4; plane.columns.3.y = -0.2
        let floor = ShotRollFloor(id: "floor", worldFromPlane: plane, boundary: [])
        return try ShotRollCalibration.fit(sensorPoints: [pixel(distance: 2), pixel(distance: 5)],
            referenceDistanceM: 3, imageSize: size, intrinsics: k, camera: camera, floor: floor, timestamp: 10)
    }
    private func pixel(distance: CGFloat) -> CGPoint {
        CGPoint(x: 0.5, y: (720 + 840 / distance) / size.height)
    }
    private func photo(width: Int = 1920, height: Int = 1440) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
    private func manifest(_ receipt: ShotRollCalibrationReviewStore.Receipt) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            receipt.directory.appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    func testCheckPersistsPhotoPixelsAndFrozenGeometryWithoutRecordingVideo() throws {
        let calibration = try calibration()
        let points = [pixel(distance: 3), pixel(distance: 4)]
        let check = try calibration.checkSpan(sensorPoints: points, referenceDistanceM: 1)
        let image = try photo()
        let receipt = try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
            imagePNG: image, rotation: .right, root: root)
        let data = try manifest(receipt)
        XCTAssertEqual(data["schema"] as? String, "kicklab.roll-calibration-review.v1")
        XCTAssertEqual(data["rotation_clockwise"] as? Int, 90)
        XCTAssertEqual(data["calibration_applied"] as? Bool, false)
        XCTAssertEqual(data["physical_speed_accuracy_verified"] as? Bool, false)
        let savedPhoto = try Data(contentsOf: receipt.directory.appendingPathComponent("roll-calibration.png"))
        XCTAssertEqual(savedPhoto, image)
        XCTAssertEqual(data["image_sha256"] as? String,
                       SHA256.hash(data: savedPhoto).map { String(format: "%02x", $0) }.joined())
        let fit = try XCTUnwrap(data["calibration"] as? [String: Any])
        XCTAssertEqual(fit["calibration_id"] as? String, calibration.id)
        let saved = try XCTUnwrap(data["independent_span_check"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(saved["estimated_distance_m"] as? Double), 1, accuracy: 0.0001)
        XCTAssertEqual(saved["within_experimental_tolerance"] as? Bool, true)
        XCTAssertEqual(saved["sensor_points_normalized"] as? [[Double]], points.map { [Double($0.x), Double($0.y)] })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receipt.directory.path).sorted(),
                       ["manifest.json", "roll-calibration.png"])
    }

    func testMismatchAlsoPersistsAndDoesNotRefitTheFloor() throws {
        let calibration = try calibration(), before = calibration.floor.worldFromPlane
        let check = try calibration.checkSpan(sensorPoints: [pixel(distance: 3), pixel(distance: 4)], referenceDistanceM: 2)
        XCTAssertFalse(check.withinTolerance)
        let receipt = try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
            imagePNG: photo(), rotation: .up, root: root)
        let saved = try XCTUnwrap(manifest(receipt)["independent_span_check"] as? [String: Any])
        XCTAssertEqual(saved["within_experimental_tolerance"] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(saved["error_m"] as? Double), -1, accuracy: 0.0001)
        XCTAssertEqual(calibration.floor.worldFromPlane, before)
    }

    func testRepeatedSavesKeepBothCompletedChecks() throws {
        let calibration = try calibration()
        let check = try calibration.checkSpan(sensorPoints: [pixel(distance: 3), pixel(distance: 4)], referenceDistanceM: 1)
        let image = try photo()
        let first = try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
            imagePNG: image, rotation: .up, root: root)
        let second = try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
            imagePNG: image, rotation: .up, root: root)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), Set([first.id, second.id]))
        XCTAssertEqual(try manifest(first)["id"] as? String, first.id)
        XCTAssertEqual(try manifest(second)["id"] as? String, second.id)
    }

    func testWrongOrMissingPhotoCannotCreateACompletedCheck() throws {
        let calibration = try calibration()
        let check = try calibration.checkSpan(sensorPoints: [pixel(distance: 3), pixel(distance: 4)], referenceDistanceM: 1)
        for image in [Data(), try photo(width: 1, height: 1)] {
            XCTAssertThrowsError(try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
                imagePNG: image, rotation: .up, root: root))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testUnwritableDestinationThrowsInsteadOfReturningASavedReceipt() throws {
        let calibration = try calibration()
        let check = try calibration.checkSpan(sensorPoints: [pixel(distance: 3), pixel(distance: 4)], referenceDistanceM: 1)
        let blocked = root.appendingPathComponent("file-blocks-directory")
        let original = Data("preserve".utf8); try original.write(to: blocked)
        XCTAssertThrowsError(try ShotRollCalibrationReviewStore.save(calibration: calibration, check: check,
            imagePNG: photo(), rotation: .up, root: blocked))
        XCTAssertEqual(try Data(contentsOf: blocked), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["file-blocks-directory"])
    }
}
