#if POWER_SHOT_DEBUG
import Foundation
import simd

/// Additional evidence only. Never feeds a value back into the measurement.
nonisolated struct PowerShotDiagnostics {
    var tracking = "Starting camera"
    var captureFPS = 0.0
    var savedFrames = 0
    var droppedFrames = 0
    var elapsed = 0.0
    var exposureMS = 0.0
    var thermal = "unknown"
    var sample: [String: String] = [:]
    var lastInvalidation = "none"
    private var start: SIMD3<Double>?
    private var uncalibratedStart: SIMD3<Double>?
    private var previousPoint: SIMD3<Double>?
    private var previousTime: Double?
    private var previousSampleTime: Double?

    mutating func annotate(_ event: inout [String: Any]) {
        func point(_ key: String) -> SIMD3<Double>? {
            guard let values = event[key] as? [NSNumber], values.count == 3,
                  values.allSatisfy({ $0.doubleValue.isFinite }) else { return nil }
            return SIMD3(values[0].doubleValue, values[1].doubleValue, values[2].doubleValue)
        }
        if event["event"] as? String == "set_start" {
            start = point("world_contact_m"); previousPoint = start
            uncalibratedStart = point("uncalibrated_world_contact_m")
            previousTime = (event["capture_timestamp_s"] as? NSNumber)?.doubleValue
            lastInvalidation = "none"
            return
        }
        guard event["event"] as? String == "sample" else { return }
        let time = (event["capture_timestamp_s"] as? NSNumber)?.doubleValue
        if let time, let previousSampleTime, time > previousSampleTime {
            event["detector_sample_interval_s"] = time - previousSampleTime
        }
        previousSampleTime = time
        if let uncalibratedStart, let position = point("uncalibrated_world_contact_m") {
            event["uncalibrated_distance_from_start_m"] = simd_distance(position, uncalibratedStart)
        }
        if let start, let position = point("world_contact_m"), let time {
            // This deliberately continues after a rejected step, to preserve the
            // old limit-off experiment without presenting it as measured distance.
            event["raw_ground_projection_distance_m"] = simd_distance(position, start)
            if let previousPoint, let previousTime, time > previousTime {
                event["raw_projection_step_m"] = simd_distance(position, previousPoint)
                event["raw_projection_interval_s"] = time - previousTime
                event["raw_projection_speed_kmh"] = simd_distance(position, previousPoint) / (time - previousTime) * 3.6
            }
            self.previousPoint = position; previousTime = time
        }
        event["raw_projection_is_validated_measurement"] = false
        event["last_invalidation_reason"] = lastInvalidation
        sample = [:]
        for key in ["model", "confidence", "threshold", "detector_ms", "observation_age_s",
                    "detector_sample_interval_s", "camera_height_m", "radius_estimate_m",
                    "silhouette_edge_rms_px", "inside_current_mapped_boundary", "measurement_gate",
                    "raw_ground_projection_distance_m", "raw_projection_speed_kmh",
                    "uncalibrated_distance_from_start_m",
                    "tracker_step_m", "tracker_interval_s", "tracker_step_limit_m",
                    "camera_movement_m", "camera_angle_change_deg", "rolling_speed_window_s",
                    "rolling_speed_window_samples", "rolling_speed_fit_rms_m"] {
            if let number = event[key] as? NSNumber {
                sample[key] = String(format: "%.3f", number.doubleValue)
            } else if let value = event[key] as? String { sample[key] = value }
        }
    }
}

nonisolated enum PowerShotCapturePolicy {
    static func canCaptureEvidence(cameraActive: Bool, hasFrame: Bool, calibrating: Bool) -> Bool {
        cameraActive && hasFrame && !calibrating
    }

    static func detectorSchedule(calibrating: Bool, busy: Bool, elapsed: Double, recording: Bool) -> String {
        if calibrating { return "calibration_photo_open" }
        if busy { return "inference_busy" }
        if elapsed < (recording ? 0.1 : 0.25) { return "cadence_limit" }
        return "submit"
    }
}

/// Nominal field markings are retained separately from measured endpoints.
/// Crossing time is relative to the original movie, never inferred from net impact.
nonisolated struct PowerShotPenaltyReference: Codable, Equatable {
    var goalLineDistanceM = "11"
    var distanceSource = "regulation_nominal"
    var releaseTimeS = ""
    var crossingTimeS = ""
    var lateralOffsetM = ""
    var crossingHeightM = ""

    var validationError: String? {
        for (label, value) in [("Goal-line distance", goalLineDistanceM), ("Release time", releaseTimeS),
                               ("Crossing time", crossingTimeS), ("Crossing height", crossingHeightM)] where !value.isEmpty {
            guard let number = Self.number(value), number >= 0 else { return "\(label) must be a finite, nonnegative number." }
        }
        guard let distance = Self.number(goalLineDistanceM), distance > 0 else { return "Enter a positive goal-line distance." }
        if !lateralOffsetM.isEmpty && Self.number(lateralOffsetM) == nil { return "Lateral offset must be a finite number." }
        if let release = Self.number(releaseTimeS), let crossing = Self.number(crossingTimeS), crossing <= release {
            return "Goal-line crossing must be after release."
        }
        return nil
    }
    private static func number(_ text: String) -> Double? {
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite else { return nil }
        return number
    }
}

/// Editable observer labels are separate from the original, hash-checked sensor
/// evidence. A claimed reference is never automatically promoted to ground truth.
nonisolated struct PowerShotFieldReference: Codable, Equatable {
    var schema = "kicklab.power-shot-field-reference.v1"
    var kind = "ground_roll"
    var surface = ""
    var endpointMetres = ""
    var distanceMethod = "unmeasured"
    var referenceSpeedKMH = ""
    var speedMethod = "unmeasured"
    var notes = ""
    var penalty: PowerShotPenaltyReference?
    var checklist: PowerShotChecklistLink?
    var checklistReview: PowerShotChecklistReview?
    var updatedAt = Date()

    static let filename = "field-reference.json"
    var validationError: String? {
        if let error = penalty?.validationError { return error }
        for (label, value) in [("Distance", endpointMetres), ("Speed", referenceSpeedKMH)] where !value.isEmpty {
            guard let number = Double(value.replacingOccurrences(of: ",", with: ".")), number.isFinite, number >= 0 else {
                return "\(label) must be a finite, nonnegative number."
            }
        }
        if !endpointMetres.isEmpty && distanceMethod == "unmeasured" { return "Choose how the distance was measured." }
        if !referenceSpeedKMH.isEmpty && speedMethod == "unmeasured" { return "Choose an independent speed reference." }
        return nil
    }
    static func load(from directory: URL) throws -> Self {
        let file = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }
    func save(to directory: URL) throws {
        if let message = validationError {
            throw NSError(domain: "PowerShotFieldReference", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        var copy = self; copy.updatedAt = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(copy).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
#endif
