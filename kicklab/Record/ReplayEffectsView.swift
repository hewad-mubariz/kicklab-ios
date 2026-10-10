import AVKit
import SwiftUI

/// Full-screen stopped session. Capture tools never appear in this editor.
struct ReplayEffectsView: View {
    let summary: SessionSummary
    @Binding var edit: SessionEditState
    @ObservedObject var stadiumPreview: StadiumPreviewModel
    @Binding var overlays: ExportOverlaySettings
    var onBack: () -> Void
    /// Offered after a download, beside the share targets.
    var onRecordAnother: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    @ObservedObject var preparation = SessionEffectsPreparation()
    var showsTouchTools = true
    var distanceTimeline: BallDistanceTimeline? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass
    @State private var shown = false
    @State private var showToolbox = false
    @State private var toolPage: ReplayTool?
    /// Where the open panel starts and the top chrome ends, so the video can fit between them.
    @State private var panelTop: CGFloat = 0
    @State private var chromeBottom: CGFloat = 0
    @State private var playbackTop: CGFloat = 0
    /// Ball and Effects loop the clip so every pick is seen on the moving ball.
    @State private var loopPreview = false
    @State private var counterSelected = false
    @State private var showGraph = true
    @State private var showTime = true
    private var motionStyle: MotionStyle { overlays.graph.style }
    @State private var motionTimeline = MotionStyleTimeline(points: [], touchTimes: [])
    @State private var originalEdit: SessionEditState?
    @State private var originalOverlays: ExportOverlaySettings?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var timeObserver: Any?
    @State private var sourceSize = CGSize(width: 9, height: 16)
    @State private var effectTrack = BallEffectTrack(frames: [])
    @State private var isScrubbing = false
    @State private var resumeAfterScrub = false
    @State private var setupTask: Task<Void, Never>?
    @State private var playbackError: String?
    @State private var motionSource: URL?
    @State private var surfaceMotionTask: Task<Void, Never>?
    @State private var surfaceMotionGeneration = UUID()
    @State private var surfaceMotionError: String?
    @StateObject private var downloader = ReplayDownloader()
    /// Where the playhead was before a tool page moved it (Effects and Counter loop, Ball holds
    /// a mid-juggle frame); leaving those pages puts it back.
    @State private var positionBeforePreview: Double?
    /// True while play-from-the-end rewinds; the time observer must not see the old end time.
    @State private var restarting = false
    @State private var showSharePanel = false
    @State private var showSaveConfirmation = false
    @State private var toast: DownloadToast?
    @State private var shareItem: ReplayShareItem?

