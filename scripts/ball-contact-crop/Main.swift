// Would a zoomed mask improve ball replacement edges? Mac experiment only: nothing here ships.
//
//   labels MODEL.mlpackage EDGE DATASET_DIR OUTPUT.json
//     Scores today's full-frame mask and the zoomed crop mask against traced ball outlines,
//     through the real BallReplacementCoverage, so the score is what the renderer would draw.
//   clip MODEL.mlpackage EDGE SOURCE PREPARED.plist SPIN.json|none OUTPUT_DIR [window-seconds|all] [skin]
//     Re-masks the frames around each touch, then renders before/after with the production renderer.
//   blur SOURCE PREPARED.plist SPIN.json|none OUTPUT_DIR [skin]
//     Renders every frame with today's motion smear and with none, and measures print sharpness
//     frame to frame against the real ball. Also writes a source | today | no smear comparison video.
import AVFoundation
import AppKit
import CoreImage
import CoreML
import Foundation
import simd

/// The two production helpers the consensus and crop need, copied verbatim from RFMaskCropRefiner,
/// whose real file pulls in the app's detector and scheduling.
nonisolated enum RFMaskCropRefiner {
    static func area(_ mask: BallMask) -> Double {
        guard mask.width > 0, mask.height > 0 else { return 0 }
        return Double(mask.alphaSum) / 255
            / Double(mask.width * mask.height) * mask.rect.width * mask.rect.height
    }
    static func region(_ f: RecordedFrame, size: CGSize, context: Double) -> CGRect? {
        let diameter = max(f.width * size.width, f.height * size.height)
        guard [f.x, f.y, diameter].allSatisfy(\.isFinite), diameter >= 12,
              diameter < min(size.width, size.height) * 0.3 else { return nil }
        let side = max(128, diameter * context)
        let roi = CGRect(x: f.x * size.width - side / 2, y: f.y * size.height - side / 2,
                         width: side, height: side).integral.intersection(CGRect(origin: .zero, size: size))
        return roi.isEmpty || roi.isNull ? nil : roi
    }
}

final class Network {
    let model: MLModel, bridge: RFSegBridge
    let ci = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    let threshold: Double
    private(set) var calls = 0, seconds = 0.0

    init(package: String, edge: Int, threshold: Double = 0.4) async throws {
        let compiled = try await MLModel.compileModel(at: URL(fileURLWithPath: package))
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU; config.functionName = "rf\(edge)"
        model = try MLModel(contentsOf: compiled, configuration: config)
        bridge = RFSegBridge(edge: edge); self.threshold = threshold
    }
    private func predict(_ image: CIImage, size: CGSize) throws -> FrameDetections {
        let started = ProcessInfo.processInfo.systemUptime
        defer { calls += 1; seconds += ProcessInfo.processInfo.systemUptime - started }
        return try bridge.decode(model.prediction(from: bridge.input(image: image, context: ci)), sourceSize: size, threshold: threshold)
    }
    func full(_ image: CIImage) throws -> FrameDetections { try predict(image, size: image.extent.size) }

    /// BallDetector.inferRFMaskCrop, without the detector around it.
    func crop(_ image: CIImage, roi: CGRect) throws -> FrameDetections {
        let rect = CGRect(x: roi.minX, y: image.extent.height - roi.maxY, width: roi.width, height: roi.height)
        let patch = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let decoded = try predict(patch, size: roi.size)
        guard let b = decoded.ball, let m = decoded.ballMask else { return FrameDetections(ball: nil, person: nil) }
        let size = image.extent.size
        let ball = Detection(score: b.score, x: (roi.minX + b.x * roi.width) / size.width,
            y: (roi.minY + b.y * roi.height) / size.height,
            width: b.width * roi.width / size.width, height: b.height * roi.height / size.height)
        let mask = BallMask(rect: CGRect(x: (roi.minX + m.rect.minX * roi.width) / size.width,
            y: (roi.minY + m.rect.minY * roi.height) / size.height,
            width: m.rect.width * roi.width / size.width, height: m.rect.height * roi.height / size.height),
            width: m.width, height: m.height, alpha: m.alpha)
        return FrameDetections(ball: ball, person: nil, ballMask: mask, usesBallMasks: true)
    }
    /// The refiner's own rule: try each context until two agree, at most three calls.
    func consensus(_ image: CIImage, guide: RecordedFrame) throws -> BallMask? {
        let size = image.extent.size
        var candidates = [RFMaskCropConsensus.Candidate](), visited = [CGRect]()
        for context in RFMaskCropConsensus.contexts {
            guard let roi = RFMaskCropRefiner.region(guide, size: size, context: context), !visited.contains(roi) else { continue }
            visited.append(roi)
            if let c = RFMaskCropConsensus.candidate(try crop(image, roi: roi), guide: guide, roi: roi, size: size) {
                candidates.append(c)
                if let mask = RFMaskCropConsensus.accepted(candidates, guide: guide) { return mask }
            }
        }
        return nil
    }
}

