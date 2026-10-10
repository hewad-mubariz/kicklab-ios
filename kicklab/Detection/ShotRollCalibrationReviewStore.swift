import CryptoKit
import Foundation
import ImageIO
import simd

/// A gap check is saved independently of applying calibration or recording video.
nonisolated enum ShotRollCalibrationReviewStore {
    struct Receipt: Sendable {
        let directory: URL
        var id: String { directory.lastPathComponent }
    }

    enum SaveError: LocalizedError {
        case image
        var errorDescription: String? {
            "The frozen calibration photo could not be verified. Keep this check open and try again."
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotCalibrationReviews", isDirectory: true)
    }

    static func save(calibration: ShotRollCalibration, check: ShotRollCalibration.SpanCheck,
                     imagePNG: Data, rotation: ShotRollRotation, root: URL = root) throws -> Receipt {
        // Recompute against the frozen fit rather than trusting a displayed number.
        let verified = try calibration.checkSpan(sensorPoints: check.sensorPoints,
                                                 referenceDistanceM: check.referenceDistanceM)
        guard let source = CGImageSourceCreateWithData(imagePNG as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue == Double(calibration.imageSize.width),
              height.doubleValue == Double(calibration.imageSize.height) else { throw SaveError.image }

        func rows(_ matrix: simd_float4x4) -> [[Double]] {
            (0..<4).map { row in (0..<4).map { Double(matrix[$0][row]) } }
        }
        let id = UUID().uuidString
        let manifest: [String: Any] = [
            "schema": "kicklab.roll-calibration-review.v1",
            "id": id, "saved_at": ISO8601DateFormatter().string(from: Date()),
            "image": "roll-calibration.png",
            "image_sha256": SHA256.hash(data: imagePNG).map { String(format: "%02x", $0) }.joined(),
            "image_size": [calibration.imageSize.width, calibration.imageSize.height],
            "image_coordinate_system": "normalized_sensor_pixels_top_left_origin",
            "rotation_clockwise": rotation.rawValue,
            "calibration": [
                "calibration_id": calibration.id, "capture_timestamp_s": calibration.timestamp,
                "reference_distance_m": calibration.referenceDistanceM,
                "uncalibrated_span_m": calibration.originalSpanM, "height_factor": calibration.heightFactor,
                "sensor_points_normalized": calibration.sensorPoints.map { [$0.x, $0.y] },
                "intrinsics": (0..<3).map { row in (0..<3).map { Double(calibration.intrinsics[$0][row]) } },
                "world_from_camera": rows(calibration.camera), "plane_id": calibration.sourceFloor.id,
                "source_world_from_plane": rows(calibration.sourceFloor.worldFromPlane),
                "effective_world_from_plane": rows(calibration.floor.worldFromPlane),
                "source_boundary_vertices_local_m": calibration.sourceFloor.boundary.map { [$0.x, $0.y, $0.z] }
            ] as [String: Any],
            "independent_span_check": [
                "sensor_points_normalized": verified.sensorPoints.map { [$0.x, $0.y] },
                "reference_distance_m": verified.referenceDistanceM,
                "estimated_distance_m": verified.estimatedDistanceM,
                "error_m": verified.errorM, "tolerance_m": verified.toleranceM,
                "within_experimental_tolerance": verified.withinTolerance
            ] as [String: Any],
            "calibration_applied": false, "physical_scale_verified": false,
            "physical_speed_accuracy_verified": false,
            "note": "Saved for review without a video. A failed gap check remains available and does not apply a calibration."
        ]
        let metadata = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        let destination = root.appendingPathComponent(id, isDirectory: true)
        let staging = root.appendingPathComponent(".\(id).saving", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try imagePNG.write(to: staging.appendingPathComponent("roll-calibration.png"), options: .atomic)
            try metadata.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return Receipt(directory: destination)
    }
}
