import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import kicklab

/// Every camera move on a real Power Shot, one test each, first to last in the editor's order.
///
/// Each test places its move the way tapping it in the editor does, saves the clip through the
/// exporter the Save button uses, and checks the saved video:
/// - it plays for as long as the edit says, at the clip's own frame rate;
/// - the move visibly changes the picture inside its block;
/// - it eases back and its last frame is the original picture (no snap back);
/// - the picture is untouched well before and after the block.
///
/// Each test also leaves the saved video and a contact sheet (the move on top, the original below)
/// in `artifacts/camera-move-review/` and in the test report. Run one test to look at one move, or
/// the class to go through them all. Run it on a simulator: the clip is read from `Fixtures/`.
final class ShotCameraMoveReviewTests: XCTestCase {
    func test00_EveryMoveHasItsOwnTest() {
        XCTAssertEqual(Self.order, ShotCameraMove.allCases, "Number a review test for each move, in the editor's order")
    }

    func test01_BallFollow() async throws { try await review(.follow) }
    func test02_ChaseCam() async throws { try await review(.chase) }
    func test03_Broadcast() async throws { try await review(.broadcast) }
    func test04_Handoff() async throws { try await review(.handoff) }
    func test05_WideAndDetail() async throws { try await review(.split) }
    func test06_DuoCam() async throws { try await review(.duo) }
    func test07_ImpactZoom() async throws { try await review(.impact) }
    func test08_TiltPunch() async throws { try await review(.tilt) }
    func test09_Recoil() async throws { try await review(.recoil) }
    func test10_ImpactRipple() async throws { try await review(.ripple) }
    func test11_LaunchWarp() async throws { try await review(.warp) }
    func test12_SpeedRamp() async throws { try await review(.ramp) }
    func test13_SlowMotion() async throws { try await review(.slowmo) }
    func test14_FreezeAndPath() async throws { try await review(.freeze) }
    func test15_FrozenArc() async throws { try await review(.arc) }
    func test16_InstantReplay() async throws { try await review(.replay) }
    func test17_BallLens() async throws { try await review(.lens) }
    func test18_Spotlight() async throws { try await review(.spotlight) }
    func test19_RackFocus() async throws { try await review(.focus) }
    func test20_BallStrobe() async throws { try await review(.strobe) }
    func test21_TargetLock() async throws { try await review(.lock) }

    /// Frozen Arc on imported kicks, when `artifacts/imported-shots/` holds clip + track cache pairs
    /// (`name.mp4` with `name.plist`). They stay out of git; without them this test is skipped.
    func test22_FrozenArcOnImportedClips() async throws {
        let folder = Self.repository.appendingPathComponent("artifacts/imported-shots")
        let clips = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "mp4" && FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("plist").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(clips.isEmpty, "No imported clips to try")
        for clip in clips {
            let shot = try await Self.makeShot(source: clip, cache: clip.deletingPathExtension().appendingPathExtension("plist"))
            try await review(.arc, on: shot, name: "arc-" + clip.deletingPathExtension().lastPathComponent)
        }
    }

    private static let order: [ShotCameraMove] = [
        .follow, .chase, .broadcast, .handoff, .split, .duo,
        .impact, .tilt, .recoil, .ripple, .warp,
        .ramp, .slowmo, .freeze, .arc, .replay,
        .lens, .spotlight, .focus, .strobe, .lock,
    ]

    // MARK: One move