func guideFrame(_ d: FrameDetections, time: Double = 0) -> RecordedFrame? {
    guard let b = d.ball else { return nil }
    return RecordedFrame(time: time, x: b.x, y: b.y, width: b.width, height: b.height, score: b.score,
        smoothedX: b.x, smoothedY: b.y, vy: 0, motion: .unknown, detected: true, person: nil,
        ballMask: d.ballMask, usesBallMasks: d.ballMask != nil)
}

// MARK: - Score against traced outlines

enum Labels {
    /// COCO compressed RLE, column-major.
    static func decode(counts: String, w: Int, h: Int) -> [UInt8] {
        var runs = [Int](), p = 0
        let bytes = Array(counts.utf8)
        while p < bytes.count {
            var x = 0, k = 0, more = true
            while more {
                let c = Int(bytes[p]) - 48; x |= (c & 0x1f) << (5 * k)
                more = c & 0x20 != 0; p += 1; k += 1
                if !more && c & 0x10 != 0 { x |= -1 << (5 * k) }
            }
            if runs.count > 2 { x += runs[runs.count - 2] }
            runs.append(x)
        }
        var out = [UInt8](repeating: 0, count: w * h), i = 0, v: UInt8 = 0
        for run in runs {
            if v == 1 { for j in i..<min(i + run, w * h) { out[(j / h) * 1 + (j % h) * w] = 1 } }
            i += run; v = 1 - v
        }
        return out
    }

    static func score(_ inside: (Double, Double) -> Bool, bounds: CGRect, label: [UInt8], w: Int, h: Int) -> [String: Double] {
        var labelBox = (minX: w, minY: h, maxX: 0, maxY: 0), area = 0
        for y in 0..<h { for x in 0..<w where label[y * w + x] == 1 {
            labelBox = (min(labelBox.minX, x), min(labelBox.minY, y), max(labelBox.maxX, x), max(labelBox.maxY, y)); area += 1
        } }
        let x0 = max(0, min(labelBox.minX, Int(bounds.minX)) - 4), x1 = min(w - 1, max(labelBox.maxX, Int(bounds.maxX)) + 4)
        let y0 = max(0, min(labelBox.minY, Int(bounds.minY)) - 4), y1 = min(h - 1, max(labelBox.maxY, Int(bounds.maxY)) + 4)
        var both = 0, onlyDrawn = 0, onlyBall = 0
        for y in y0...y1 { for x in x0...x1 {
            let drawn = inside(Double(x) + 0.5, Double(y) + 0.5), ball = label[y * w + x] == 1
            if drawn && ball { both += 1 } else if drawn { onlyDrawn += 1 } else if ball { onlyBall += 1 }
        } }
        let union = both + onlyDrawn + onlyBall, a = Double(max(area, 1))
        // spill: replacement over things that are not ball. miss: real ball left showing.
        return ["iou": union > 0 ? Double(both) / Double(union) : 0, "spill": Double(onlyDrawn) / a, "miss": Double(onlyBall) / a]
    }