    private enum DownloadToast: Equatable { case saved, failed(String) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoCanvas.ignoresSafeArea()
                .sessionEntrance(shown, offset: 0, scale: 1.04)
            VStack(spacing: 0) {
                topBar.sessionEntrance(shown, order: 1, offset: -16)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { chromeBottom = $0 }
                    .overlay(alignment: .top) { toastView.padding(.top, 58).padding(.horizontal, 20) }
                Spacer(minLength: 12)
                // Customize and the toolbox share one glass identity, so the pill morphs into the panel.
                GlassEffectContainer(spacing: 8) {
                    VStack(spacing: 0) {
                        if showToolbox {
                            ReplayToolbox(counter: $overlays.counter, edit: $edit,
                                          showTime: $showTime, showGraph: $showGraph,
                                          includeGraph: $overlays.graph.enabled, motionStyle: $overlays.graph.style,
                                          motionSnapshot: motionTimeline.snapshot(at: currentTime, duration: duration),
                                          sourceAspect: sourceSize.width / max(1, sourceSize.height),
                                          isPlaying: isPlaying, onTogglePlayback: togglePlay, page: $toolPage,
                                          onClose: { showToolbox = false }, showsTouchTools: showsTouchTools)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                                // Same spring as the tray's height, so video and panel move as one.
                                withAnimation(SessionMotion.animation(SessionMotion.tray, reduceMotion: reduceMotion)) { panelTop = top }
                            }
                            .glassEffectID("customize", in: glass)
                            .padding(.horizontal, 20).padding(.bottom, 18)
                        } else if showSharePanel {
                            ReplaySharePanel(onShare: share, onClose: { showSharePanel = false },
                                             onRecordAnother: onRecordAnother, onDone: onDone)
                                .padding(.horizontal, 16).padding(.bottom, 10)
                                .transition(.sessionRise)
                        } else {
                            if let distanceTimeline {
                                let reading = distanceTimeline.state(at: currentTime)
                                BallDistanceReadout(value: reading.valueLabel, detail: reading.status.label,
                                    paused: reading.status == .paused || reading.status == .needsSetup, compact: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 24).padding(.bottom, 12)
                            }
                            CaptureMetrics(points: motionTimeline.points, touchTimes: motionTimeline.touches,
                                           time: currentTime, duration: duration,
                                           showGraph: showsTouchTools && showGraph && !effectiveOverlays.graph.enabled, showTime: showTime,
                                           motionStyle: motionStyle, motionTimeline: motionTimeline,
                                           sourceAspect: sourceSize.width / max(1, sourceSize.height), showsTouchMetrics: showsTouchTools)
                                .padding(.horizontal, 24).padding(.bottom, 10).allowsHitTesting(false)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { playbackTop = $0 }
                                .sessionEntrance(shown, order: 2)
                                .transition(.sessionRise)
                            playbackBar.padding(.horizontal, 24).padding(.bottom, 14)
                                .sessionEntrance(shown, order: 3)
                                .transition(.sessionRise)
                            if counterSelected {
                                Text("Drag to move · Pinch to resize")
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 10)
                                    .transition(.sessionRise)
                            }
                            bottomControls.padding(.horizontal, 24).padding(.bottom, 16)
                                .sessionEntrance(shown, order: 4, offset: 24)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onChange(of: showToolbox) { _, open in
            if !open { if toolPage == .graph { pause() }; toolPage = nil; panelTop = 0 }
        }
        .onChange(of: toolPage) { _, page in
            if page != .graph && !loopPreview { pause() }
            // Effects loop so they are seen on the moving ball. The Ball page holds a frame:
            // drawing a replacement ball on every video frame is CPU work on the main thread.
            // The counter page loops too, so each style's touch move plays on real touches.
            if page == .effects || page == .counter { startPreviewLoop() } else { stopPreviewLoop() }
            if page == .ball { showBallFrame() }
            if page == nil || page == .timer || page == .graph { restorePreviewPosition() }
        }
        .onChange(of: edit.ballSkin) { _, _ in prepareSurfaceMotion() }
        .onChange(of: summary.needsVisualPreparation) { _, pending in
            guard !pending, edit.scene == nil else { return }
            effectTrack = BallEffectTrack(frames: summary.renderTrack, touchTimes: summary.touchesMarked.map(\.time))
            prepareSurfaceMotion()
        }
        .onChange(of: edit.scene) { _, _ in tearDownPlayer(); setUpPlayer() }
        .onChange(of: overlays) { old, value in
            if old.graph.enabled != value.graph.enabled {
                ProductAnalytics.shared.track(.graphToggled(value.graph.enabled))
            }
            if showsTouchTools { value.save() }
            downloadOutdated()
        }
        .onChange(of: edit) { old, next in
            if old.style != next.style {
                ProductAnalytics.shared.track(.effectSelected(showsTouchTools ? .juggling : .ballDistance, effect: next.style.rawValue))
            }
            downloadOutdated()
        }
        .onChange(of: showGraph) { _, _ in downloadOutdated() }
        .onChange(of: downloader.phase) { _, phase in
            switch phase {
            case .saved:
                show(.saved); showSharePanel = true
                showSaveConfirmation = UIApplication.shared.applicationState == .active
            case .failed(let message): show(.failed(message))
            default: break
            }
        }
        .sheet(item: $shareItem) { item in
            ReplayShareSheet(url: item.url).presentationDetents([.medium, .large])
        }
        .onAppear {
            if originalEdit == nil { originalEdit = edit; originalOverlays = overlays }
            motionTimeline = MotionStyleTimeline(points: summary.track.map {
                CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil, x: $0.detected ? $0.x : nil)
            }, touchTimes: summary.touchesMarked.map(\.time))
            setUpPlayer()
            shown = true
        }
        .onDisappear { tearDownPlayer() }
        .videoSavedConfirmation(isPresented: $showSaveConfirmation)
        .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: showToolbox)
        .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: showSharePanel)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: toast)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: counterSelected)
        .sensoryFeedback(.impact(weight: .light), trigger: showToolbox)
        .sensoryFeedback(.selection, trigger: counterSelected)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            roundButton("chevron.left", label: "Close editor", action: onBack)
                .accessibilityIdentifier("replay-close")
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                if showsTouchTools {
                    CaptureSessionBadge(number: summary.sessionNumber)
                } else {
                    Text(distanceTimeline == nil ? "BALL EFFECTS" : "BALL DISTANCE")
                        .font(.system(size: 11, weight: .semibold)).tracking(1.6)
                        .accessibilityIdentifier("ball-video-editor-title")
                }
                if edit.ballSkin != .original {
                    Text(preparation.isPreparing ? "Preparing ball effects · \(Int(preparation.progress * 100))%"
                         : preparation.error != nil || surfaceMotionError != nil ? "Ball effects unavailable — tap to retry"
                         : surfaceMotionTask != nil ? "Preparing source spin…"
                         : effectTrack.surfaceMotion?.status(at: currentTime).label ?? "Spin uncertain")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier("replay-spin-status")
                        .onTapGesture { prepareSurfaceMotion() }
                }
            }
            Spacer(minLength: 0)
            // Saves what you see in one tap; the button itself shows the progress.
            ReplayDownloadButton(phase: downloader.phase, progress: downloader.progress, action: download,
                                 needsForeground: downloader.needsForeground)
                .accessibilityIdentifier("replay-export")
        }.padding(.horizontal, 20).padding(.top, 8)
    }

    // MARK: Download

    private func download() {
        switch downloader.phase {
        case .preparing, .exporting, .saving:
            return
        case .saved where !downloader.isStale(edit: edit, overlays: effectiveOverlays):
            // Already in Photos: the check reopens the share panel.
            showToolbox = false; counterSelected = false
            showSharePanel = true
        default:
            pause()
            showToolbox = false; counterSelected = false; showSharePanel = false; toast = nil
            Task {
                await downloader.download(summary: summary, edit: edit, overlays: effectiveOverlays,
                                          sceneModel: stadiumPreview, preparation: preparation,
                                          distanceTimeline: distanceTimeline)
            }
        }
    }

    /// An edit after saving means the saved file no longer matches: offer download again.
    private func downloadOutdated() {
        guard downloader.phase == .saved, downloader.isStale(edit: edit, overlays: effectiveOverlays) else { return }
        downloader.reset()
        showSharePanel = false
    }

    private func share() {
        guard let url = downloader.savedURL else { return }
        shareItem = ReplayShareItem(url: url)
    }

    private func show(_ next: DownloadToast) {
        toast = next
        Task {
            try? await Task.sleep(for: .seconds(next == .saved ? 2.8 : 4.5))
            if toast == next { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Group {
                switch toast {
                case .saved:
                    ReplaySavedToast(thumbnail: downloader.thumbnail,
                                     detail: "1080p · \(ExportPreviewTime.label(at: duration))")
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
            let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            // While customizing, the whole frame shrinks into the space above the panel,
            // so the ball is never hidden behind the tools.
            let lowerEdge = showToolbox ? panelTop : playbackTop
            let editing = (showToolbox || effectiveOverlays.graph.enabled) && lowerEdge > chromeBottom + 120
            let top = chromeBottom + 10, bottom = lowerEdge - 12
            let fit = editing ? min(1, (bottom - top) / size.height) : 1
            ZStack(alignment: .topLeading) {
                if let player {
                    MetalVideoSurface(player: player, edit: renderedEdit, track: effectTrack) { playbackError = $0 }
                        .transition(.opacity)
                    // Shade the footage before drawing the counter, so white stays white.
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0),
                                          .init(color: .clear, location: 0.32),
                                          .init(color: .clear, location: 0.56),
                                          .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    ExportOverlayLayer(settings: effectiveOverlays,
                        timeline: .init(touches: summary.touchesMarked, total: summary.touches), time: currentTime, size: size)
                    if effectiveOverlays.graph.enabled {
                        ExportMotionGraphLayer(style: motionStyle,
                            snapshot: motionTimeline.snapshot(at: currentTime, duration: duration), size: size)
                            .allowsHitTesting(false)
                    }
                    if showsTouchTools && overlays.counter.enabled {
                        if counterSelected {
                            let rect = overlays.counter.placement.rect(in: size)
                            CounterStickerInteraction(placement: $overlays.counter.placement)
                            // Handles snap inward onto the sticker, like a focus ring landing.
                            CounterSelectionFrame(placement: $overlays.counter.placement, size: size) {
                                overlays.counter.enabled = false; counterSelected = false
                            }
                            .transition(.sessionPop(from: UnitPoint(x: rect.midX / max(1, size.width),
                                                                    y: rect.midY / max(1, size.height)), scale: 1.3))
                        } else {
                            let rect = overlays.counter.placement.rect(in: size)
                            Button { pause(); showToolbox = false; counterSelected = true } label: {
                                Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
                            }.buttonStyle(.plain).rotationEffect(.radians(overlays.counter.placement.radians))
                                .position(x: rect.midX, y: rect.midY)
                                .accessibilityLabel("Adjust touch counter").accessibilityIdentifier("replay-select-counter")
                        }
                    }
                }
                if player == nil || playbackError != nil {
                    VStack(spacing: 10) {
                        if let playbackError { Text(playbackError).font(.subheadline).multilineTextAlignment(.center) }
                        else { ProgressView().tint(SessionStyle.mint); Text("Preparing video…").font(.subheadline) }
                    }.padding(24).frame(width: size.width, height: size.height)
                    .transition(.opacity)
                }
            }
            .animation(SessionMotion.fade, value: player == nil)
            .frame(width: size.width, height: size.height)
            .clipShape(.rect(cornerRadius: editing ? 18 / fit : 0))
            .scaleEffect(fit)
            .position(x: geometry.size.width / 2, y: editing ? (top + bottom) / 2 : geometry.size.height / 2)
        }
    }

    private var playbackBar: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { currentTime }, set: { value in
                currentTime = value
                player?.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }), in: 0...max(0.1, duration)) { editing in
                isScrubbing = editing
                if editing { resumeAfterScrub = isPlaying; player?.pause(); isPlaying = false }
                else if resumeAfterScrub { player?.play(); isPlaying = true }
            }.tint(SessionStyle.mint).accessibilityLabel("Video position")
            HStack {
                Text(ExportPreviewTime.label(at: currentTime))
                Spacer()
                Text(ExportPreviewTime.label(at: duration))
            }.font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
        }
    }

    private var bottomControls: some View {
        HStack(spacing: 18) {
            roundButton(counterSelected ? "arrow.uturn.backward" : isPlaying ? "pause.fill" : "play.fill",
                        label: counterSelected ? "Reset counter position" : isPlaying ? "Pause video" : "Play video") {
                if counterSelected {
                    withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                        overlays.counter.placement = .init(x: 0.04, y: 0.08, scale: 0.65)
                    }
                }
                else { togglePlay() }
            }.accessibilityIdentifier("replay-play")
            Spacer(minLength: 0)
            Button {
                pause()
                // The pill morphs into the tray, opened straight on the counter styles.
                if counterSelected { counterSelected = false; toolPage = .counter; showToolbox = true }
                else { showToolbox.toggle() }
            } label: {
                Label {
                    Text(counterSelected ? "Counter style" : "Customize").contentTransition(.interpolate)
                } icon: {
                    Image(systemName: counterSelected ? "textformat.123" : "wand.and.stars")
                        .contentTransition(.symbolEffect(.replace))
                }
                .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 20).frame(minHeight: 48)
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .glassEffectID("customize", in: glass)
            .accessibilityIdentifier("replay-customize")
            Spacer(minLength: 0)
            roundButton(counterSelected ? "checkmark" : "arrow.uturn.backward",
                        label: counterSelected ? "Done adjusting counter" : "Reset edits") {
                if counterSelected { counterSelected = false }
                else {
                    withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                        if let originalEdit { edit = originalEdit }
                        if let originalOverlays { overlays = originalOverlays }
                        showGraph = true; showTime = true
                        overlays.graph.style = .ballMotion
                    }
                }
            }.tint(counterSelected ? SessionStyle.mint : .white)
                .accessibilityIdentifier("replay-reset")
        }.frame(maxWidth: 420).frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 32, height: 32)
                .contentTransition(.symbolEffect(.replace))
                .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: symbol)
        }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).accessibilityLabel(label)
    }

    private func pause() { player?.pause(); isPlaying = false }

    private func startPreviewLoop() {
        guard !loopPreview else { return }
        loopPreview = true
        guard let player, !isPlaying else { return }
        if positionBeforePreview == nil { positionBeforePreview = currentTime }
        if currentTime >= duration - 0.05 { player.seek(to: .zero); currentTime = 0 }
        player.play(); isPlaying = true
    }

    /// Paused at the end of the clip the ball is often out of shot; jump to mid-juggle.
    private func showBallFrame() {
        guard let player, currentTime >= duration - 0.1 else { return }
        if positionBeforePreview == nil { positionBeforePreview = currentTime }
        currentTime = duration * 0.4
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Player

    private func setUpPlayer() {
        guard player == nil, setupTask == nil else { return }
        playbackError = nil
        setupTask = Task {
            do {
                let media = try await stadiumPreview.media(summary: summary, selection: edit.scene)
                let url = media.url
                effectTrack = BallEffectTrack(frames: media.track, touchTimes: summary.touchesMarked.map(\.time))
                motionSource = summary.videoURL
                prepareSurfaceMotion()
                try Task.checkCancellation()
                let asset = AVURLAsset(url: url)
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    let natural = try await track.load(.naturalSize)
                    let transform = try await track.load(.preferredTransform)
                    sourceSize = EffectVideoGeometry.displaySize(naturalSize: natural, transform: transform)
                }
                duration = max(0.1, CMTimeGetSeconds(try await asset.load(.duration)))
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: asset)
                if let videoTrack = try await asset.loadTracks(withMediaType: .video).first {
                    item.videoComposition = try await EffectVideoGeometry.composition(track: videoTrack,
                        duration: try await asset.load(.duration), shortEdge: 1080)
                }
                let p = AVPlayer(playerItem: item)
                p.isMuted = false
                player = p
                currentTime = max(0, duration - 1.0 / 30)
                await p.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                let interval = CMTime(seconds: 1.0 / 60, preferredTimescale: 600)
                timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                    guard !isScrubbing, !restarting else { return }
                    let seconds = CMTimeGetSeconds(time)
                    if seconds.isFinite { currentTime = max(0, seconds) }
                    if currentTime >= duration - 0.03 {
                        if loopPreview { p.seek(to: .zero); p.play() } else { isPlaying = false }
                    }
                }
            } catch is CancellationError { }
            catch { playbackError = "Couldn’t open this video. \(error.localizedDescription)" }
        }
    }

    private var renderedEdit: SessionEditState {
        var value = edit
        // Never display stale capture masks or invented timer spin while precise
        // effects are being prepared. Original footage stays playable.
        if (summary.needsVisualPreparation && preparation.prepared == nil) || effectTrack.surfaceMotion == nil { value.ballSkin = .original }
        return value
    }

    private var effectiveOverlays: ExportOverlaySettings {
        var value = overlays
        if !showsTouchTools { value.counter.enabled = false }
        value.graph.enabled = value.graph.enabled && showsTouchTools && showGraph
        return value
    }

    private func prepareSurfaceMotion() {
        guard edit.ballSkin != .original, let url = motionSource,
              effectTrack.surfaceMotion == nil, surfaceMotionTask == nil else { return }
        let token = UUID(); surfaceMotionGeneration = token; surfaceMotionError = nil
        surfaceMotionTask = Task {
            defer { if surfaceMotionGeneration == token { surfaceMotionTask = nil } }
            do {
                let ready = try await preparation.prepare(summary)
                try Task.checkCancellation()
                guard motionSource == url else { return }
                if edit.scene == nil {
                    effectTrack = BallEffectTrack(frames: ready.renderTrack, touchTimes: ready.touchesMarked.map(\.time))
                }
                let motion = try await BallSurfaceTimeline.prepare(source: url, track: BallEffectTrack(frames: ready.renderTrack))
                try Task.checkCancellation()
                guard motionSource == url else { return }
                effectTrack.surfaceMotion = motion
            } catch is CancellationError { }
            catch {
                if surfaceMotionGeneration == token { surfaceMotionError = error.localizedDescription }
                NSLog("KickLab ball effects: %@", error.localizedDescription)
            }
        }
    }

    private func tearDownPlayer() {
        surfaceMotionGeneration = UUID(); surfaceMotionError = nil
        surfaceMotionTask?.cancel(); surfaceMotionTask = nil; motionSource = nil
        setupTask?.cancel()
        setupTask = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player?.pause()
        isPlaying = false
        player = nil
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else if currentTime >= duration - 0.05 {
            // From the end: rewind first and only then play, or a stale end-time report stops it again.
            isPlaying = true
            currentTime = 0
            restarting = true
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    restarting = false
                    if isPlaying { player.play() }
                }
            }
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func formatTime(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
