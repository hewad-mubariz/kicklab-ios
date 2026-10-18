#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import SwiftUI

/// Phone side of the wall-targets experiment: the camera watches the projected
/// board, the overlay shows what the rules see, and hits light boxes on the
/// projector. Corners are set by tapping the four projected corner dots in
/// order (TL, TR, BR, BL), then dragging any handle to fine-tune. Recordings
/// save the video, detections and hits for review on the Mac.
struct WallTargetsView: View {
    @ObservedObject private var model = WallTargetsModel.shared
    @StateObject private var camera = WallTargetsCamera(onImpact: { impact in
        if impact.borderline { WallTargetsModel.shared.recordBorderline() }
        else { WallTargetsModel.shared.record(box: impact.box, u: impact.u, v: impact.v) }
    }, onAlignment: { WallTargetsModel.shared.applyAlignment($0) })
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var calibrating = false
    @State private var draft: [CGPoint] = []
    @State private var nextCorner = 0
    @State private var editedCorners: Set<Int> = []
    @State private var showResults = false
    @State private var showPlay = false
    @State private var autoPlayed = false
    @State private var liveFeed = WallTargetsLiveFeed()
    @AppStorage("wallTargets.macPreview") private var macPreview = false

    private static let cornerNames = ["top-left", "top-right", "bottom-right", "bottom-left"]
    private static let minPanelWidth: CGFloat = 150

