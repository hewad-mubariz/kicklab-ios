import Foundation
import simd

/// Human-selected source-video times. These establish a review interval, not
/// ground contact, a measured flight path, or validated launch speed.
nonisolated struct SavedShotPhaseMarks: Codable, Equatable, Sendable {
    var kick: Double?
    var landing: Double?

    var flightSeconds: Double? {
        guard let kick, let landing, landing > kick else { return nil }
        return landing - kick
    }

    mutating func setKick(_ time: Double) {
        kick = time
        if let landing, landing <= time { self.landing = nil }
    }

    func phase(at time: Double) -> String {
        guard let kick else { return "Mark the kick" }
        if time < kick { return "Before kick" }
        guard let landing else { return "After kick · mark first landing" }
        return time < landing ? "Flight · distance pending" : "After landing · roll / bounce"
    }

    func isValid(frameTimes: [Double]) -> Bool {
        func isFrame(_ value: Double) -> Bool {
            value.isFinite && value >= 0 && frameTimes.contains { abs($0 - value) < 0.000_001 }
        }
        guard kick.map(isFrame) ?? true, landing.map(isFrame) ?? true else { return false }
        if let landing { return kick.map { landing > $0 } ?? false }
        return true
    }

    struct GroundSpan: Sendable {
        let distanceM: Double
        let start: SavedDistanceTestTimeline.Position
        let end: SavedDistanceTestTimeline.Position
    }

    /// Take a pre-kick and post-contact observation, never a flight peak or a
    /// held display value. A 10 Hz log can still miss the actual contact frame;
    /// report the offsets and keep this span explicitly unverified.
    func groundSpan(positions: [SavedDistanceTestTimeline.Position]) -> GroundSpan? {
        guard let kick, let landing, landing > kick,
              let start = positions.last(where: { $0.time <= kick + 0.000_001 }),
              let end = positions.first(where: { $0.time >= landing - 0.000_001 }),
              kick - start.time <= 0.12, end.time - landing <= 0.12,
              start.segment == end.segment else { return nil }
        let distance = Double(simd_distance(start.point, end.point))
        guard distance.isFinite else { return nil }
        return GroundSpan(distanceM: distance, start: start, end: end)
    }
}

nonisolated enum SavedShotPhaseStore {
    static let filename = "shot-phase-test.json"

    struct Evidence: Codable, Equatable, Sendable {
        let videoSHA256: String
        let distanceSHA256: String?
    }
    private struct Document: Codable {
        let schema: String
        let evidence: Evidence
        let marks: SavedShotPhaseMarks
    }
    enum Failure: LocalizedError {
        case changed, invalid
        var errorDescription: String? {
            switch self {
            case .changed: "These marks belong to different recording data. They have been kept but were not applied."
            case .invalid: "The saved marks do not match the frames in this video."
            }
        }
    }

    static func evidence(directory: URL) throws -> Evidence {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("manifest.json"))) as? [String: Any] ?? [:]
        guard let hash = manifest["video_sha256"] as? String else { throw Failure.invalid }
        return Evidence(videoSHA256: hash, distanceSHA256: manifest["roll_distance_sha256"] as? String)
    }

    static func load(directory: URL, evidence: Evidence, frameTimes: [Double]) throws -> SavedShotPhaseMarks {
        let path = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: path.path) else { return SavedShotPhaseMarks() }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: path))
        guard document.schema == "kicklab.shot-phase-test.v1" else { throw Failure.invalid }
        guard document.evidence == evidence else { throw Failure.changed }
        guard document.marks.isValid(frameTimes: frameTimes) else { throw Failure.invalid }
        return document.marks
    }

    static func save(_ marks: SavedShotPhaseMarks, directory: URL, evidence: Evidence, frameTimes: [Double]) throws {
        guard marks.isValid(frameTimes: frameTimes) else { throw Failure.invalid }
        let document = Document(schema: "kicklab.shot-phase-test.v1", evidence: evidence, marks: marks)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
