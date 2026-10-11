import CoreFoundation
import Foundation
import simd

/// Replay-only experiment. Reuses saved ground projections, ignoring the rolling
/// step/gap latch. This never changes the recorder, its files, or exported distances.
nonisolated struct SavedDistanceTestTimeline: Sendable {
    struct Position: Sendable, Equatable {
        let time: Double
        let point: SIMD3<Float>
        let segment: Int
    }
    let test: BallDistanceTimeline?
    let saved: BallDistanceTimeline?
    var positions: [Position] = []

    static func load(directory: URL) throws -> Self {
        // Verifies the distance log and any calibration evidence before decoding.
        let saved = try BallDistanceTimeline.load(directory: directory)
        guard saved != nil else { return Self(test: nil, saved: nil) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        let log = try Data(contentsOf: directory.appendingPathComponent("roll-distance.jsonl"))
        let replay = try decodeReplay(log, sourceOrigin: number(manifest["source_origin_s"]) ?? 0)
        return Self(test: replay.timeline, saved: saved, positions: replay.positions)
    }

    /// Limited to the newer AR-floor captures used in this experiment. Missing
    /// observations hold the previous value; we do not interpolate through gaps.
    static func decode(_ data: Data, sourceOrigin: Double = 0) throws -> BallDistanceTimeline? {
        try decodeReplay(data, sourceOrigin: sourceOrigin).timeline
    }

    static func decodeReplay(_ data: Data, sourceOrigin: Double = 0) throws
        -> (timeline: BallDistanceTimeline?, positions: [Position]) {
        var samples: [BallDistanceTimeline.Sample] = []
        var positions: [Position] = []
        var segment = 0
        var origin: SIMD3<Float>?
        var plane: String?
        var trial: Double?
        var lastDistance: Double?
        var lastTime = 0.0
        var invalidated = false
        for line in data.split(separator: 10) {
            let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] ?? [:]
            let time = number(row["time_s"]) ?? number(row["capture_timestamp_s"]).map { $0 - sourceOrigin }
            switch row["event"] as? String {
            case "set_start":
                guard row["distance_calibration"] as? String == "uncalibrated_ar_floor",
                      let point = point(row["world_contact_m"]),
                      let id = row["plane_id"] as? String, !id.isEmpty,
                      let nextTrial = number(row["trial"]), nextTrial > 0,
                      let time, time >= lastTime else { continue }
                origin = point; plane = id; trial = nextTrial
                invalidated = false; lastDistance = 0; lastTime = time
                segment += 1
                positions.append(.init(time: time, point: point, segment: segment))
                samples.append(.init(time: time, distanceM: 0, status: .estimate))
            case "sample":
                guard let origin, !invalidated, let time, time > lastTime else { continue }
                // A changed floor/camera is not one of the cutoffs being removed.
                if row["floor_frozen_at_start"] as? Bool == false ||
                    (row["plane_id"] as? String).map({ $0 != plane }) == true ||
                    number(row["trial"]).map({ $0 != trial }) == true ||
                    (row["distance_calibration"] as? String).map({ $0 != "uncalibrated_ar_floor" }) == true {
                    invalidated = true; lastDistance = nil
                    samples.append(.init(time: time, distanceM: nil, status: .needsSetup))
                } else if row["floor_frozen_at_start"] as? Bool == true,
                          row["plane_id"] as? String == plane, number(row["trial"]) == trial,
                          row["distance_calibration"] as? String == "uncalibrated_ar_floor",
                          let point = point(row["world_contact_m"]),
                          simd_distance(point, origin).isFinite {
                    lastDistance = Double(simd_distance(point, origin))
                    positions.append(.init(time: time, point: point, segment: segment))
                    samples.append(.init(time: time, distanceM: lastDistance, status: .estimate))
                } else {
                    samples.append(.init(time: time, distanceM: lastDistance, status: .paused))
                }
                lastTime = time
            case "calibration", "calibration_invalidated":
                guard origin != nil else { continue }
                invalidated = true; lastDistance = nil
                lastTime = max(lastTime, time ?? lastTime)
                samples.append(.init(time: lastTime, distanceM: nil, status: .needsSetup))
            default: break // End-of-file does not certify a stopped ball or a final distance.
            }
        }
        return (samples.isEmpty ? nil : BallDistanceTimeline(samples: samples), positions)
    }

    private static func point(_ value: Any?) -> SIMD3<Float>? {
        guard let array = value as? [Any], array.count == 3,
              let x = number(array[0]), let y = number(array[1]), let z = number(array[2]),
              [x, y, z].allSatisfy({ Float($0).isFinite }) else { return nil }
        return SIMD3(Float(x), Float(y), Float(z))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