    private func review(_ move: ShotCameraMove, on given: Shot? = nil, name label: String? = nil) async throws {
        let shot: Shot
        if let given { shot = given } else { shot = try await Self.loadShot() }
        let number = label ?? String(format: "%02d", (Self.order.firstIndex(of: move) ?? 0) + 1)

        // Placed the way the editor places a tapped move: its own range, fitted on the track.
        let empty = ShotCameraPlan(track: ShotCameraTrack(clips: [], strike: shot.strike), ball: shot.ball, flight: shot.flight,
                                   duration: shot.duration, aspect: shot.aspect, frameDuration: 1 / shot.frameRate)
        let preferred = move.defaultRange(strike: empty.strike, flightEnd: empty.flightEnd, playhead: empty.strike, duration: shot.duration)
        var camera = ShotCameraTrack(clips: [], strike: shot.strike)
        let id = camera.insert(move, range: camera.fit(preferred, duration: shot.duration) ?? preferred, duration: shot.duration)
        let clip = try XCTUnwrap(camera.clip(id))
        let plan = ShotCameraPlan(track: camera, ball: shot.ball, flight: shot.flight, duration: shot.duration,
                                  aspect: shot.aspect, frameDuration: 1 / shot.frameRate)
        let timeline = plan.timeline

        XCTAssertGreaterThanOrEqual(clip.start, 0)
        XCTAssertLessThanOrEqual(clip.end, shot.duration + 0.0001)
        XCTAssertGreaterThanOrEqual(clip.length, ShotCameraTrack.minimumLength - 0.0001)
        if move.isMoment { XCTAssertTrue(clip.contains(plan.strike), "\(move.title) should sit on the strike") }
        if move.needsPerson { XCTAssertTrue(plan.hasKicker, "\(move.title) frames the kicker, and this clip has him") }
        checkTiming(move, clip: clip, timeline: timeline, duration: shot.duration)

        // Frozen Arc's layers: in the app Vision outlines the kicker; the Simulator cannot run it, so a
        // Vision mask made on a Mac for that frame stands in when there is one (`<clip>-mask.png`).
        var arc: ShotArcLayers?
        if let moment = plan.arcMoment, let mask = shot.mask {
            arc = try await ShotArcLayers.build(source: shot.source, ball: shot.ball, time: moment, knownMask: mask)
        }
        // Saved the way the Save button saves it.
        let output = try await ShotEffectExporter.render(source: shot.source, track: shot.ball, style: .none,
                                                         camera: camera, flight: shot.flight, arc: arc) { _ in }
        defer { try? FileManager.default.removeItem(at: output) }
        let saved = AVURLAsset(url: output)
        let savedDuration = try await saved.load(.duration).seconds
        let savedTracks = try await saved.loadTracks(withMediaType: .video)
        let savedVideo = try XCTUnwrap(savedTracks.first)
        let savedRate = Double(try await savedVideo.load(.nominalFrameRate))
        XCTAssertEqual(savedDuration, timeline.outputDuration, accuracy: 0.06, "The saved video plays as long as the edit")
        XCTAssertEqual(savedRate, shot.frameRate, accuracy: 1.5, "The saved video keeps the clip's frame rate")

        // Every other saved frame inside the block, and every other one well clear of it.
        var samples: [(index: Int, source: Double, inside: Bool)] = []
        let count = Int((timeline.outputDuration * shot.frameRate).rounded(.down))
        for index in stride(from: 0, to: count, by: 2) {
            let location = timeline.locate(Double(index) / shot.frameRate)
            let inside = location.segment.clip == clip.id || clip.contains(location.source)
            let clear = location.segment.clip == nil && location.segment.kind == .play(rate: 1) && !location.segment.isReplay
                && (location.source < clip.start - 0.35 || location.source > clip.end + 0.35)
            if inside || clear { samples.append((index: index, source: location.source, inside: inside)) }
        }

        // The video and contact sheet to look at, written before the checks so a failure still leaves them.
        let name = label ?? number + "-" + Self.slug(move.title)
        let video = Self.reviewFolder.appendingPathComponent(name + "." + output.pathExtension)
        try? FileManager.default.removeItem(at: video)
        try FileManager.default.copyItem(at: output, to: video)
        let sheet = Self.reviewFolder.appendingPathComponent(name + ".png")
        let insideTimes = samples.filter { $0.inside }.map { Double($0.index) / shot.frameRate }
        try await Self.writeSheet(for: move, clip: clip, plan: plan, saved: saved, insideTimes: insideTimes, shot: shot,
                                  subtitle: String(format: "Block %.2f – %.2f s  ·  saved video %.2f s at %.0f fps",
                                                   clip.start, clip.end, savedDuration, savedRate),
                                  title: number + "  " + move.title, to: sheet)
        for url in [video, sheet] {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = url.lastPathComponent
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // Compared with the same clip saved without a camera move.
        let pictures = try await Self.brightness(of: output, rate: shot.frameRate, keeping: Set(samples.map { $0.index }))
        var strongest = (change: 0.0, at: 0.0)
        var ending = (change: 0.0, at: 0.0)
        var outside: [(at: Double, change: Double)] = []
        for sample in samples {
            guard let picture = pictures[sample.index] else { continue }
            let change = Self.change(picture, from: sample.source, in: shot)
            let at = Double(sample.index) / shot.frameRate
            if sample.inside {
                if change > strongest.change { strongest = (change: change, at: at) }
                if at >= ending.at { ending = (change: change, at: at) }
            } else {
                outside.append((at: at, change: change))
            }
        }
        let quiet = outside.map { $0.change }.sorted()
        let grain = quiet.isEmpty ? 0 : quiet[quiet.count / 2]
        XCTAssertFalse(insideTimes.isEmpty, "\(move.title) has frames in its block")
        // Slow Motion changes time, not the picture; its timing is checked above.
        if move != .slowmo {
            XCTAssertGreaterThan(strongest.change, max(0.0015, grain * 3), "\(move.title) should visibly change the picture inside its block")
        }
        XCTAssertLessThan(ending.change, 0.03, String(format: "%@ should end on the original, but its last frame (%.2f s) still differs by %.1f%%",
                                                      move.title, ending.at, ending.change * 100))
        let leaks = outside.filter { $0.change > 0.015 }
        XCTAssertTrue(leaks.isEmpty, "\(move.title) changed the picture outside its block at "
            + leaks.map { String(format: "%.2f s (%.1f%%)", $0.at, $0.change * 100) }.joined(separator: ", "))

        if move == .arc {
            let scene = plan.arcScene
            print(String(format: "Camera review %@ scene: strike %.2f s, focal %.0f px, horizon row %.0f px, phone %.2f m up, kicker %.1f m, backdrop %.1f m, ground %@, outline %@",
                         number, plan.strike, scene.focal * 720, scene.horizon * 720, scene.cameraHeight, scene.kickerDepth, scene.backdropDepth,
                         scene.fitted ? "fitted from people" : "guessed", arc == nil ? "from the clip alone" : "Vision mask (Mac)"))
        }
        print(String(format: "Camera review %@ %@: block %.2f – %.2f s, saved %.2f s at %.0f fps, strongest change %.1f%% at %.2f s, last frame %.1f%% from the original, outside at most %.1f%%. %@",
                     number, move.title, clip.start, clip.end, savedDuration, savedRate, strongest.change * 100, strongest.at,
                     ending.change * 100, (quiet.last ?? 0) * 100, video.path))
    }

    /// Time moves change how long the video plays; every other move keeps the clip's length.
    private func checkTiming(_ move: ShotCameraMove, clip: ShotCameraClip, timeline: ShotEditTimeline, duration: Double) {
        func rate(_ kind: ShotEditTimeline.Kind) -> Double? {
            if case .play(let rate) = kind { return rate }
            return nil
        }
        switch move {
        case .ramp, .slowmo:
            let slowest = timeline.segments.compactMap { rate($0.kind) }.min() ?? 1
            XCTAssertEqual(slowest, clip.settings.rate, accuracy: 0.02, "\(move.title) slows to its rate")
            XCTAssertGreaterThan(timeline.outputDuration, duration + 0.2, "\(move.title) makes the video longer")
        case .freeze, .arc:
            let hold = timeline.segments.first { $0.kind == .hold }?.outputLength ?? 0
            XCTAssertEqual(hold, min(move == .arc ? 4 : 3, max(0.2, clip.settings.hold)), accuracy: 0.02, "\(move.title) holds for its hold time")
            XCTAssertEqual(timeline.outputDuration, duration + hold, accuracy: 0.02)
        case .replay:
            XCTAssertTrue(timeline.segments.contains { $0.kind == .rewind }, "Instant Replay rewinds")
            XCTAssertTrue(timeline.segments.contains { $0.isReplay && abs((rate($0.kind) ?? 0) - clip.settings.rate) < 0.01 },
                          "Instant Replay plays again at its slow rate")
        default:
            XCTAssertEqual(timeline.outputDuration, duration, accuracy: 0.001, "\(move.title) keeps the clip's length")
        }
    }

    // MARK: The shot

    private struct Shot {
        var source: URL
        var ball: BallEffectTrack
        var flight: ShotFlight?
        var duration: Double
        var aspect: Double
        var frameRate: Double
        /// The clip saved with no camera move, as brightness by frame number: what every saved frame is compared with.
        var plain: [Int: [UInt8]]
        /// The kicker's outline at the strike, made by Vision on a Mac (`<clip>-mask.png`), if any.
        var mask: CGImage?
        /// A strike moment set by hand (`<clip>.json`, `{"strike": 1.52}`), as dragging the strike marker does.
        var strike: Double?
    }

    private enum Failure: Error { case noVideo(String), unreadable(String), sheet }

    nonisolated(unsafe) private static var loaded: Shot?

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    }