    static func run(_ args: [String]) async throws {
        let network = try await Network(package: args[2], edge: Int(args[3])!)
        let folder = URL(fileURLWithPath: args[4])
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("annotations.json"))) as! [String: Any]
        let images = Dictionary(uniqueKeysWithValues: (root["images"] as! [[String: Any]]).map { ("\($0["id"]!)", $0) })
        var rows = [[String: Any]]()
        for annotation in root["annotations"] as! [[String: Any]] {
            try autoreleasepool {
                let info = images["\(annotation["image_id"]!)"]!
                let w = info["width"] as! Int, h = info["height"] as! Int, name = info["file_name"] as! String
                let rle = annotation["segmentation"] as! [String: Any]
                guard let counts = rle["counts"] as? String else { return }
                let label = decode(counts: counts, w: w, h: h)
                let url = folder.appendingPathComponent(name)
                guard let image = CIImage(contentsOf: url), let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                let size = CGSize(width: w, height: h)
                let upright = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                guard upright.extent.width == size.width, upright.extent.height == size.height else { return }
                let bbox = annotation["bbox"] as! [Double]
                var row: [String: Any] = ["file": name, "width": w, "height": h, "split": info["split"] ?? "", "diameter": max(bbox[2], bbox[3]),
                    "roundness": Double(label.reduce(0) { $0 + Int($1) }) / max(1, bbox[2] * bbox[3])]
                let full = try network.full(upright)
                guard let guide = guideFrame(full), let fullMask = full.ballMask else { row["found"] = false; rows.append(row); return }
                row["found"] = true; row["score"] = full.ball!.score
                let sample = BallStyleSample(frame: guide)
                let fitted = BallReplacementFootprint.fit(image: source, sample: sample, measureTexture: true)
                func both(_ mask: BallMask) -> [String: Any] {
                    let matte = BallReplacementCoverage(mask: mask, fitted: fitted, size: size)
                    let raw = score({ x, y in mask.coverage(x: x / size.width, y: y / size.height) >= 0.5 },
                        bounds: CGRect(x: mask.rect.minX * size.width, y: mask.rect.minY * size.height,
                                       width: mask.rect.width * size.width, height: mask.rect.height * size.height),
                        label: label, w: w, h: h)
                    let drawn = score({ x, y in matte.coverage(x: x, y: y) >= 0.5 }, bounds: matte.bounds, label: label, w: w, h: h)
                    return ["raw": raw, "drawn": drawn, "radius": matte.footprint.radius,
                            "center": [matte.footprint.center.x, matte.footprint.center.y]]
                }
                row["full"] = both(fullMask)
                for context in [3.5, 2.5] {
                    if let roi = RFMaskCropRefiner.region(guide, size: size, context: context),
                       let mask = try network.crop(upright, roi: roi).ballMask { row["crop\(context)"] = both(mask) }
                }
                if let mask = try network.consensus(upright, guide: guide) { row["consensus"] = both(mask) }
                rows.append(row)
                print("\(rows.count) \(name)"); fflush(stdout)
            }
        }
        let result: [String: Any] = ["edge": Int(args[3])!, "dataset": folder.lastPathComponent, "calls": network.calls,
            "model_seconds": network.seconds, "rows": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[5]))
    }
}

// MARK: - Real clips

