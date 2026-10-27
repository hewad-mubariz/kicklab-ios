import AVFoundation
import SwiftUI

/// The Power Shot editor, laid out and moving like the juggling one. The processing screen
/// runs while the ball is tracked through every frame, then hands over: the video settles in,
/// the chrome builds, and Customize opens its effects, graph and camera tools.
struct ShotEffectsReplayView: View {
    /// Makes the playable upright video, and its distance estimate when the shot has one.
    /// Runs as the first step of the processing screen.
    let prepare: @MainActor () async throws -> (URL, BallDistanceTimeline?)
    /// Keeps the finished ball track so reopening a shot skips the processing screen.
    var trackCache: URL?
    /// Debug review only: hold this moment once the editor is open.
    var holdAt: Double?
    /// Debug review only: open on this graph style.
    private var pinnedGraph: ShotGraphStyle?
    let onClose: () -> Void

    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var look: ShotReplayLook
    private enum ProRequest {
        case tool(ShotTool)
        case look(ShotReplayLook)
    }
    @State private var pendingProRequest: ProRequest?
    @State private var showsProPaywall = false
    private var committedLook: ShotReplayLook { look.allowed(isPro: subscriptions.isPro) }
    private var displayedLook: ShotReplayLook { committedLook }

    private var style: ShotTrailStyle {
        get { displayedLook.style }
        nonmutating set { changeLook { $0.style = newValue } }
    }
    private var intensity: Double {
        get { displayedLook.intensity }
        nonmutating set { changeLook { $0.intensity = newValue } }
    }
    private var graphStyle: ShotGraphStyle {
        get { displayedLook.graphStyle }
        nonmutating set { changeLook { $0.graphStyle = newValue } }
    }
    private var showGraph: Bool {
        get { displayedLook.showGraph }
        nonmutating set { changeLook { $0.showGraph = newValue } }
    }
    private var camera: ShotCameraTrack {
        get { displayedLook.camera }
        nonmutating set { changeLook { $0.camera = newValue } }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var showOriginal = false
    /// The clock of the player's current item; follows the plan once its replay is rebuilt.
    @State private var playbackTimeline = ShotEditTimeline()
    /// The camera track, worked out for the current edit.
    @State private var plan: ShotCameraPlan?
    @State private var atlas: ShotSpriteAtlas?
    @State private var atlasTask: Task<Void, Never>?
    /// Frozen Arc's layers, cut at its frozen moment.
    @State private var arcLayers: ShotArcLayers?
    @State private var arcTask: Task<Void, Never>?
    /// Slowed stretches rendered with in-between frames, and the render playing now.
    @State private var slowMotion: ShotSlowMotion?
    @State private var slowMotionTask: Task<Void, Never>?
    @State private var playbackSlowMotion: ShotSlowMotion?
    @State private var makingSlowMotion = false
    @State private var still: CGImage?
    @State private var cameraSelection: UUID?
    @State private var targetEdit: UUID?
    @State private var outputTime = 0.0
    /// Output time at which a block preview stops.
    @State private var previewEnd: Double?
    @State private var pendingPreview: UUID?
    @State private var preparingCamera = false
    @State private var cameraTask: Task<Void, Never>?
    @State private var cameraRevision = 0
    @State private var sourceFrames = ShotSourceFrames()
    @State private var frameIndexTask: Task<Void, Never>?
    @State private var track: BallEffectTrack?
    @State private var flight: ShotFlight?
    @State private var trackingProblem: String?
    @State private var source: URL?
    @State private var distance: BallDistanceTimeline?

    // Processing
    @State private var processing: Bool
    @State private var progress = 0.02
    @State private var step = 0
    @State private var processingInfo: VideoProcessingInfo?

    // Editor
    @State private var shown = false
    @State private var showToolbox = false
    @State private var toolPage: ShotTool?
    @State private var panelTop: CGFloat = 0
    @State private var chromeBottom: CGFloat = 0
    @State private var loopPreview = false
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime = 0.0
    @State private var duration = 1.0
    @State private var timeObserver: Any?
    @State private var sourceSize = CGSize(width: 9, height: 16)
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var restarting = false
    @State private var playbackError: String?
    @State private var positionBeforePreview: Double?

    // Saving
    @State private var save = ReplayDownloader.Phase.idle
    @State private var saveProgress = 0.0
    @State private var exportID = UUID()
    @State private var needsForeground = false
    @State private var savedURL: URL?
    @State private var savedLook: SavedLook?
    @State private var savedDuration: Double?
    @State private var thumbnail: CGImage?
    @State private var toast: ShotToast?
    @State private var showSharePanel = false
    @State private var shareItem: ReplayShareItem?
    @State private var exportTask: Task<Void, Never>?

    private enum ShotToast: Equatable { case saved, failed(String) }
    private struct SavedLook: Equatable {
        let trail: ShotTrailStyle
        let intensity: Double
        let camera: ShotCameraTrack
    }
    private var currentLook: SavedLook { SavedLook(trail: style, intensity: intensity, camera: camera) }
    private var hasBallTrack: Bool { track?.samples.isEmpty == false }
    private var strike: Double { plan?.strike ?? camera.strike ?? flight?.launch ?? 0 }
    private var showingSource: Bool { showOriginal || targetEdit != nil }
    private var canSave: Bool {
        !showOriginal && targetEdit == nil && !preparingCamera && source != nil
    }

    init(video: URL, style: ShotTrailStyle = .glowTrail, trackCache: URL? = nil,
         holdAt: Double? = nil, graph: ShotGraphStyle? = nil, onClose: @escaping () -> Void) {
        self.init(style: style, trackCache: trackCache, holdAt: holdAt, graph: graph, onClose: onClose) { (video, nil) }
    }

    init(style: ShotTrailStyle = .glowTrail, trackCache: URL? = nil, holdAt: Double? = nil, graph: ShotGraphStyle? = nil,
         onClose: @escaping () -> Void, prepare: @escaping @MainActor () async throws -> (URL, BallDistanceTimeline?)) {
        self.prepare = prepare
        pinnedGraph = graph
        self.trackCache = trackCache
        self.holdAt = holdAt
        self.onClose = onClose
        _look = State(initialValue: ShotReplayLook(style: style))
        let cached = trackCache.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        _processing = State(initialValue: !cached)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !processing { editor.transition(.opacity) }
            if processing {
                ProcessingOverlay(progress: progress, stepIndex: step, onCancel: onClose, labels: .powerShot,
                                  videoInfo: processingInfo)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .task { await load() }
        .onDisappear { tearDown() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shot-effects")
    }

    private var editor: some View {
        ZStack {
            videoCanvas.ignoresSafeArea()
                .sessionEntrance(shown, offset: 0, scale: 1.04)
            // Glass is drawn by its container and ignores the fade-in, so the chrome waits until the
            // editor is ready instead of floating over a black screen.
            if shown {
            VStack(spacing: 0) {
                topBar.sessionEntrance(shown, order: 1, offset: -16)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { chromeBottom = $0 }
                    .overlay(alignment: .top) { toastView.padding(.top, 58).padding(.horizontal, 20) }
                Spacer(minLength: 12)
                // Customize and the toolbox share one glass identity, so the pill morphs into the panel.
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 0) {
                        if showToolbox {
                            ShotToolbox(style: lookBinding(\.style), intensity: lookBinding(\.intensity), graphStyle: lookBinding(\.graphStyle), showGraph: lookBinding(\.showGraph),
                                        camera: lookBinding(\.camera), cameraSelection: $cameraSelection, targetEdit: $targetEdit,
                                        original: $showOriginal, plan: plan, still: still, duration: duration,
                                        flight: flight, distance: distance, time: currentTime, isPlaying: isPlaying, onTogglePlayback: togglePlay,
                                        hasBallTrack: hasBallTrack, source: source, frames: sourceFrames,
                                        onSeek: { pause(); seek(to: $0) }, onPreview: preview,
                                        page: $toolPage, onClose: { showToolbox = false },
                                        isPro: subscriptions.isPro, onUnlockTool: { requestPro(.tool($0)) },
                                        makingSmoothMotion: makingSlowMotion)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                                    withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { panelTop = top }
                                }
                                .glassEffectID("customize", in: glass)
                                .padding(.horizontal, 20).padding(.bottom, 18)
                        } else if showSharePanel {
                            ReplaySharePanel(onShare: share, onClose: { showSharePanel = false }, onRecordAnother: nil, onDone: onClose)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                                .transition(.sessionRise)
                        } else {
                            if subscriptions.isPro, let distance {
                                let reading = distance.state(at: currentTime)
                                BallDistanceReadout(value: reading.valueLabel, detail: reading.status.label,
                                    paused: reading.status == .paused || reading.status == .needsSetup, compact: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24).padding(.bottom, 12)
                                    .sessionEntrance(shown, order: 2)
                            }
                            if let trackingProblem {
                                Label(trackingProblem, systemImage: "exclamationmark.triangle")
                                    .font(.footnote).foregroundStyle(.white.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 24).padding(.bottom, 12)
                                    .accessibilityIdentifier("shot-effects-problem")
                            }
                            if subscriptions.isPro {
                                ShotFlightPanel(style: graphStyle, flight: flight, time: currentTime, showGraph: showGraph,
                                                palette: style.palette, distance: distance)
                                    .padding(.horizontal, 24).padding(.bottom, 10).allowsHitTesting(false)
                                    .sessionEntrance(shown, order: 2)
                                    .transition(.sessionRise)
                            }
                            playbackBar.padding(.horizontal, 24).padding(.bottom, 14)
                                .sessionEntrance(shown, order: 3)
                                .transition(.sessionRise)
                            bottomControls.padding(.horizontal, 24).padding(.bottom, 16)
                                .sessionEntrance(shown, order: 4, offset: 24)
                        }
                    }
                }
            }
            .transition(.sessionRise)
            }
        }
        .onChange(of: showToolbox) { _, open in
            if !open { if toolPage == .graph { pause() }; cameraSelection = nil; targetEdit = nil; toolPage = nil; panelTop = 0 }
        }
        .onChange(of: toolPage) { _, page in
            if page != .camera { showOriginal = false; cameraSelection = nil; targetEdit = nil }
            if page != .graph && !loopPreview { pause() }
            // Effects loop the flight, so every pick is seen on the moving ball.
            if page == .effects { startPreviewLoop() } else { stopPreviewLoop() }
            if page != .effects { restorePreviewPosition() }
            // The camera editor opens on the strike, with its flag under the playhead, on a real frame.
            if page == .camera, !sourceFrames.isEmpty { pause(); seek(to: sourceFrames.nearest(plan?.strike ?? currentTime)) }
        }
        .onChange(of: style) { _, next in
            ProductAnalytics.shared.track(.effectSelected(.ballDistance, effect: next.rawValue))
            saveOutdated()
        }
        .onChange(of: intensity) { _, _ in saveOutdated() }
        .onChange(of: camera) { _, _ in
            saveOutdated()
            rebuildPlan()
            updateCameraMedia()
        }
        .onChange(of: targetEdit) { _, edit in
            if let clip = camera.clip(edit) { pause(); seek(to: max(clip.start, min(clip.end, strike))) }
        }
        .onChange(of: subscriptions.isPro) { _, active in
            if !active {
                pendingProRequest = nil; showOriginal = false; cameraSelection = nil; targetEdit = nil
                if toolPage != .effects { toolPage = nil }
            }
            saveOutdated()
        }
        .sheet(isPresented: $showsProPaywall, onDismiss: finishPaywall) {
            ProPaywallView(onClose: { showsProPaywall = false }, onUnlocked: {
                showsProPaywall = false
            })
            .presentationDetents([.large])
        }
        .sheet(item: $shareItem) { item in
            ReplayShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: showToolbox)
        .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: showSharePanel)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: toast)
        .sensoryFeedback(.impact(weight: .light), trigger: showToolbox)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            roundButton("chevron.left", label: "Close editor", action: onClose)
                .accessibilityIdentifier("shot-effects-close")
            Spacer(minLength: 0)
            HStack(spacing: 7) {
                Circle().fill(SessionStyle.mint).frame(width: 7, height: 7)
                Text("POWER SHOT").font(.system(size: 12, weight: .semibold)).tracking(1.2)
            }
            .padding(.horizontal, 14).frame(height: 32)
            .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 0)
            ReplayDownloadButton(phase: save, progress: saveProgress, action: download, needsForeground: needsForeground)
                .disabled(!canSave)
                .opacity(canSave ? 1 : 0.45)
                .accessibilityIdentifier("shot-effects-save")
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Group {
                switch toast {
                case .saved:
                    ReplaySavedToast(thumbnail: thumbnail, detail: "1080p · \(ExportPreviewTime.label(at: savedDuration ?? duration))")
                case .failed(let message):
                    ReplaySavedToast(thumbnail: nil, detail: "", failure: message)
                }
            }
            .transition(.sessionDrop)
        }
    }

    private var videoCanvas: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            let fullSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            // While customizing, the frame shrinks into the space above the panel.
            let editing = showToolbox && panelTop > chromeBottom + 120
            let top = chromeBottom + 10, bottom = panelTop - 12
            let fit = editing ? max(0.1, min(1, (bottom - top) / fullSize.height)) : 1
            let size = CGSize(width: fullSize.width * fit, height: fullSize.height * fit)
            ZStack {
                if let player {
                    ShotVideoSurface(player: player, style: showingSource || !hasBallTrack ? .none : style, intensity: intensity,
                                     track: track ?? BallEffectTrack(frames: []),
                                     plan: showingSource ? nil : plan, timeline: playbackTimeline,
                                     atlas: atlas?.stamps == plan?.stamps ? atlas : nil,
                                     arc: arcLayers?.matches(plan?.arcMoment) == true ? arcLayers : nil) { playbackError = $0 }
                        .transition(.opacity)
                    if !showingSource, let plan, !camera.isEmpty {
                        ShotCaptionOverlay(captions: plan.frame(location: playbackTimeline.locate(outputTime), size: sourceSize).captions,
                                           canvas: sourceSize)
                    }
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0),
                                           .init(color: .clear, location: 0.32),
                                           .init(color: .clear, location: 0.56),
                                           .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                        .opacity(targetEdit != nil ? 0 : 1)
                }
                if player == nil || playbackError != nil {
                    VStack(spacing: 10) {
                        if let playbackError { Text(playbackError).font(.subheadline).multilineTextAlignment(.center) }
                        else { ProgressView().tint(SessionStyle.mint); Text("Preparing video…").font(.subheadline) }
                    }
                    .padding(24).frame(width: size.width, height: size.height)
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay {
                if let targetEdit, let clip = camera.clip(targetEdit) {
                    ShotTargetPicker(point: clip.settings.target?.cgPoint, tint: clip.move.tint) { point in
                        var next = camera
                        next.update(clip.id) { $0.target = ShotCameraPoint(x: point.x, y: point.y) }
                        camera = next
                        withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { self.targetEdit = nil }
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if preparingCamera {
                    ProgressView("Preparing replay…").font(.footnote).tint(SessionStyle.mint)
                        .padding(16).background(.black.opacity(0.65), in: .rect(cornerRadius: 16))
                }
            }
            .clipShape(.rect(cornerRadius: editing ? 18 : 0))
            .position(x: geometry.size.width / 2, y: editing ? (top + bottom) / 2 : geometry.size.height / 2)
        }
    }

    private var playbackBar: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { currentTime }, set: { value in
                currentTime = value
                player?.seek(to: CMTime(seconds: playbackTimeline.outputTime(for: value), preferredTimescale: 60_000),
                             toleranceBefore: .zero, toleranceAfter: .zero)
            }), in: 0...max(0.1, duration)) { editing in
                isScrubbing = editing
                if editing { resumeAfterScrub = isPlaying; player?.pause(); isPlaying = false }
                else if resumeAfterScrub { player?.play(); isPlaying = true }
            }
            .tint(SessionStyle.mint).accessibilityLabel("Video position")
            HStack {
                Text(ExportPreviewTime.label(at: currentTime))
                Spacer()
                Text(ExportPreviewTime.label(at: duration))
            }
            .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 18) {
            roundButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause video" : "Play video", action: togglePlay)
                .accessibilityIdentifier("shot-effects-play")
            Spacer(minLength: 0)
            Button {
                pause()
                showToolbox.toggle()
            } label: {
                Label("Customize", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    .padding(.horizontal, 20).frame(minHeight: 48)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffectID("customize", in: glass)
            .accessibilityIdentifier("shot-effects-customize")
            Spacer(minLength: 0)
            roundButton("arrow.uturn.backward", label: "Reset edits") {
                withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                    look = ShotReplayLook(style: .glowTrail, graphStyle: distance == nil ? .comet : .tape)
                        .allowed(isPro: subscriptions.isPro)
                    camera = .init(); showOriginal = false; cameraSelection = nil
                }
            }
            .accessibilityIdentifier("shot-effects-reset")
        }
        .frame(maxWidth: 420).frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
                .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: symbol)
        }
        .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).accessibilityLabel(label)
    }

    private func changeLook(_ change: (inout ShotReplayLook) -> Void) {
        var next = committedLook
        change(&next)
        guard subscriptions.isPro || !next.requiresPro else {
            requestPro(.look(next))
            return
        }
        look = next
    }

    private func lookBinding<Value>(_ keyPath: WritableKeyPath<ShotReplayLook, Value>) -> Binding<Value> {
        Binding(get: { displayedLook[keyPath: keyPath] }, set: { value in
            changeLook { $0[keyPath: keyPath] = value }
        })
    }

    private func requestPro(_ request: ProRequest) {
        pendingProRequest = request
        pause()
        showsProPaywall = true
    }

    private func finishPaywall() {
        defer { pendingProRequest = nil }
        guard subscriptions.isPro, let pendingProRequest else { return }
        switch pendingProRequest {
        case .tool(let tool): toolPage = tool
        case .look(let requestedLook): look = requestedLook
        }
    }

    // MARK: - Loading

    private func load() async {
        guard player == nil, source == nil else { return }
        let video: URL
        do {
            (video, distance) = try await prepare()
            source = video
            // A recorded roll opens on its measured distance.
            if distance != nil { graphStyle = .tape }
            if let pinnedGraph { graphStyle = pinnedGraph }
        } catch is CancellationError {
            return
        } catch {
            playbackError = String(localized: "This shot couldn’t be prepared. \(error.localizedDescription)")
            await finishProcessing()
            return
        }
        progress = 0.06
        let asset = AVURLAsset(url: video)
        do {
            let length = try await asset.load(.duration)
            duration = max(0.1, length.seconds)
            playbackTimeline = ShotEditTimeline(duration: duration)
            sourceFrames = ShotSourceFrames(duration: duration)
            frameIndexTask = Task {
                do {
                    let worker = Task.detached(priority: .userInitiated) { try await ShotSourceFrames.load(video) }
                    let frames = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    sourceFrames = frames
                } catch is CancellationError {
                    return
                } catch { show(.failed(String(localized: "Frame selection couldn’t be prepared. \(error.localizedDescription)"))) }
            }
            let item = AVPlayerItem(asset: asset)
            if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                let natural = try await videoTrack.load(.naturalSize)
                let fps = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
                processingInfo = VideoProcessingInfo(size: natural, fps: Double(fps), duration: length.seconds)
                let transform = try await videoTrack.load(.preferredTransform)
                sourceSize = EffectVideoGeometry.displaySize(naturalSize: natural, transform: transform)
                item.videoComposition = try await EffectVideoGeometry.composition(track: videoTrack, duration: length, shortEdge: 1080)
            }
            let player = AVPlayer(playerItem: item)
            observe(player)
            self.player = player
        } catch {
            playbackError = String(localized: "This shot can’t be played. \(error.localizedDescription)")
            await finishProcessing()
            return
        }
        step = 1; progress = 0.1
        if let cached = cachedTrack() {
            ready(cached)
        } else {
            do {
                let frames = try await VideoAnalyzer.replayTrack(source: video) { value in
                    Task { @MainActor in
                        progress = max(progress, 0.1 + value * 0.78)
                        step = max(step, value < 0.5 ? 1 : 2)
                    }
                }
                let found = BallEffectTrack(frames: frames)
                if found.samples.count >= 8 {
                    if let trackCache { try? SessionAnalysisStore.frameData(frames).write(to: trackCache, options: .atomic) }
                    ready(found)
                } else {
                    track = found
                    trackingProblem = String(localized: "We couldn’t follow the ball in this shot. Keep the whole flight in view.")
                }
            } catch is CancellationError {
                return
            } catch {
                trackingProblem = String(localized: "Ball tracking stopped. \(error.localizedDescription)")
            }
        }
        step = 3; progress = 0.95
        await finishProcessing()
    }

    private func ready(_ found: BallEffectTrack) {
        track = found
        flight = ShotFlight.find(in: found, aspect: Double(sourceSize.width / max(1, sourceSize.height)))
        plan = nil
        rebuildPlan()
        loadStill()
    }

    /// The strike frame, for the camera move cards.
    private func loadStill() {
        guard let source else { return }
        let at = strike
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 360)
            still = try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
        }
    }

    /// Works the camera track out again after an edit; the sprite sheet follows when its moments change.
    private func rebuildPlan() {
        guard let track else { plan = nil; return }
        if let plan, plan.matches(track: camera, duration: duration) { return }
        let frameDuration = sourceFrames.isEmpty ? 1.0 / 60 : sourceFrames.frameDuration(at: 0)
        let next = ShotCameraPlan(track: camera, ball: track, flight: flight, duration: duration,
                                  aspect: Double(sourceSize.width / max(1, sourceSize.height)), frameDuration: frameDuration)
        plan = next
        let slowed = ShotSlowMotion.stretches(in: next.timeline, track: camera)
        if let source, !slowed.isEmpty, ShotSlowMotion.isAvailable, slowMotion?.covers(slowed, of: source) != true {
            slowMotionTask?.cancel()
            makingSlowMotion = true
            slowMotionTask = Task {
                // Smooth frames take a few seconds; until then slow motion plays as before.
                let made = try? await ShotSlowMotion.render(source: source, stretches: slowed)
                guard !Task.isCancelled else { return }
                makingSlowMotion = false
                guard let made else { return }
                slowMotion = made
                updateCameraMedia()
            }
        }
        if let moment = next.arcMoment, arcLayers?.matches(moment) != true, let source {
            arcTask?.cancel()
            arcTask = Task {
                let built = try? await ShotArcLayers.build(source: source, ball: track, time: moment)
                guard !Task.isCancelled else { return }
                arcLayers = built
            }
        }
        guard next.stamps != atlas?.stamps else { return }
        atlasTask?.cancel()
        guard let source, !next.stamps.isEmpty else { atlas = nil; return }
        atlasTask = Task {
            let built = try? await ShotSpriteAtlas.build(source: source, stamps: next.stamps)
            guard !Task.isCancelled else { return }
            atlas = built
        }
    }

    /// Plays one block from just before it to just after it (after the replay is rebuilt, if needed).
    private func preview(_ clip: ShotCameraClip) {
        pendingPreview = clip.id
        if !preparingCamera { startPendingPreview() }
    }

    private func startPendingPreview() {
        guard let id = pendingPreview, let clip = camera.clip(id), let player else { return }
        pendingPreview = nil
        let from = max(0, clip.start - 0.35)
        let ends = playbackTimeline.segments.filter { $0.clip == id }.map(\.outputEnd)
        let end = max(ends.max() ?? 0, playbackTimeline.outputTime(for: min(duration, clip.end + 0.3)))
        previewEnd = min(playbackTimeline.outputDuration, end + 0.2)
        currentTime = from
        restarting = true
        player.seek(to: CMTime(seconds: playbackTimeline.outputTime(for: from), preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                restarting = false
                player.play(); isPlaying = true
            }
        }
    }

    /// The last checkpoint celebrates, then the editor takes over in place, as after juggling.
    private func finishProcessing() async {
        let start = holdAt ?? flight?.end ?? 0
        do {
            try await MediaReadiness.wait {
                guard let item = player?.currentItem else { throw MediaReadiness.Failure.unavailable }
                if item.status == .failed { throw item.error ?? MediaReadiness.Failure.unavailable }
                return item.status == .readyToPlay
            }
        } catch is CancellationError { return }
        catch {
            trackingProblem = error.localizedDescription
            processing = false; shown = true
            return
        }
        guard !Task.isCancelled else { return }
        // Open on the end of the flight, with the whole trail in the air.
        currentTime = min(duration, max(0, start))
        await player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        guard !Task.isCancelled else { return }
        if processing {
            progress = 1; step = 4
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 1200)) }
            catch { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { processing = false }
        }
        withAnimation(SessionMotion.animation(SessionMotion.settle, reduceMotion: reduceMotion)) { shown = true }
        #if DEBUG
        // Design review: place moves, open the camera page, select a block.
        if let names = SessionDesignReview.argument("--shot-camera-moves") {
            var next = camera
            for move in names.split(separator: ",").compactMap({ ShotCameraMove(rawValue: String($0)) }) {
                let preferred = move.defaultRange(strike: strike, flightEnd: plan?.flightEnd ?? strike + 1, playhead: currentTime, duration: duration)
                next.insert(move, range: next.fit(preferred, duration: duration) ?? preferred, duration: duration)
            }
            camera = next
        }
        if SessionDesignReview.argument("--shot-open-tool") == "camera" { showToolbox = true; toolPage = .camera }
        if let index = SessionDesignReview.argument("--shot-camera-select").flatMap(Int.init), camera.clips.indices.contains(index) {
            cameraSelection = camera.clips[index].id
        }
        if SessionDesignReview.argument("--shot-export-to") != nil { download() }
        #endif
    }

    private func cachedTrack() -> BallEffectTrack? {
        guard let trackCache, let data = try? Data(contentsOf: trackCache),
              let stored = try? PropertyListDecoder().decode([StoredFrame].self, from: data),
              stored.allSatisfy(\.isValid) else { return nil }
        let found = BallEffectTrack(frames: stored.map(\.frame))
        return found.samples.count >= 8 ? found : nil
    }

    // MARK: - Playback

    private func observe(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 60, preferredTimescale: 600),
                                                      queue: .main) { now in
            MainActor.assumeIsolated {
                guard !isScrubbing, !restarting else { return }
                let seconds = playbackTimeline.sourceTime(for: now.seconds)
                if seconds.isFinite { currentTime = max(0, seconds) }
                outputTime = now.seconds
                if let previewEnd, isPlaying, now.seconds >= previewEnd {
                    self.previewEnd = nil
                    pause()
                } else if now.seconds >= playbackTimeline.outputDuration - 0.03 {
                    if loopPreview { player.seek(to: CMTime(seconds: playbackTimeline.outputTime(for: loopStart), preferredTimescale: 60_000)); player.play() }
                    else { isPlaying = false; previewEnd = nil }
                }
            }
        }
    }

    /// Effects loop from just before the kick, so the trail is seen straight away.
    private var loopStart: Double { max(0, (flight?.launch ?? 0) - 0.6) }

    private func seek(to sourceTime: Double) {
        guard let player else { return }
        currentTime = min(duration, max(0, sourceTime))
        outputTime = playbackTimeline.outputTime(for: currentTime)
        player.seek(to: CMTime(seconds: outputTime, preferredTimescale: 60_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func updateCameraMedia(seekTo requested: Double? = nil) {
        guard let source, let player else { return }
        let next = plan?.timeline ?? ShotEditTimeline(track: camera, duration: duration)
        let slowed = ShotSlowMotion.stretches(in: next, track: camera)
        let smooth = slowMotion?.covers(slowed, of: source) == true ? slowMotion : nil
        if next == playbackTimeline && smooth === playbackSlowMotion && !preparingCamera {
            if let requested { seek(to: requested) }
            if pendingPreview != nil { startPendingPreview() }
            return
        }
        cameraRevision += 1
        let revision = cameraRevision
        cameraTask?.cancel()
        pause()
        preparingCamera = true
        let position = min(duration, max(0, requested ?? currentTime))
        cameraTask = Task {
            defer { if revision == cameraRevision { preparingCamera = false } }
            do {
                try await Task.sleep(for: .milliseconds(100))
                let asset = try await next.asset(source: source, smooth: smooth)
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .spectral
                if let video = try await asset.loadTracks(withMediaType: .video).first {
                    // A retimed replay reports its average rate; play it at the recording's own.
                    let cadence = sourceFrames.isEmpty ? nil : CMTime(seconds: sourceFrames.frameDuration(at: 0), preferredTimescale: 60_000)
                    item.videoComposition = try await EffectVideoGeometry.composition(
                        track: video, duration: asset.load(.duration), shortEdge: 1080, frameDuration: next.isOriginal ? nil : cadence)
                }
                guard !Task.isCancelled, revision == cameraRevision else { return }
                playbackTimeline = next
                playbackSlowMotion = smooth
                player.replaceCurrentItem(with: item)
                currentTime = position
                outputTime = next.outputTime(for: position)
                await player.seek(to: CMTime(seconds: outputTime, preferredTimescale: 60_000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
                if revision == cameraRevision { preparingCamera = false; startPendingPreview() }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, revision == cameraRevision else { return }
                show(.failed(String(localized: "Couldn’t prepare this replay. \(error.localizedDescription)")))
            }
        }
    }

    private func pause() { player?.pause(); isPlaying = false }

    private func togglePlay() {
        guard let player, !preparingCamera else { return }
        if isPlaying {
            pause()
        } else if currentTime >= duration - 0.05 {
            isPlaying = true; currentTime = 0; restarting = true
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    restarting = false
                    if isPlaying { player.play() }
                }
            }
        } else {
            player.play(); isPlaying = true
        }
    }

    private func startPreviewLoop() {
        guard !loopPreview else { return }
        loopPreview = true
        guard let player, !isPlaying else { return }
        if positionBeforePreview == nil { positionBeforePreview = currentTime }
        currentTime = loopStart
        player.seek(to: CMTime(seconds: playbackTimeline.outputTime(for: loopStart), preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); isPlaying = true
    }

    private func stopPreviewLoop() {
        guard loopPreview else { return }
        loopPreview = false
        pause()
    }

    private func restorePreviewPosition() {
        guard let position = positionBeforePreview, let player, !isPlaying else { return }
        positionBeforePreview = nil
        currentTime = position
        player.seek(to: CMTime(seconds: playbackTimeline.outputTime(for: position), preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tearDown() {
        // The user-started save owns its background lease and survives leaving the editor.
        cameraTask?.cancel()
        frameIndexTask?.cancel()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
    }

    // MARK: - Saving

    private func download() {
        guard !save.isBusy else { return }
        // Resolve again at export, including after expiration or a restored editor state.
        let exportLook = committedLook
        switch save {
        case .preparing, .exporting, .saving:
            return
        case .saved where savedLook == currentLook:
            showToolbox = false
            showSharePanel = true
        default:
            guard canSave, let source else { return }
            let track = track ?? BallEffectTrack(frames: [])
            pause()
            showToolbox = false; showSharePanel = false; toast = nil
            save = .preparing; saveProgress = 0
            let look = exportLook.style, strength = exportLook.intensity, timeline = subscriptions.isPro ? distance : nil, cameraLook = exportLook.camera, flightLook = flight
            let exportClock = ShotEditTimeline(track: cameraLook, duration: duration)
            let stamps = plan?.stamps ?? [], readyAtlas = atlas, readyArc = arcLayers, readySlowMotion = slowMotion
            let jobID = UUID()
            exportID = jobID
            ProductAnalytics.shared.track(.exportStarted(.ballDistance, effect: look.rawValue, graph: false))
            exportTask = Task {
                let analyticsStart = ContinuousClock.now
                var outcome: ProductEvent.Outcome = .failed
                defer {
                    let elapsed = analyticsStart.duration(to: .now)
                    ProductAnalytics.shared.track(.exportFinished(.ballDistance, outcome, elapsed: Double(elapsed.components.seconds)))
                }
                do {
                    #if DEBUG
                    let exportFolder = SessionDesignReview.argument("--shot-export-to")
                    #else
                    let exportFolder: String? = nil
                    #endif
                    if exportFolder == nil {
                        try await ShotEffectExporter.authorizePhotos()
                    }
                    let url = try await runSave(exportFolder: exportFolder) {
                        await MainActor.run { needsForeground = VideoWorkExecution.lease?.canContinue != true }
                        // Ball Strobe and freeze ghosts need their sprite sheet before the first frame.
                        let atlasLook = readyAtlas?.stamps == stamps ? readyAtlas : try await ShotSpriteAtlas.build(source: source, stamps: stamps)
                        let worker = VideoWorkExecution.detached {
                            try await ShotEffectExporter.render(source: source, track: track, style: look, intensity: strength,
                                distance: timeline, camera: cameraLook, flight: flightLook, atlas: atlasLook, arc: readyArc,
                                slowMotion: readySlowMotion) { amount in
                                    VideoWorkExecution.lease?.progress(amount * 0.96, subtitle: String(localized: "Rendering your shot"))
                                    Task { @MainActor in
                                        if exportID == jobID && save.isBusy {
                                            save = .exporting(amount); saveProgress = amount
                                        }
                                    }
                                }
                        }
                        let url = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                        var saved = false
                        defer { if !saved { try? FileManager.default.removeItem(at: url) } }
                        try await VideoWorkExecution.checkpoint()
                        await MainActor.run { save = .saving }
                        VideoWorkExecution.lease?.progress(0.98, subtitle: String(localized: "Saving to Photos"))
                        #if DEBUG
                        if let exportFolder {
                            let name = cameraLook.isEmpty ? look.rawValue : cameraLook.clips.map(\.move.rawValue).joined(separator: "+") + "-" + look.rawValue
                            let directory = SessionDesignReview.fileURL(exportFolder)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let target = directory.appendingPathComponent(name + "." + url.pathExtension)
                            try? FileManager.default.removeItem(at: target)
                            try FileManager.default.copyItem(at: url, to: target)
                        } else { try await ShotEffectExporter.saveToPhotos(url) }
                        #else
                        try await ShotEffectExporter.saveToPhotos(url)
                        #endif
                        saved = true
                        await MainActor.run {
                            savedURL = url
                            savedLook = SavedLook(trail: look, intensity: strength, camera: cameraLook)
                            savedDuration = exportClock.outputDuration
                            save = .saved
                            show(.saved)
                            showSharePanel = true
                        }
                        if exportFolder == nil { await VideoSaveCompletion.shared.saved() }
                        return url
                    }
                    outcome = .completed
                    thumbnail = await Self.frame(of: url, at: exportClock.outputTime(for: flightLook?.end ?? 0.5))
                } catch is CancellationError {
                    // Photos commits atomically; a late cancellation cannot undo a completed save.
                    guard save != .saved else { outcome = .completed; return }
                    outcome = .cancelled
                    saveProgress = 0
                    save = .failed(String(localized: "Saving stopped. Tap Download to try again."))
                    show(.failed(String(localized: "Saving stopped. Tap Download to try again.")))
                } catch {
                    save = .failed(error.localizedDescription)
                    show(.failed(error.localizedDescription))
                }
            }
        }
    }

    /// A change after saving means the saved file no longer matches: offer saving again.
    private func runSave<T: Sendable>(exportFolder: String?, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        #if DEBUG
        // Automated local exports run in the foreground. The simulator cannot reliably
        // deliver a continued-processing task; production Photos saves keep their lease.
        if exportFolder != nil {
            return try await VideoWorkExecution.$lease.withValue(VideoWorkLease(allowed: false, cpuOnly: false, backgroundGPU: false), operation: operation)
        }
        #endif
        return try await VideoBackgroundWork.shared.run(title: String(localized: "Saving your shot"), operation: operation)
    }

    private func saveOutdated() {
        guard save == .saved, savedLook != currentLook else { return }
        save = .idle
        showSharePanel = false
    }

    private func share() {
        guard let savedURL else { return }
        shareItem = ReplayShareItem(url: savedURL)
    }

    private func show(_ next: ShotToast) {
        toast = next
        Task {
            try? await Task.sleep(for: .seconds(next == .saved ? 2.8 : 4.5))
            if toast == next { toast = nil }
        }
    }

    private static func frame(of url: URL, at seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}