    private static var repository: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// Kept out of git (`artifacts/`); falls back to the runner's temporary folder off the simulator.
    private static var reviewFolder: URL {
        let folder = repository.appendingPathComponent("artifacts/camera-move-review", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil { return folder }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("camera-move-review", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// The 2.5 s Power Shot and its ball track (the app's detections, cached as the replay caches them).
    private static func loadShot() async throws -> Shot {
        if let loaded { return loaded }
        let shot = try await makeShot(source: fixtures.appendingPathComponent("power-shot-2.5s.mp4"),
                                      cache: fixtures.appendingPathComponent("power-shot-2.5s-track.plist"))
        loaded = shot
        return shot
    }

    /// A clip, its cached ball track, and the clip saved with no camera move to compare against.
    private static func makeShot(source: URL, cache: URL) async throws -> Shot {
        let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: cache))
        let ball = BallEffectTrack(frames: stored.map(\.frame))
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = tracks.first else { throw Failure.noVideo(source.lastPathComponent) }
        let upright = EffectVideoGeometry.displaySize(naturalSize: try await video.load(.naturalSize),
                                                      transform: try await video.load(.preferredTransform))
        let aspect = Double(upright.width / max(1, upright.height))
        let duration = try await asset.load(.duration).seconds
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let flight = ShotFlight.find(in: ball, aspect: aspect)
        let plainVideo = try await ShotEffectExporter.render(source: source, track: ball, style: .none, flight: flight) { _ in }
        defer { try? FileManager.default.removeItem(at: plainVideo) }
        let plain = try await brightness(of: plainVideo, rate: frameRate, keeping: nil)
        let base = source.deletingPathExtension()
        let maskURL = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-mask.png")
        let mask = CGImageSourceCreateWithURL(maskURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        let settings = (try? Data(contentsOf: base.appendingPathExtension("json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] }
        return Shot(source: source, ball: ball, flight: flight, duration: duration, aspect: aspect, frameRate: frameRate, plain: plain,
                    mask: mask, strike: settings?["strike"])
    }

    // MARK: Comparing pictures

    private static let compareWidth = 360, compareHeight = 640

    /// A saved video's frames as brightness at the comparison size, by frame number.
    private static func brightness(of url: URL, rate: Double, keeping wanted: Set<Int>?) async throws -> [Int: [UInt8]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else { throw Failure.noVideo(url.lastPathComponent) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else { throw Failure.unreadable(url.lastPathComponent) }
        var frames: [Int: [UInt8]] = [:]
        while let sample = output.copyNextSampleBuffer() {
            let index = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * rate).rounded())
            guard wanted?.contains(index) ?? true, let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames[index] = brightness(pixels)
        }
        guard reader.status == .completed else { throw Failure.unreadable(url.lastPathComponent) }
        return frames
    }

    /// Brightness averaged over 2 × 2 pixels at the comparison size, which also evens out encoder grain.
    private static func brightness(_ pixels: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels), row = CVPixelBufferGetBytesPerRow(pixels)
        var result = [UInt8](repeating: 0, count: compareWidth * compareHeight)
        guard width > 1, height > 1, let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return result }
        func luma(_ x: Int, _ y: Int) -> Int {
            let p = base + y * row + x * 4
            return Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29
        }
        for y in 0..<compareHeight {
            let sy = min(height - 2, y * height / compareHeight)
            for x in 0..<compareWidth {
                let sx = min(width - 2, x * width / compareWidth)
                let sum = luma(sx, sy) + luma(sx + 1, sy) + luma(sx, sy + 1) + luma(sx + 1, sy + 1)
                result[y * compareWidth + x] = UInt8(min(255, sum >> 10))
            }
        }
        return result
    }

    /// Share of the picture whose brightness is more than 20 levels away from the plain save of the
    /// same source moment. The best of the neighbouring frames counts, so frame rounding never does.
    private static func change(_ picture: [UInt8], from source: Double, in shot: Shot) -> Double {
        let frame = Int((source * shot.frameRate + 0.001).rounded(.down))
        var best = 1.0
        for index in frame - 1...frame + 1 {
            guard let plain = shot.plain[index] else { continue }
            best = min(best, share(picture, plain))
        }
        return best
    }

    private static func share(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var count = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > 20 { count += 1 }
            }
        }
        return Double(count) / Double(a.count)
    }