enum Clip {
    static let cs = CGColorSpaceCreateDeviceRGB()
    static let ci = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])

    static func spin(_ path: String) throws -> BallSurfaceTimeline? {
        guard path != "none", let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any],
              let rows = saved["rows"] as? [[String: Any]] else { return nil }
        let entries = rows.map { row -> BallSurfaceTimeline.Entry in
            let q = ((row["orientation"] ?? row["q"]) as! [NSNumber]).map(\.floatValue)
            let white = (row["white"] as? [NSNumber]).map { SIMD3($0[0].floatValue, $0[1].floatValue, $0[2].floatValue) }
            return .init(time: (row["time"] as! NSNumber).doubleValue, orientation: simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]),
                accepted: row["accepted"] as! Bool, visible: row["visible"] as! Bool, white: white)
        }
        return BallSurfaceTimeline(entries: entries, elapsed: 0, photographicExposure: (saved["photographicExposure"] as? NSNumber)?.doubleValue)
    }

    /// A touch is where the ball reaches its lowest point in the picture and rises again.
    static func contacts(_ frames: [RecordedFrame]) -> [Int] {
        let seen = frames.indices.filter { frames[$0].detected }
        var peaks = [Int]()
        for (position, i) in seen.enumerated() {
            let t = frames[i].time, y = frames[i].y
            var lowest = true, top = y, a = position
            while a > 0, frames[seen[a - 1]].time > t - 0.25 {
                a -= 1; let o = frames[seen[a]]
                if t - o.time < 0.14, o.y > y { lowest = false; break }
                top = min(top, o.y)
            }
            guard lowest else { continue }
            var b = position
            while b + 1 < seen.count, frames[seen[b + 1]].time < t + 0.25 {
                b += 1; let o = frames[seen[b]]
                if o.time - t < 0.14, o.y >= y { lowest = false; break }
                top = min(top, o.y)
            }
            if lowest, y - top > 0.012 { peaks.append(i) }
        }
        return peaks
    }

    static func decoder(_ source: URL, shortEdge: Int) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        let asset = AVURLAsset(url: source), video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        out.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: shortEdge)
        out.alwaysCopiesSampleData = false; reader.add(out)
        guard reader.startReading() else { throw reader.error! }
        return (reader, out)
    }
    static func nearest(_ frames: [RecordedFrame], _ time: Double) -> Int? {
        var low = 0, high = frames.count
        while low < high { let m = (low + high) / 2; if frames[m].time < time { low = m + 1 } else { high = m } }
        return [low - 1, low].filter { frames.indices.contains($0) && abs(frames[$0].time - time) < 0.003 }
            .min { abs(frames[$0].time - time) < abs(frames[$1].time - time) }
    }
    static func buffer(_ w: Int, _ h: Int) throws -> CVPixelBuffer {
        var p: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &p) == kCVReturnSuccess, let p else { throw NSError(domain: "Buffer", code: 1) }
        return p
    }
    static func image(_ p: CVPixelBuffer) -> CGImage {
        ci.createCGImage(CIImage(cvPixelBuffer: p), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(p), height: CVPixelBufferGetHeight(p)))!
    }
    struct Drawn { let pixels: CVPixelBuffer; let matte: BallReplacementCoverage? }

    /// The export path in BallStyleBurnIn, on the shared CPU renderer.
    static func render(_ t: BallEffectTrack, _ pixels: CVPixelBuffer, time: Double, skin: BallSkin, draw: Bool) throws -> Drawn {
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)), guide = t.replacementGuide(at: time)
        let fitted = guide.flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0, measureTexture: true) }
        let smear = t.smear(at: time, size: size)
        let matte = t.replacementMatte(at: time, fitted: fitted, size: size, smear: smear, photographicSmear: t.surfaceMotion?.photographicExposure != nil)
        guard draw else { return Drawn(pixels: pixels, matte: matte) }
        let target = try buffer(Int(size.width), Int(size.height)); ci.render(CIImage(cvPixelBuffer: pixels), to: target)
        let replacement = BallMaterialRenderer.replacement(footprint: t.usesBallMasks ? matte?.footprint : fitted, skin: skin, time: time,
            coverage: matte.map { m in { m.coverage(x: $0, y: $1) } }, coverageBounds: matte?.bounds,
            orientation: t.surfaceMotion?.renderOrientation(at: time), smear: smear, light: t.surfaceMotion?.light(at: time),
            background: matte.flatMap { BallReplacementBackground(pixels: pixels, matte: $0) })
        if let replacement {
            CVPixelBufferLockBaseAddress(target, []); defer { CVPixelBufferUnlockBaseAddress(target, []) }
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(target), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(target), space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
            BallMaterialRenderer.draw(in: ctx, size: size, sourceSize: size, skin: skin, sample: guide, time: time, replacement: replacement)
        }
        return Drawn(pixels: target, matte: matte)
    }
    static func tile(_ images: [CGImage], crop: CGRect, title: String, side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side * images.count, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        for (i, picture) in images.enumerated() {
            if let part = picture.cropping(to: crop) { ctx.draw(part, in: CGRect(x: i * side, y: 0, width: side, height: side)) }
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.yellow]))
        ctx.textPosition = CGPoint(x: 6, y: side - 18); CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }
    static func sheet(_ tiles: [CGImage], columns: Int, url: URL) throws {
        guard let first = tiles.first else { return }
        let rows = (tiles.count + columns - 1) / columns
        let ctx = CGContext(data: nil, width: first.width * columns, height: first.height * rows, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i, t) in tiles.enumerated() {
            ctx.draw(t, in: CGRect(x: (i % columns) * t.width, y: (rows - 1 - i / columns) * t.height, width: t.width, height: t.height))
        }
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.92])!.write(to: url)
    }

    static func run(_ args: [String]) async throws {
        let network = try await Network(package: args[2], edge: Int(args[3])!)
        let source = URL(fileURLWithPath: args[4]), folder = URL(fileURLWithPath: args[7])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let everyFrame = args.count > 8 && args[8] == "all"
        let window = args.count > 8 && !everyFrame ? Double(args[8])! : 0.05
        let skin = args.count > 9 ? BallSkin(rawValue: args[9])! : .volt
        var frames = try SavedAppearanceFrames.frames(URL(fileURLWithPath: args[5])).sorted { $0.time < $1.time }
        let before = frames, motion = try spin(args[6]), peaks = contacts(frames)
        let wanted = Set(frames.indices.filter { i in
            frames[i].detected && frames[i].ballMask != nil && (everyFrame || peaks.contains { abs(frames[$0].time - frames[i].time) <= window })
        })
        print("touches \(peaks.count), frames to re-mask \(wanted.count) of \(frames.count)"); fflush(stdout)
        // Same analysis pixels as the app: the 720 composition.
        var accepted = Set<Int>(), attempted = 0
        var (reader, out) = try await decoder(source, shortEdge: 720)
        while let sample = out.copyNextSampleBuffer() {
            try autoreleasepool {
                guard let i = nearest(before, sample.presentationTimeStamp.seconds), wanted.contains(i) else { return }
                attempted += 1
                let image = CIImage(cvPixelBuffer: CMSampleBufferGetImageBuffer(sample)!)
                if let mask = try network.consensus(image, guide: before[i]) { frames[i].ballMask = mask; accepted.insert(i) }
            }
        }
        print("re-masked \(accepted.count) of \(attempted), \(network.calls) model calls, \(network.seconds) s"); fflush(stdout)
        var old = BallEffectTrack(frames: before), new = BallEffectTrack(frames: frames)
        old.surfaceMotion = motion; new.surfaceMotion = motion
        // Review the frame at each touch and the moment just before contact.
        let step = before.count > 1 ? (before[before.count - 1].time - before[0].time) / Double(before.count - 1) : 1.0 / 60
        let reviewed = Set(peaks.flatMap { [$0, max(0, $0 - Int((0.02 / step).rounded()))] })
        (reader, out) = try await decoder(source, shortEdge: 1080)
        var rows = [[String: Any]](), tiles = [(Int, CGImage)]()
        while let sample = out.copyNextSampleBuffer() {
            try autoreleasepool {
                let pixels = CMSampleBufferGetImageBuffer(sample)!, time = sample.presentationTimeStamp.seconds
                guard let i = nearest(before, time) else { return }
                let draw = reviewed.contains(i)
                let a = try render(old, pixels, time: time, skin: skin, draw: draw), b = try render(new, pixels, time: time, skin: skin, draw: draw)
                func geometry(_ m: BallReplacementCoverage?) -> [Double] { m.map { [$0.footprint.center.x, $0.footprint.center.y, $0.footprint.radius] } ?? [] }
                rows.append(["index": i, "time": time, "remasked": accepted.contains(i), "touch": peaks.contains(i),
                             "before": geometry(a.matte), "after": geometry(b.matte)])
                if draw, let m = b.matte ?? a.matte {
                    let side = max(150, m.footprint.radius * 3.3), width = Double(CVPixelBufferGetWidth(pixels)), height = Double(CVPixelBufferGetHeight(pixels))
                    let crop = CGRect(x: m.footprint.center.x - side / 2, y: m.footprint.center.y - side / 2, width: side, height: side)
                        .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
                    let title = String(format: "%.2fs%@", time, accepted.contains(i) ? "" : " not re-masked")
                    tiles.append((i, tile([image(pixels), image(a.pixels), image(b.pixels)], crop: crop, title: title, side: 260)))
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "Decode", code: 1) }
        let ordered = tiles.sorted { $0.0 < $1.0 }.map(\.1), perSheet = 24
        for page in stride(from: 0, to: ordered.count, by: perSheet) {
            try sheet(Array(ordered[page..<min(page + perSheet, ordered.count)]), columns: 2,
                      url: folder.appendingPathComponent(String(format: "sheet-%02d.jpg", page / perSheet)))
        }
        let result: [String: Any] = ["source": source.lastPathComponent, "edge": Int(args[3])!, "touches": peaks.count, "frames": before.count,
            "attempted": attempted, "accepted": accepted.count, "calls": network.calls, "model_seconds": network.seconds, "rows": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: folder.appendingPathComponent("result.json"))
        print("done: \(ordered.count) tiles"); fflush(stdout)
    }
}

