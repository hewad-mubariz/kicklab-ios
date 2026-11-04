// SOURCE OUTPUT_DIRECTORY [MODEL.mlpackage] [model-edge: 288 or 384]
// Native SDR decode through production geometry. With a model: fresh full-frame
// RF masks at every source timestamp. Without: frame extraction only.
// This control does not reproduce app association, crop/gap repair or cached tracks.
import AVFoundation
import AppKit
import CoreML
import CoreImage
import Foundation

@main struct PairAudit {
    static func main() async throws {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--geometry" {
            try await PairGeometry.run(args)
            return
        }
        guard args.count >= 3 else { fatalError("SOURCE OUTPUT_DIRECTORY [MODEL.mlpackage] [model-edge]") }
        let modelEdge = args.count > 4 ? Int(args[4])! : 384
        precondition([288,384].contains(modelEdge))
        let source = URL(fileURLWithPath: args[1]), folder = URL(fileURLWithPath: args[2])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var model: MLModel?
        if args.count > 3 {
            var url = URL(fileURLWithPath: args[3])
            if url.pathExtension == "mlpackage" { url = try await MLModel.compileModel(at: url) }
            let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
            config.functionName = "rf\(modelEdge)"
            model = try MLModel(contentsOf: url, configuration: config)
        }
        let bridge = RFSegBridge(edge: modelEdge), ci = CIContext(options: [.cacheIntermediates: false])
        let asset = AVURLAsset(url: source), video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: 720)
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        var saved = [[String: Any]](), rows = [[String: Any]](), index = 0
        let start = ProcessInfo.processInfo.systemUptime
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                let time = sample.presentationTimeStamp.seconds, pixels = CMSampleBufferGetImageBuffer(sample)!
                let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                var row: [String: Any] = ["index": index, "time": time]
                if let model {
                    let prediction = try model.prediction(from: bridge.input(image: CIImage(cvPixelBuffer: pixels), context: ci))
                    let result = try bridge.decode(prediction, sourceSize: size, threshold: 0.4)
                    if let ball = result.ball {
                        var item: [String: Any] = ["values": [time,ball.x,ball.y,ball.width,ball.height,ball.score,ball.x,ball.y,0],
                            "detected": true, "usesMasks": true, "repair": false, "motion": 0]
                        row["ball"] = [ball.x,ball.y,ball.width,ball.height,ball.score]
                        if let mask = result.ballMask {
                            item["maskRect"] = [mask.rect.minX,mask.rect.minY,mask.rect.width,mask.rect.height]
                            item["maskWidth"] = mask.width; item["maskHeight"] = mask.height; item["alpha"] = Data(mask.alpha)
                            row["maskRadius"] = BallReplacementCoverage.maskRadius(mask, size: size)
                        }
                        saved.append(item)
                    }
                }
                if index % 6 == 0 {
                    let image = CIImage(cvPixelBuffer: pixels)
                    let cg = ci.createCGImage(image, from: image.extent)!
                    let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.96])!
                    let name = String(format: "frame-%05d.jpg", index)
                    try data.write(to: folder.appendingPathComponent(name)); row["image"] = name
                }
                rows.append(row); index += 1
                if index % 300 == 0 { print("\(source.lastPathComponent): \(index) frames, \(String(format: "%.2f", time))s"); fflush(stdout) }
            }
        }
        guard reader.status == .completed else { throw reader.error! }
        try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("visual.plist"))
        let report: [String: Any] = ["source": source.path, "frames": index, "detections": saved.count, "modelEdge":modelEdge,
            "seconds": ProcessInfo.processInfo.systemUptime-start,
            "scope": "macOS production SDR decode; optional raw RF inference at 0.4; no app association/crop/gap repair; not the exported clip's retained track",
            "rows": rows]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent("frames.json"))
        if model != nil {
            let frames = try SavedAppearanceFrames.frames(folder.appendingPathComponent("visual.plist"))
            let track = BallEffectTrack(frames: frames)
            let timeline = try await BallSurfaceTimeline.analyzeForReview(source: source, track: track)
            let spinRows: [[String: Any]] = timeline.entries.map { entry in
                ["time": entry.time, "accepted": entry.accepted, "visible": entry.visible,
                 "orientation": [entry.orientation.vector.x,entry.orientation.vector.y,entry.orientation.vector.z,entry.orientation.vector.w],
                 "status": timeline.status(at: entry.time).rawValue]
            }
            let spin: [String: Any] = ["rows": spinRows, "accepted": timeline.acceptedCount,
                "boxExposure": track.exposure(size: CGSize(width:720,height:1280)),
                "photographicExposure": timeline.photographicExposure as Any? ?? NSNull(), "seconds": timeline.elapsed]
            try JSONSerialization.data(withJSONObject: spin, options: [.sortedKeys])
                .write(to: folder.appendingPathComponent("spin.json"))
        }
        print("Complete: \(index) frames, \(saved.count) raw detections; \(folder.path)")
    }
}
