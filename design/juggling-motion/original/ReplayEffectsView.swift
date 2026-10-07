import AVKit
import SwiftUI

/// Full-screen stopped session. Capture tools never appear in this editor.
struct ReplayEffectsView: View {
    let summary: SessionSummary
    @Binding var edit: SessionEditState
    @ObservedObject var stadiumPreview: StadiumPreviewModel
    @Binding var overlays: ExportOverlaySettings
    var onSaveShare: () -> Void
    var onBack: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tool: ReplayTool?
    @State private var showToolbox = false
    @State private var counterSelected = false
    @State private var showGraph = true
    @State private var showTime = true
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            videoCanvas.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                if showToolbox {
                    ReplayToolbox(counterStyle: overlays.counter.style, onClose: { showToolbox = false }) { chosen in
                        pause(); showToolbox = false; tool = chosen
                    }.padding(.horizontal, 20).padding(.bottom, 18)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    CaptureMetrics(points: motionPoints, touchTimes: summary.touchesMarked.map(\.time),
                                   time: currentTime, duration: duration, showGraph: showGraph, showTime: showTime)
                        .padding(.horizontal, 24).padding(.bottom, 10).allowsHitTesting(false)
                    playbackBar.padding(.horizontal, 24).padding(.bottom, 14)
                }
                if counterSelected {
                    Text("Drag to move · Pinch to resize")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 10)
                }
                bottomControls.padding(.horizontal, 24).padding(.bottom, 16)
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(item: $tool) { selected in
            switch selected {
            case .counter:
                ExportOverlayEditor(summary: summary, edit: edit, sourceSize: sourceSize,
                                    sceneModel: stadiumPreview, settings: $overlays)
                    .presentationDragIndicator(.visible)
            case .ball:
                BallSkinPickerView(selection: $edit.ballSkin)
            case .effects:
                EffectPickerView(selection: $edit.style)
            case .timer, .graph:
                NavigationStack {
                    Form {
                        if selected == .timer {
                            Toggle("Show elapsed time", isOn: $showTime)
                            Text("Elapsed time is shown in the playback HUD.").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Toggle("Show ball motion", isOn: $showGraph)
                        }
                    }.navigationTitle(selected.rawValue).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { tool = nil } } }
                }.presentationDetents([.height(260)]).presentationDragIndicator(.visible)
            }
        }
        .onChange(of: edit.scene) { _, _ in tearDownPlayer(); setUpPlayer() }
        .onChange(of: overlays) { _, value in value.save() }
        .onAppear {
            if originalEdit == nil { originalEdit = edit; originalOverlays = overlays }
            setUpPlayer()
        }
        .onDisappear { tearDownPlayer() }
        .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: showToolbox)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            roundButton("chevron.left", label: "Close editor", action: onBack)
                .accessibilityIdentifier("replay-close")
            Spacer(minLength: 0)
            CaptureSessionBadge(number: summary.sessionNumber)
            Spacer(minLength: 0)
            Button("Export") { pause(); onSaveShare() }
                .font(.system(size: 14, weight: .semibold))
                .buttonStyle(.glassProminent).tint(Color(red: 0.84, green: 1, blue: 0.42))
                .foregroundStyle(.black).controlSize(.large)
                .accessibilityIdentifier("replay-export")
        }.padding(.horizontal, 20).padding(.top, 8)
    }

    private var videoCanvas: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
            let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
            ZStack(alignment: .topLeading) {
                if let player {
                    MetalVideoSurface(player: player, edit: edit, track: effectTrack) { playbackError = $0 }
                    // Shade the footage before drawing the counter, so white stays white.
                    LinearGradient(stops: [.init(color: .black.opacity(0.4), location: 0),
                                          .init(color: .clear, location: 0.32),
                                          .init(color: .clear, location: 0.56),
                                          .init(color: .black.opacity(0.8), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .allowsHitTesting(false)
                    ExportOverlayLayer(settings: overlays,
                        timeline: .init(touches: summary.touchesMarked, total: summary.touches), time: currentTime, size: size)
                    if overlays.counter.enabled {
                        if counterSelected {
                            CounterStickerInteraction(placement: $overlays.counter.placement)
                            CounterSelectionFrame(placement: $overlays.counter.placement, size: size) {
                                overlays.counter.enabled = false; counterSelected = false
                            }
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
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var motionPoints: [CaptureMotionPoint] {
        summary.track.map { CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil) }
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
                if counterSelected { overlays.counter.placement = .init(x: 0.04, y: 0.08, scale: 0.65) }
                else { togglePlay() }
            }.accessibilityIdentifier("replay-play")
            Spacer(minLength: 0)
            Button {
                pause()
                if counterSelected { tool = .counter }
                else { showToolbox.toggle() }
            } label: {
                Label(counterSelected ? "Counter style" : "Customize", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8).frame(minHeight: 24)
            }.buttonStyle(.glass).controlSize(.large)
                .tint(showToolbox ? SessionStyle.mint : .white)
                .accessibilityIdentifier("replay-customize")
            Spacer(minLength: 0)
            roundButton(counterSelected ? "checkmark" : "arrow.uturn.backward",
                        label: counterSelected ? "Done adjusting counter" : "Reset edits") {
                if counterSelected { counterSelected = false }
                else {
                    if let originalEdit { edit = originalEdit }
                    if let originalOverlays { overlays = originalOverlays }
                    showGraph = true; showTime = true
                }
            }.tint(counterSelected ? SessionStyle.mint : .white)
                .accessibilityIdentifier("replay-reset")
        }.frame(maxWidth: 420).frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 32, height: 32)
        }.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular).accessibilityLabel(label)
    }

    private func pause() { player?.pause(); isPlaying = false }

    // MARK: - Player

    private func setUpPlayer() {
        guard player == nil, setupTask == nil else { return }
        playbackError = nil
        setupTask = Task {
            do {
                let media = try await stadiumPreview.media(summary: summary, selection: edit.scene)
                let url = media.url
                effectTrack = BallEffectTrack(frames: media.track)
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
                    guard !isScrubbing else { return }
                    let seconds = CMTimeGetSeconds(time)
                    if seconds.isFinite { currentTime = max(0, seconds) }
                    if currentTime >= duration - 0.03 { isPlaying = false }
                }
            } catch is CancellationError { }
            catch { playbackError = "Couldn’t open this video. \(error.localizedDescription)" }
        }
    }

    private func tearDownPlayer() {
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
        } else {
            if currentTime >= duration - 0.05 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                currentTime = 0
            }
            player.play()
        }
        isPlaying.toggle()
    }

    private func formatTime(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