// MARK: - Motion smear

enum Blur {
    /// Variance of the Laplacian inside the ball, on luminance: one number for how sharp the print looks.
    static func sharpness(_ p: CVPixelBuffer, center: CGPoint, radius: Double) -> Double? {
        CVPixelBufferLockBaseAddress(p, .readOnly); defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(p)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(p), h = CVPixelBufferGetHeight(p), stride = CVPixelBufferGetBytesPerRow(p)
        func luma(_ x: Int, _ y: Int) -> Double {
            let q = base + y * stride + x * 4
            return 0.114 * Double(q[0]) + 0.587 * Double(q[1]) + 0.299 * Double(q[2])
        }
        let r = radius * 0.72, r2 = r * r
        let x0 = max(1, Int(center.x - r)), x1 = min(w - 2, Int(center.x + r)), y0 = max(1, Int(center.y - r)), y1 = min(h - 2, Int(center.y + r))
        guard x1 > x0 + 8, y1 > y0 + 8 else { return nil }
        var n = 0.0, sum = 0.0, squares = 0.0
        for y in y0...y1 { for x in x0...x1 {
            let dx = Double(x) - center.x, dy = Double(y) - center.y
            guard dx * dx + dy * dy <= r2 else { continue }
            let l = luma(x - 1, y) + luma(x + 1, y) + luma(x, y - 1) + luma(x, y + 1) - 4 * luma(x, y)
            n += 1; sum += l; squares += l * l
        } }
        guard n > 40 else { return nil }
        return squares / n - (sum / n) * (sum / n)
    }