    // MARK: Contact sheet

    private struct Cell {
        var title: String
        var note: String
        var top: CGImage?
        var bottom: CGImage?
    }

    /// Before the block, through it (and its strike), and after it: the move on top, the original below.
    private static func writeSheet(for move: ShotCameraMove, clip: ShotCameraClip, plan: ShotCameraPlan, saved: AVAsset,
                                   insideTimes: [Double], shot: Shot, subtitle: String, title: String, to url: URL) async throws {
        let timeline = plan.timeline
        var picks: [(label: String, output: Double)] = []
        if clip.start >= 0.2 { picks.append((label: "Before", output: timeline.outputTime(for: clip.start - 0.25))) }
        if let first = insideTimes.first, let last = insideTimes.last {
            picks += [0.05, 0.35, 0.65, 0.95].map { (label: "In block", output: first + (last - first) * $0) }
        }
        if clip.contains(plan.strike) { picks.append((label: "Strike", output: timeline.outputTime(for: plan.strike))) }
        if clip.end + 0.3 < shot.duration { picks.append((label: "After", output: timeline.outputTime(for: clip.end + 0.3))) }
        picks.sort { $0.output < $1.output }

        let savedFrames = AVAssetImageGenerator(asset: saved)
        let originalFrames = AVAssetImageGenerator(asset: AVURLAsset(url: shot.source))
        for generator in [savedFrames, originalFrames] {
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 360, height: 640)
        }
        var cells: [Cell] = []
        for pick in picks {
            let frame = (pick.output * shot.frameRate).rounded(.down)
            let source = timeline.locate(frame / shot.frameRate).source
            let sourceFrame = (source * shot.frameRate + 0.001).rounded(.down)
            let top = try? await savedFrames.image(at: CMTime(seconds: (frame + 0.25) / shot.frameRate, preferredTimescale: 60_000)).image
            let bottom = try? await originalFrames.image(at: CMTime(seconds: (sourceFrame + 0.25) / shot.frameRate, preferredTimescale: 60_000)).image
            cells.append(Cell(title: String(format: "%@  %.2f s", pick.label, frame / shot.frameRate),
                              note: String(format: "Original  %.2f s", sourceFrame / shot.frameRate), top: top, bottom: bottom))
        }

