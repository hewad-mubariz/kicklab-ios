import AVFoundation
import CoreImage
import SwiftUI
import Vision

// The analytics lab views of November 2026 (graphs, body zones, technique views and games) in the
// app, as a test build: the lab's drawing code (Analytics/LabViews, copied by the lab's
// scripts/fx/app-port.py) over the replay. The app has no body pose or foot side, so the first time
// a view is picked the session's video is read once: Apple Vision body pose on every frame (60 fps,
// 30 fps for clips over a minute), the foot of each touch by the lab's raised-ankle rule, and zoomed
// crops around each touch for the Touch Lens. Preview only; not in saved videos yet.

nonisolated enum LabViewID: String, CaseIterable, Identifiable, Sendable {
    case footRally = "foot-rally", leftRight = "left-right", beatGates = "beat-gates", arcMatch = "arc-match", controlSurf = "control-surf"
    case peakZone = "peak-zone", touchZone = "touch-zone", reach = "reach", footwork = "footwork"
    case nextTouch = "next-touch", touchSignature = "touch-signature", legSwing = "leg-swing", ballFlight = "ball-flight"
    case recoveryChain = "recovery-chain", controlWindow = "control-window", controlTopography = "control-topography"
    case ghostBall = "ghost-ball", zoneGame = "zone-game", heightLadder = "height-ladder", beatGame = "beat-game", touchLens = "touch-lens"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .footRally: "Foot Rally"
        case .leftRight: "Left · Right"
        case .beatGates: "Beat Gates"
        case .arcMatch: "Arc Match"
        case .controlSurf: "Control Surf"
        case .peakZone: "Peak Zone"
        case .touchZone: "Touch Zone"
        case .reach: "Reach"
        case .footwork: "Footwork"
        case .nextTouch: "Next Touch"
        case .touchSignature: "Touch Signature"
        case .legSwing: "Swing Volume"
        case .ballFlight: "Ball Flight"
        case .recoveryChain: "Recovery Chain"
        case .controlWindow: "Control Window"
        case .controlTopography: "Control Map"
        case .ghostBall: "Ghost Ball"
        case .zoneGame: "Zone Game"
        case .heightLadder: "Height Ladder"
        case .beatGame: "Beat Game"
        case .touchLens: "Touch Lens"
        }
    }

    var group: String {
        switch self {
        case .footRally, .leftRight, .beatGates, .arcMatch, .controlSurf: "Graphs"
        case .peakZone, .touchZone, .reach, .footwork: "Body"
        case .ghostBall, .zoneGame, .heightLadder, .beatGame: "Games"
        default: "Technique"
        }
    }

    var symbol: String {
        switch self {
        case .footRally, .leftRight: "shoeprints.fill"
        case .beatGates, .beatGame: "metronome.fill"
        case .arcMatch, .ballFlight: "point.topleft.down.to.point.bottomright.curvepath"
        case .controlSurf, .controlWindow: "rectangle.split.3x1"
        case .peakZone, .heightLadder: "arrow.up.to.line"
        case .touchZone: "figure.soccer"
        case .reach: "arrow.left.and.right"
        case .footwork: "figure.walk"
        case .nextTouch: "scope"
        case .touchSignature: "signature"
        case .legSwing: "figure.kickboxing"
        case .recoveryChain: "arrow.uturn.backward"
        case .controlTopography: "map.fill"
        case .ghostBall: "circle.dashed"
        case .zoneGame: "square.dashed"
        case .touchLens: "magnifyingglass.circle.fill"
        }
    }
}