    static func run(_ args: [String]) async throws {
        let source = URL(fileURLWithPath: args[2]), folder = URL(fileURLWithPath: args[5])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let skin = args.count > 6 ? BallSkin(rawValue: args[6])! : .arctic
        let frames = try SavedAppearanceFrames.frames(URL(fileURLWithPath: args[3])).sorted { $0.time < $1.time }
        let motion = try Clip.spin(args[4])
        var today = BallEffectTrack(frames: frames), sharp = today
        today.surfaceMotion = motion
        sharp.surfaceMotion = BallSurfaceTimeline(entries: motion?.entries ?? [], elapsed: 0, photographicExposure: 0)
        // Review the fastest moment of each run and the slowest moment after it: the two ends of any pulse.
        let review = frames.map { $0.time }.indices.filter { i in
            let t = frames[i].time, here = hypot(today.smear(at: t, size: CGSize(width: 1080, height: 1920)).dx, today.smear(at: t, size: CGSize(width: 1080, height: 1920)).dy)
            return here >= 4.5 && frames.indices.filter { abs(frames[$0].time - t) <= 0.12 }.allSatisfy { j in
                let o = today.smear(at: frames[j].time, size: CGSize(width: 1080, height: 1920)); return hypot(o.dx, o.dy) <= here }
        }
        var tiles = [(Int, CGImage)]()
        let (reader, out) = try await Clip.decoder(source, shortEdge: 1080)
        var rows = [[String: Any]](), movie: AVAssetWriter?, input: AVAssetWriterInput?, adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var first: CMTime?, last = CMTime.zero
        let panelW = 1620, panelH = 960, ctxSpace = CGColorSpaceCreateDeviceRGB()
        while let sample = out.copyNextSampleBuffer() {
            try autoreleasepool {
                let pixels = CMSampleBufferGetImageBuffer(sample)!, stamp = sample.presentationTimeStamp, time = stamp.seconds
                let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                let a = try Clip.render(today, pixels, time: time, skin: skin, draw: true)
                let b = try Clip.render(sharp, pixels, time: time, skin: skin, draw: true)
                var row: [String: Any] = ["time": time]
                if let m = a.matte {
                    let smear = today.smear(at: time, size: size), v = today.velocity(at: time, size: size)
                    row["smear"] = hypot(smear.dx, smear.dy)
                    row["speed"] = v.map { hypot($0.dx, $0.dy) } ?? 0
                    row["radius"] = m.footprint.radius
                    if let measured = BallReplacementMotionBlur.measured(pixels: pixels, body: m.footprint, suggested: smear) {
                        row["measured"] = hypot(measured.dx, measured.dy)
                    }
                    row["source"] = sharpness(pixels, center: m.footprint.center, radius: m.footprint.radius)
                    row["today"] = sharpness(a.pixels, center: m.footprint.center, radius: m.footprint.radius)
                    if let n = b.matte { row["nosmear"] = sharpness(b.pixels, center: n.footprint.center, radius: n.footprint.radius) }
                    if let i = Clip.nearest(frames, time), review.contains(i) {
                        let side = max(150, m.footprint.radius * 3.3)
                        let crop = CGRect(x: m.footprint.center.x - side / 2, y: m.footprint.center.y - side / 2, width: side, height: side)
                            .integral.intersection(CGRect(origin: .zero, size: size))
                        let length = hypot(today.smear(at: time, size: size).dx, today.smear(at: time, size: size).dy)
                        tiles.append((i, Clip.tile([Clip.image(pixels), Clip.image(a.pixels), Clip.image(b.pixels)], crop: crop,
                            title: String(format: "%.2fs smear %.0fpx", time, length), side: 260)))
                    }
                }
                rows.append(row)
                if movie == nil {
                    let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("compare.mov"), fileType: .mov)
                    let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: panelW, AVVideoHeightKey: panelH,
                        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000]])
                    i.expectsMediaDataInRealTime = false
                    let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: panelW, kCVPixelBufferHeightKey as String: panelH])
                    writer.add(i); guard writer.startWriting() else { throw writer.error! }
                    writer.startSession(atSourceTime: stamp); movie = writer; input = i; adaptor = ad; first = stamp
                }
                while input?.isReadyForMoreMediaData == false { Thread.sleep(forTimeInterval: 0.002) }
                let panel = try Clip.buffer(panelW, panelH)
                CVPixelBufferLockBaseAddress(panel, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(panel), width: panelW, height: panelH, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(panel),
                    space: ctxSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.interpolationQuality = .medium
                for (i, picture) in [Clip.image(pixels), Clip.image(a.pixels), Clip.image(b.pixels)].enumerated() {
                    let width = Double(panelH) * size.width / size.height
                    ctx.draw(picture, in: CGRect(x: Double(i) * 540 + (540 - width) / 2, y: 0, width: width, height: Double(panelH)))
                }
                for (i, text) in ["Real ball", "Today", "No fake blur"].enumerated() {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.white]))
                    ctx.textPosition = CGPoint(x: i * 540 + 14, y: panelH - 38); CTLineDraw(line, ctx)
                }
                CVPixelBufferUnlockBaseAddress(panel, [])
                adaptor?.append(panel, withPresentationTime: stamp); last = stamp
            }
        }
        input?.markAsFinished(); movie?.endSession(atSourceTime: last); await movie?.finishWriting()
        let ordered = tiles.sorted { $0.0 < $1.0 }.map(\.1)
        for page in Swift.stride(from: 0, to: ordered.count, by: 24) {
            try Clip.sheet(Array(ordered[page..<min(page + 24, ordered.count)]), columns: 2, url: folder.appendingPathComponent(String(format: "fast-%02d.jpg", page / 24)))
        }
        guard reader.status == .completed else { throw reader.error ?? NSError(domain: "Decode", code: 1) }
        let result: [String: Any] = ["source": source.lastPathComponent, "start": first?.seconds ?? 0, "rows": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: folder.appendingPathComponent("blur.json"))
        print("done \(rows.count)"); fflush(stdout)
    }
}

@main struct ContactCrop {
    static func main() async throws {
        let args = CommandLine.arguments
        switch args.dropFirst().first {
        case "labels": try await Labels.run(args)
        case "clip": try await Clip.run(args)
        case "blur": try await Blur.run(args)
        default: fatalError("labels | clip")
        }
    }
}