    var body: some View {
        GeometryReader { geometry in
            // The camera takes the full height; the panel gets whatever width is left.
            let aspect = camera.frameSize.width / max(camera.frameSize.height, 1)
            let videoWidth = min(geometry.size.width - Self.minPanelWidth, geometry.size.height * aspect)
            HStack(spacing: 0) {
                cameraArea.frame(width: videoWidth)
                panel.frame(width: geometry.size.width - videoWidth)
            }
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showResults) { WallTargetsResultsView() }
        // Boxes only on screen (and so on a mirrored projector); the camera keeps
        // detecting underneath, since this view and its camera stay alive.
        .fullScreenCover(isPresented: $showPlay) {
            WallTargetsPlayView(model: model, camera: camera)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            WallTargetsAppDelegate.lock(.landscapeRight)
            UIApplication.shared.isIdleTimerDisabled = true
            camera.setCorners(model.corners)
            camera.start()
            applyMacPreview(macPreview)
            // Open straight into boxes only, so the wall never shows a camera picture;
            // long-press there to come back to this settings screen.
            if !autoPlayed {
                model.invalidateCalibration()
                autoPlayed = true
                showPlay = true
            }
        }
        .onDisappear {
            // Play mode covers this screen but must keep its camera detecting.
            guard !showPlay else { return }
            applyMacPreview(false)
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            WallTargetsAppDelegate.lock(.portrait)
        }
        .onChange(of: showPlay) { _, playing in
            if !playing { camera.start() }   // in case the cover's appearance paused it
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else {
                model.invalidateCalibration()
                camera.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification,
                                                         object: camera.session)) { _ in
            camera.stop(message: "Camera interrupted")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification,
                                                         object: camera.session)) { _ in
            if scenePhase == .active { camera.start() }
        }
    }

    private var cameraArea: some View {
        GeometryReader { geometry in
            let video = AVMakeRect(aspectRatio: camera.frameSize, insideRect: CGRect(origin: .zero, size: geometry.size))
            let corners = (calibrating ? draft : model.corners)
                .map { CGPoint(x: video.minX + $0.x * video.width, y: video.minY + $0.y * video.height) }
            ZStack(alignment: .topLeading) {
                WallTargetsPreview(session: camera.session)
                // The projector's board itself, warped onto the wall; see-through while
                // setting corners so the real dots stay visible.
                // In an overlay so its fixed drawing size never affects layout.
                Color.clear.overlay(alignment: .topLeading) {
                    WallTargetsWarpedBoard(model: model, corners: corners)
                }
                .opacity(calibrating || model.calibration == .ready ? 0.22 : 0)
                .allowsHitTesting(false)
                Canvas { context, _ in drawOverlay(context, video: video, corners: corners) }
                    .allowsHitTesting(false)
                if calibrating { calibrationLayer(video: video) }
            }
            .coordinateSpace(name: "wallCamera")
        }
        .background(.black)
        .clipped()
    }

    /// The browser view for the Mac (see WallTargetsLiveFeed); only runs while switched on.
    private func applyMacPreview(_ on: Bool) {
        if on {
            try? liveFeed.start()
            camera.setLiveFeed(liveFeed)
        } else {
            camera.setLiveFeed(nil)
            liveFeed.stop()
        }
    }

    // MARK: Overlay

    private func drawOverlay(_ context: GraphicsContext, video: CGRect, corners: [CGPoint]) {
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: video.minX + p.x * video.width, y: video.minY + p.y * video.height) }
        if calibrating, corners.count == 4, let board = WallBoard(topLeft: corners[0], topRight: corners[1],
                                                                  bottomRight: corners[2], bottomLeft: corners[3]) {
            var grid = Path()
            for u in 0...3 {
                grid.move(to: board.imagePoint(u: Double(u), v: 0)); grid.addLine(to: board.imagePoint(u: Double(u), v: 2))
            }
            for v in 0...2 {
                grid.move(to: board.imagePoint(u: 0, v: Double(v))); grid.addLine(to: board.imagePoint(u: 3, v: Double(v)))
            }
            context.stroke(grid, with: .color(.cyan.opacity(0.9)), lineWidth: 2)
        }
        if camera.trail.count > 1 {
            var trail = Path()
            trail.addLines(camera.trail.map(view))
            context.stroke(trail, with: .color(.orange.opacity(0.8)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        if let ball = camera.ball {
            let c = view(CGPoint(x: ball.x, y: ball.y)), r = ball.width * video.width / 2
            context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(ball.atWall ? .green : .yellow), lineWidth: 3)
        }
    }

    private func calibrationLayer(video: CGRect) -> some View {
        ZStack {
            Color.white.opacity(0.001)   // receives taps across the whole preview
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(coordinateSpace: .named("wallCamera")).onEnded { tap in
                    draft[nextCorner] = normalised(tap.location, in: video)
                    editedCorners.insert(nextCorner)
                    nextCorner = (nextCorner + 1) % 4
                })
            ForEach(0..<4, id: \.self) { index in
                let p = CGPoint(x: video.minX + draft[index].x * video.width, y: video.minY + draft[index].y * video.height)
                ZStack {
                    Circle().stroke(index == nextCorner ? Color.yellow : Color.cyan, lineWidth: 3)
                    Circle().fill(.cyan).frame(width: 6, height: 6)
                    Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.cyan).offset(x: 22, y: -22)
                }
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .position(p)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("wallCamera")).onChanged { drag in
                    draft[index] = normalised(drag.location, in: video)
                    editedCorners.insert(index)
                })
            }
            Text("Tap the \(Self.cornerNames[nextCorner]) corner dot, or drag a handle")
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.7), in: Capsule())
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
                .allowsHitTesting(false)
        }
    }

    private func normalised(_ p: CGPoint, in video: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - video.minX) / video.width)),
                y: min(1, max(0, (p.y - video.minY) / video.height)))
    }

    // MARK: Panel

    private var panel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wall targets").font(.headline)
                Label(model.projectorConnected ? "Projector on" : "No projector: use Screen Mirroring",
                      systemImage: model.projectorConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(model.projectorConnected ? .green : .orange)
                if model.cornersNotSet {
                    Label("Scoring paused · find all four corners first", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                // One button: records, hides every control and shows only the boxes.
                Button {
                    showPlay = true
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Label("Set up & play", systemImage: "play.fill").font(.headline)
                        Text("Align board · sample ball · play").font(.caption2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .tint(WallTargetsBoard.metalCyan)
                .foregroundStyle(.black)
                .disabled(calibrating)
                miniBoard
                roundTimer
                Picker("Colours", selection: $model.style) {
                    ForEach(WallBoardStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Toggle("Mac preview", isOn: $macPreview)
                    .font(.caption)
                    .onChange(of: macPreview) { _, on in applyMacPreview(on) }
                if macPreview {
                    Text("Open on the Mac:\nhttp://\(wallTargetsWiFiAddress() ?? "phone-ip"):\(WallTargetsLiveFeed.port)")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Button {
                    showResults = true
                } label: {
                    Label(camera.lastRecording == nil ? "Results" : "Results · new", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .font(.caption)
                Button(calibrating ? "Done" : "Set corners") {
                    if calibrating {
                        guard model.setCorners(draft) else { return }
                        camera.setCorners(draft)
                    } else {
                        model.pause()
                        camera.setScoringEnabled(false)
                        editedCorners = model.calibration == .ready ? Set(0..<4) : []
                        draft = model.corners
                        nextCorner = 0
                    }
                    calibrating.toggle()
                }
                .buttonStyle(.borderedProminent)
                .tint(calibrating ? .green : .blue)
                .disabled(calibrating && (editedCorners.count < 4 || !WallBoard.validCalibration(draft)))
                HStack(spacing: 6) {
                    Button("New round") { model.newRound() }
                    Button("Close") { dismiss() }
                }
                .buttonStyle(.bordered)
                .font(.caption)
                VStack(alignment: .leading, spacing: 2) {
                    Text(camera.status).font(.caption2.weight(.semibold))
                    Text(camera.handState == .held ? "Ball near hands · no score" :
                         camera.handState == .clear ? "Ball clear of hands" : "Checking hands")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "Capture %.0f / %d fps\nAnalysis %.0f fps · %.0f ms",
                                camera.deliveredFPS, camera.captureFPS, camera.processingFPS, camera.detectorMS))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(white: 0.08))
    }

    private var miniBoard: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(1...3, id: \.self) { column in
                        let box = row * 3 + column, lit = model.boxesHit.contains(box)
                        Text("\(box)")
                            .font(.subheadline.bold())
                            .foregroundStyle(lit ? .black : .white.opacity(0.7))
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(lit ? WallTargetsBoard.hitColor : Color.white.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 5))
                    }
                }
            }
        }
    }

    private var roundTimer: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            Group {
                if let time = model.clearTime {
                    Text(String(format: "Cleared %.1f s", time)).foregroundStyle(.green)
                } else if let start = model.roundStart {
                    Text(String(format: "%d/6 · %.1f s", model.boxesHit.count, timeline.date.timeIntervalSince(start)))
                } else {
                    Text("Hit a box to start")
                }
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }
}

/// The projector board, warped through the calibrated corners onto the wall in
/// the camera view, so the phone shows the same GPU-drawn targets as the wall.
private struct WallTargetsWarpedBoard: View {
    @ObservedObject var model: WallTargetsModel
    let corners: [CGPoint]   // view coordinates: TL, TR, BR, BL

    private static let size = CGSize(width: 1600, height: 900)

    var body: some View {
        let r = WallTargetsBoard.boardRect(in: Self.size)
        let board = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                     CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        if corners.count == 4, let h = WallBoard.homography(from: board, to: corners) {
            WallTargetsBoard(model: model, background: .clear)
                .frame(width: Self.size.width, height: Self.size.height)
                .projectionEffect(ProjectionTransform(Self.transform(h)))
        }
    }

    /// A 2D homography as a Core Animation transform (row vectors: p' = p * M).
    private static func transform(_ h: [Double]) -> CATransform3D {
        var m = CATransform3DIdentity
        m.m11 = h[0]; m.m21 = h[1]; m.m41 = h[2]
        m.m12 = h[3]; m.m22 = h[4]; m.m42 = h[5]
        m.m14 = h[6]; m.m24 = h[7]; m.m44 = 1
        return m
    }
}

private struct WallTargetsPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect   // whole analysed frame, so taps map 1:1
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Same unrotated landscape frame as the analysed buffers.
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }
    }
}
#endif
