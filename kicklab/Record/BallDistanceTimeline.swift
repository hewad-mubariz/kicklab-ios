import Foundation
import CoreFoundation

/// Replays the distances saved while recording: measured on ARKit's own floor and scale
/// (experimental), or, for older recordings, on a floor calibrated with measured marks.
/// Imported footage has no metric scale and never receives a distance timeline.
nonisolated struct BallDistanceTimeline: Equatable, Sendable {
    enum Status: String, Sendable {
        case waiting, tracking, estimate, paused, needsSetup, finished

        var label: String {
            switch self {
            case .waiting: "Waiting for the start"
            case .tracking: "From start · estimated"
            case .estimate: "From start · estimated"
            case .paused: "Last estimate · tracking paused"
            case .needsSetup: "Set up distance again"
            case .finished: "Saved estimate · from start"
            }
        }
    }

    struct Sample: Equatable, Sendable {
        let time: Double
        let distanceM: Double?
        let status: Status
        var valueLabel: String { distanceM.map { String(format: "%.2f m", $0) } ?? "— m" }
    }

    let samples: [Sample]
    var finalDistanceM: Double? { samples.last?.distanceM }

    func state(at time: Double) -> Sample {
        guard time.isFinite, let first = samples.first, time >= first.time else {
            return Sample(time: max(0, time.isFinite ? time : 0), distanceM: nil, status: .waiting)
        }
        var low = 0, high = samples.count
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        let sample = samples[max(0, low - 1)]
        if (sample.status == .tracking || sample.status == .estimate), time - sample.time > 0.35 {
            return Sample(time: sample.time, distanceM: sample.distanceM, status: .paused)
        }
        return sample
    }

    /// A recording without distance data is a valid effects-only recording, not a zero metre roll.
    static func load(directory: URL) throws -> Self? {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        guard manifest["roll_distance"] as? String == "roll-distance.jsonl",
              let expected = manifest["roll_distance_sha256"] as? String else { return nil }
        let path = directory.appendingPathComponent("roll-distance.jsonl")
        guard try ShotRecordingStore.hash(path) == expected else { throw ShotRecordingStore.StoreError.changed }
        let origin = number(manifest["source_origin_s"]) ?? 0
        guard let calibrationID = manifest["roll_calibration_id"] as? String, !calibrationID.isEmpty else {
            // Measured on ARKit's own floor, with no measured marks.
            return try decode(Data(contentsOf: path), calibrationID: nil, sourceOrigin: origin)
        }
        guard manifest["roll_calibration_image"] as? String == "roll-calibration.png",
              let photoHash = manifest["roll_calibration_image_sha256"] as? String else { return nil }
        guard try ShotRecordingStore.hash(directory.appendingPathComponent("roll-calibration.png")) == photoHash else {
            throw ShotRecordingStore.StoreError.changed
        }
        return try decode(Data(contentsOf: path), calibrationID: calibrationID, sourceOrigin: origin)
    }

    /// With a calibration ID, only distances measured on that calibrated floor count. Without
    /// one, only distances measured on ARKit's own floor count, and calibration events are ignored.
    static func decode(_ data: Data, calibrationID: String?, sourceOrigin: Double = 0) throws -> Self? {
        var result: [Sample] = []
        let method = calibrationID == nil ? "uncalibrated_ar_floor" : "measured_span_floor_offset"
        var calibrated = calibrationID == nil, hasStart = false
        var lastDistance: Double?
        var lastTime = 0.0
        var invalidated = false
        for line in data.split(separator: 10) {
            let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] ?? [:]
            let event = row["event"] as? String
            let time = number(row["time_s"]) ?? number(row["capture_timestamp_s"]).map { $0 - sourceOrigin }
            switch event {
            case "calibration":
                guard let calibrationID else { continue }
                calibrated = row["calibration_id"] as? String == calibrationID &&
                    number(row["reference_distance_m"]).map { (0.5...10).contains($0) } == true
            case "calibration_invalidated":
                guard calibrationID != nil, calibrated else { continue }
                invalidated = true; hasStart = false; lastDistance = nil
                let t = max(lastTime, time ?? lastTime)
                result.append(Sample(time: t, distanceM: nil, status: .needsSetup)); lastTime = t
            case "set_start":
                guard calibrated, !invalidated,
                      row["distance_calibration"] as? String == method,
                      let t = time, t.isFinite, t >= 0 else { continue }
                hasStart = true; lastDistance = 0; lastTime = t
                result.append(Sample(time: t, distanceM: 0, status: .tracking))
            case "sample":
                guard calibrated, hasStart, !invalidated, let t = time, t.isFinite, t >= lastTime else { continue }
                let value = number(row["distance_from_start_m"])
                if row["calibration_id"] as? String == calibrationID,
                   row["distance_calibration"] as? String == method,
                   row["live"] as? Bool == true, let value, value >= 0 {
                    lastDistance = value
                    result.append(Sample(time: t, distanceM: value,
                        status: row["inside_current_mapped_boundary"] as? Bool == false ? .estimate : .tracking))
                } else {
                    result.append(Sample(time: t, distanceM: lastDistance, status: .paused))
                }
                lastTime = t
            case "end":
                guard calibrated, hasStart, !invalidated, let lastDistance else { continue }
                // The manifest's last value can be held after tracking loss. Keep
                // the accepted samples as the source rather than inventing an endpoint.
                result.append(Sample(time: lastTime + 0.000_001, distanceM: lastDistance, status: .finished))
            default: break
            }
        }
        guard calibrated, !result.isEmpty else { return nil }
        return Self(samples: result)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
