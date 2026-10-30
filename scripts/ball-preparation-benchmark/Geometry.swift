import AVFoundation
import Foundation

/// An offline experiment, not a production geometry cache. Match actual source
/// timestamps before comparing a preparation fit with a larger export fit.
enum GeometryReuseStudy {
    struct Outline: Codable {
        let center, radii: [Double]
        let radius, feather, padding: Double
        init(_ fit: BallReplacementFootprint) {
            let scale = min(fit.sourceSize.width, fit.sourceSize.height) / 720
            center = [fit.center.x / scale, fit.center.y / scale]
            radii = fit.radii.map { $0 / scale }
            radius = fit.radius / scale
            feather = fit.feather / scale
            padding = fit.padding / scale
        }
    }
    struct Row: Codable {
        let time: Double
        let width, height: Int
        let plain, textured: Outline?
    }
    struct Pass: Codable {
        let shortEdge, stride: Int
        let seconds: Double
        let rows: [Row]
    }
    struct Report: Codable {
        let scope: String
        let passes: [Pass]
    }

    static func run(_ args: [String]) async throws {
        guard args.count >= 5 else {
            fatalError("--geometry source.mov appearance.plist output.json [sample-stride]")
        }
        let stride = args.count > 5 ? Int(args[5])! : 12
        precondition(stride > 0)
        let track = BallEffectTrack(frames: try SavedAppearanceFrames.frames(URL(fileURLWithPath: args[3])))
        let source = URL(fileURLWithPath: args[2])
        var passes: [Pass] = []
        for edge in [720, 1080] {
            passes.append(try await decode(source: source, track: track, shortEdge: edge, stride: stride))
        }
        let report = Report(scope: "Sampled production outline fits, normalized to 720 short edge. Same source timestamps and guides; no model inference or rendering. Different decoded resolutions may not be interchangeable.", passes: passes)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        print("Geometry study: \(passes.map { $0.rows.count }) sampled frames at 720/1080 (capped to native resolution)")
    }

    private static func decode(source: URL, track: BallEffectTrack, shortEdge: Int, stride: Int) async throws -> Pass {
        let start = ProcessInfo.processInfo.systemUptime
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "GeometryStudy", code: 1)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: shortEdge)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "GeometryStudy", code: 2) }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var rows: [Row] = [], index = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            defer { index += 1 }
            guard index % stride == 0 else { continue }
            autoreleasepool {
                guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
                let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
                let sample = track.replacementGuide(at: time)
                let plain = sample.flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0) }
                let textured = sample.flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0, measureTexture: true) }
                rows.append(Row(time: time, width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels),
                    plain: plain.map(Outline.init), textured: textured.map(Outline.init)))
            }
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "GeometryStudy", code: 3) }
        return Pass(shortEdge: shortEdge, stride: stride, seconds: ProcessInfo.processInfo.systemUptime - start, rows: rows)
    }
}