/// Everything the lab views read for one session, in upright source pixels.
nonisolated final class LabViewsData: @unchecked Sendable {
    let video: URL
    let size: CGSize
    let ball: GraphScene.BallTrack
    let motion: AnalyticsMotion.Session
    let feet: FootChallenge.Session
    let rally: FootRally.Model
    let technique: Technique.Model
    let peak: BodyZones.PeakModel
    let touch: BodyZones.TouchModel
    let reach: BodyMoves.ReachModel
    let footwork: BodyMoves.FootworkModel
    let lensFrames: [Int: [(t: Double, image: CGImage)]]
    /// One letter per touch (L, R or U), for checking the foot rule.
    let sides: String

    init(video: URL, size: CGSize, ball: GraphScene.BallTrack, motion: AnalyticsMotion.Session, feet: FootChallenge.Session,
         body: BodyZones.Body, lensFrames: [Int: [(t: Double, image: CGImage)]], sides: String) {
        self.video = video; self.size = size; self.ball = ball; self.motion = motion; self.feet = feet
        rally = FootRally.Model(feet)
        technique = Technique.Model(body: body, ball: ball, touches: feet.times, motion: motion, sides: feet.touches.map(\.side))
        peak = BodyZones.PeakModel(body: body, ball: ball, touches: feet.times)
        touch = BodyZones.TouchModel(body: body, ball: ball, feet: feet)
        reach = BodyMoves.ReachModel(body: body, ball: ball, touchTimes: feet.times)
        footwork = BodyMoves.FootworkModel(body: body, ball: ball, touchTimes: feet.times)
        self.lensFrames = lensFrames; self.sides = sides
    }
}