        let cellWidth: CGFloat = 180, cellHeight: CGFloat = 320, gap: CGFloat = 8, header: CGFloat = 80, label: CGFloat = 20
        let width = gap + CGFloat(max(1, cells.count)) * (cellWidth + gap)
        let height = header + 2 * (label + cellHeight + gap)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.sheet }
        context.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let white = SIMD3<Float>(1, 1, 1), lime = SIMD3<Float>(0.8, 1, 0.43)
        var captions = [
            ShotCaption(text: title, position: CGPoint(x: gap, y: 10), size: 22, alpha: 1, color: lime),
            ShotCaption(text: move.detail, position: CGPoint(x: gap, y: 38), size: 12, alpha: 0.85, color: white, bold: false),
            ShotCaption(text: subtitle, position: CGPoint(x: gap, y: 56), size: 12, alpha: 0.6, color: white, bold: false),
        ]
        for (column, cell) in cells.enumerated() {
            let x = gap + CGFloat(column) * (cellWidth + gap)
            for (row, image) in [cell.top, cell.bottom].enumerated() {
                let top = header + CGFloat(row) * (label + cellHeight + gap)
                captions.append(ShotCaption(text: row == 0 ? cell.title : cell.note, position: CGPoint(x: x, y: top + 3),
                                            size: 11, alpha: row == 0 ? 0.95 : 0.6, color: white, bold: row == 0))
                if let image {
                    context.draw(image, in: CGRect(x: x, y: height - (top + label + cellHeight), width: cellWidth, height: cellHeight))
                }
            }
        }
        ShotCaptionRenderer.draw(captions, in: context, height: height)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw Failure.sheet }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.sheet }
    }

    private static func slug(_ title: String) -> String {
        title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }
}
