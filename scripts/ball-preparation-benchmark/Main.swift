import Foundation
import simd

/// Runs the real source-spin pipeline against retained video and mask evidence.
/// It bypasses app caches/lifecycle; these timings are Mac timings, not iPhone claims.
@main struct BallPreparationBenchmark {
    struct Row: Codable {
        let time: Double
        let orientation: [Float]
        let accepted, visible: Bool
        let white: [Float]?
    }
    struct Run: Codable {
        let seconds: Double
        let accepted: Int
        let exposure: Double?
        let timing: BallPreparationTiming?
        let rows: [Row]
    }
    struct Report: Encodable {
        let scope = "Optimized native macOS; production AVFoundation/geometry/rotation; saved masks; no fresh model inference or iOS thermal policy."
        let runs: [Run]
    }
    static func main() async throws {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--geometry" {
            try await GeometryReuseStudy.run(args)
            return
        }
        guard args.count >= 4 else { fatalError("source.mov appearance.plist output.json [runs]") }
        let source = URL(fileURLWithPath: args[1])
        let frames = try SavedAppearanceFrames.frames(URL(fileURLWithPath: args[2]))
        let track = BallEffectTrack(frames: frames)
        var runs: [Run] = []
        for index in 0..<(args.count > 4 ? Int(args[4])! : 1) {
            let timeline = try await BallSurfaceTimeline.analyzeForReview(source: source, track: track)
            #if BENCHMARK_BASELINE
            let timing: BallPreparationTiming? = nil
            #else
            let timing = timeline.preparationTiming
            #endif
            runs.append(Run(seconds: timeline.elapsed, accepted: timeline.acceptedCount,
                exposure: timeline.photographicExposure, timing: timing,
                rows: timeline.entries.map { row in
                    Row(time: row.time, orientation: [row.orientation.vector.x, row.orientation.vector.y,
                        row.orientation.vector.z, row.orientation.vector.w], accepted: row.accepted,
                        visible: row.visible, white: row.white.map { [$0.x, $0.y, $0.z] })
                }))
            print("Run \(index+1): \(timeline.entries.count) frames, \(timeline.acceptedCount) accepted pairs, \(timeline.elapsed)s")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Report(runs: runs)).write(to: URL(fileURLWithPath: args[3]), options: .atomic)
    }
}