nonisolated enum LabViewsPrep {
    enum Failure: LocalizedError {
        case noVideo, noTouches
        var errorDescription: String? { self == .noVideo ? "The video can’t be read." : "This session has no touches to analyse." }
    }

    private static let jointNames: [(String, VNHumanBodyPoseObservation.JointName)] = [
        ("nose", .nose), ("neck", .neck), ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
        ("leftWrist", .leftWrist), ("rightWrist", .rightWrist), ("root", .root),
        ("leftHip", .leftHip), ("rightHip", .rightHip), ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
        ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle)]

    static func prepare(video: URL, frames: [RecordedFrame], touches: [Double],
                        progress: @escaping @Sendable (Double) -> Void) async throws -> LabViewsData {
        guard !touches.isEmpty else { throw Failure.noTouches }
        try Task.checkCancellation()
        let access = try VideoStorageAccess.beginRead()
        defer { access.release() }
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let natural = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration).seconds
        let upright = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        let W = Double(upright.width), H = Double(upright.height)
        let orientation: CGImagePropertyOrientation = transform.b == 1 ? .right : transform.b == -1 ? .left : transform.a == -1 ? .down : .up

        // The counter's own ball track and person boxes (normalized upright, top-left).
        let sorted = frames.sorted { $0.time < $1.time }
        let rows = sorted.map { f in
            GraphScene.BallTrack.Row(time: f.time, x: f.detected ? f.x : nil, y: f.detected ? f.y : nil, width: f.detected ? f.width : nil,
                                     personX: f.person?.x, personY: f.person?.y, personHeight: f.person?.height)
        }
        let ball = GraphScene.BallTrack(GraphScene.BallTrack.File(track: rows), width: W, height: H)
        let touchTimes = touches.sorted()

        // One pass over the video: body pose on a 60 (or 30) fps grid, and the Touch Lens crops.
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw Failure.noVideo }
        defer { reader.cancelReading() }
        let step = duration > 60 ? 1.0 / 30 : 1.0 / 60
        var next = 0.0
        var poseFrames = [BodyZones.PoseFile.Frame]()
        let ci = CIContext(options: [.cacheIntermediates: false])
        let lensRects: [CGRect?] = touchTimes.map { t in
            ball.ball(at: t).map { b in
                let side = 2 * TechniqueDrawing.lensCropRadii * Double(b.r)
                return CGRect(x: Double(b.p.x) - side / 2, y: Double(b.p.y + b.r * 0.8) - side * 0.5, width: side, height: side).integral
            }
        }
        var lens = [Int: [(t: Double, image: CGImage)]]()
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let near = touchTimes.indices.filter { abs(touchTimes[$0] - t) <= 0.1 }
            if !near.isEmpty {
                var image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
                for k in near {
                    guard let r = lensRects[k] else { continue }
                    // Core Image is bottom-left; the crop rect is top-left.
                    let flipped = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height).intersection(image.extent)
                    if !flipped.isEmpty, let cut = ci.createCGImage(image, from: flipped) { lens[k, default: []].append((t, cut)) }
                }
            }
            guard t + 0.0005 >= next else { continue }
            while next <= t + 0.0005 { next += step }
            let request = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])
            var joints = [String: [Double]]()
            if let person = request.results?.max(by: { $0.confidence < $1.confidence }) {
                for (name, key) in jointNames {
                    if let p = try? person.recognizedPoint(key), p.confidence > 0.1 {
                        joints[name] = [Double(p.location.x) * W, (1 - Double(p.location.y)) * H, Double(p.confidence)]
                    }
                }
            }
            poseFrames.append(BodyZones.PoseFile.Frame(time: t, joints: joints))
            progress(min(0.99, t / max(0.1, duration)))
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? Failure.noVideo }
        let body = BodyZones.Body(BodyZones.PoseFile(frames: poseFrames))

        // The foot of each touch, the lab's rule (scripts/graphs/feet/classify.py, 33/33 on the owner's clip):
        // in the frames from 0.067 s before contact, the raised ankle is the higher one, and the foot is left
        // when it is on the person's left of the standing ankle. Which side is the person's left comes from
        // the hips over the whole clip. Vision's own left/right names swap when the legs cross.
        let hips = poseFrames.compactMap { f -> Bool? in
            guard let l = f.joints["leftHip"], let r = f.joints["rightHip"] else { return nil }
            return l[0] > r[0]
        }
        let facing: Double = hips.filter { $0 }.count * 2 > hips.count ? 1 : -1
        let minLift = 8 * W / 1080
        var sides = ""
        let feetInput = FootChallenge.Input(touches: touchTimes.map { t in
            var num = 0.0, den = 0.0
            for f in poseFrames where f.time >= t - 0.067 - 1e-6 && f.time <= t + 1e-6 {
                guard let a = f.joints["leftAnkle"], let b = f.joints["rightAnkle"], min(a[2], b[2]) >= 0.3 else { continue }
                let (up, down) = a[1] < b[1] ? (a, b) : (b, a)
                let lift = down[1] - up[1]
                guard lift >= minLift else { continue }
                num += (up[0] > down[0] ? 1 : -1) * facing * lift
                den += lift
            }
            let agree = den > 0 ? num / den : 0
            let side = abs(agree) >= 0.5 ? (agree > 0 ? "L" : "R") : "U"
            sides += side
            return FootChallenge.Input.Touch(time: t, side: side)
        })
        let feet = FootChallenge.Session(feetInput)

        // The suite's input: the ball and the person box on a 30 fps grid, and the touches with their foot.
        var samples = [AnalyticsSuite.Sample]()
        var lastPerson: PersonBox?
        var index = 0
        for i in 0..<Int(duration * 30) {
            let t = Double(i) / 30
            while index + 1 < sorted.count && sorted[index + 1].time <= t { index += 1 }
            guard index < sorted.count else { break }
            let f = sorted[index]
            if let p = f.person { lastPerson = p }
            let p = lastPerson
            samples.append(AnalyticsSuite.Sample(time: t, x: f.x * W, y: f.y * H, radius: f.width * W / 2,
                                                 valid: f.detected && f.score >= 0.5 && abs(f.time - t) <= 0.05,
                                                 personX: (p?.x ?? 0) * W, personY: (p?.y ?? 0) * H,
                                                 personWidth: (p?.width ?? 0) * W, personHeight: (p?.height ?? 0) * H))
        }
        let events = feet.touches.map { AnalyticsSuite.Event(time: $0.time, availableAt: $0.time, side: $0.side == .left ? "L" : $0.side == .right ? "R" : "U") }
        let input = AnalyticsSuite.Input(samples: samples, events: events, history: [], contextKey: "app-test", definitionsVersion: "analytics-lab-v1")
        progress(1)
        return LabViewsData(video: video, size: CGSize(width: W, height: H), ball: ball, motion: AnalyticsMotion.Session(input),
                            feet: feet, body: body, lensFrames: lens, sides: sides)
    }
}

nonisolated enum LabViewsDraw {
    /// Bottom of the frame, below the player's feet, 92% wide (as in the lab renders).
    static func strip(_ size: CGSize) -> CGRect {
        let width = size.width * 0.92, height = width / 342 * 124
        return CGRect(x: (size.width - width) / 2, y: size.height - size.height * 0.035 - height, width: width, height: height)
    }

    /// Draws `view` in a top-left, y-down context sized like the source video.
    static func draw(_ view: LabViewID, in c: CGContext, data d: LabViewsData, time t: Double) {
        let size = d.size, rect = strip(size)
        c.saveGState(); defer { c.restoreGState() }
        switch view {
        case .footRally, .beatGates, .arcMatch, .controlSurf:
            guard let graph = GraphScene.Graph(rawValue: view.rawValue) else { return }
            GraphScene.draw(graph, in: c, size: size, track: d.ball, motion: d.motion, rally: d.rally, time: t)
            switch view {
            case .footRally: FootRallyDrawing.draw(in: c, rect: rect, model: d.rally, time: t)
            case .beatGates: AnalyticsMotionDrawing.draw(in: c, rect: rect, graph: 0, session: d.motion, time: t)
            case .arcMatch: AnalyticsMotionDrawing.draw(in: c, rect: rect, graph: 1, session: d.motion, time: t)
            default: AnalyticsMotionDrawing.draw(in: c, rect: rect, graph: 2, session: d.motion, time: t)
            }
        case .leftRight: FootChallengeDrawing.draw(in: c, rect: rect, session: d.feet, time: t)
        case .peakZone: BodyZonesDrawing.peakZone(in: c, rect: rect, model: d.peak, time: t)
        case .touchZone: BodyZonesDrawing.touchZone(in: c, rect: rect, model: d.touch, time: t)
        case .reach: BodyMovesDrawing.reach(in: c, rect: rect, model: d.reach, time: t)
        case .footwork: BodyMovesDrawing.footwork(in: c, rect: rect, model: d.footwork, time: t)
        default:
            guard let technique = Technique.View(rawValue: view.rawValue) else { return }
            TechniqueDrawing.visible = nil
            TechniqueDrawing.lensFrames = d.lensFrames
            TechniqueDrawing.draw(technique, in: c, size: size, model: d.technique, time: t)
        }
    }
}

/// The picked lab view over the replay, redrawn whenever the playhead moves.
struct LabViewOverlay: View {
    let view: LabViewID
    let data: LabViewsData
    let time: Double
    let size: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, canvas in
            context.withCGContext { c in
                let s = canvas.width / max(1, data.size.width)
                c.scaleBy(x: s, y: s)
                LabViewsDraw.draw(view, in: c, data: data, time: time)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

/// Picker for the lab views (Analytics page), with the preparation status.
struct LabViewPicker: View {
    @Binding var selection: LabViewID?
    var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("New analytics (test)").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let status { Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).monospacedDigit() }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(nil, title: "Off", symbol: "xmark")
                    ForEach(LabViewID.allCases) { view in chip(view, title: view.title, symbol: view.symbol) }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ view: LabViewID?, title: String, symbol: String) -> some View {
        let selected = selection == view
        return Button {
            withAnimation(.snappy) { selection = view }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(height: 18)
                Text(title).font(.system(size: 10, weight: selected ? .semibold : .medium)).lineLimit(1)
                if let view { Text(view.group.uppercased()).font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.45)) }
            }
            .frame(width: 84, height: 62)
            .background(selected ? Color.green.opacity(0.18) : Color.white.opacity(0.05), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.green : .white.opacity(0.1), lineWidth: selected ? 1.5 : 0.5))
            .foregroundStyle(selected ? Color.green : .white.opacity(0.85))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("lab-view-\(view?.rawValue ?? "off")")
    }
}
