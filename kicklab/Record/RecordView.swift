//
//  RecordView.swift
//  kicklab
//
//  Live juggling capture HUD. Preview runs immediately; detection and recording start only
//  when you hit Record. Stop finalizes the clip and opens its editor.
//

import AVFoundation
import Combine
import PhotosUI
import SwiftUI

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraSession()
    @StateObject private var importedVideo = VideoAnalyzer()

    @AppStorage("experimentalBallModel") private var experimentalBallModel = "default"
    @State private var showGallery = false
    @State private var galleryItem: PhotosPickerItem?
    @State private var importedURL: URL?
    @State private var importError: String?
    @State private var elapsed: TimeInterval = 0
    @State private var timerRunning = false
    @State private var showDiagnostics = ProcessInfo.processInfo.arguments.contains("--detector-review")
    @State private var comboPeak = 0
    @State private var liveTrail: [BallStyleSample] = []
    @State private var sessionNumber = JugglingSessionIdentity.next()
    @State private var motionPoints: [CaptureMotionPoint] = []
    private let liveStyle = BallStyle.fire
    private let liveIntensity = 0.85

    @State private var showProcessing = false
    @State private var processingProgress: Double = 0
    @State private var processingStep = 0
    @State private var pendingSummary: SessionSummary?
    @State private var sessionSummary: SessionSummary?
    @State private var isFinishingSession = false
    @State private var hudShown = false

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    init(initialVideo: PhotosPickerItem? = nil) {
        _galleryItem = State(initialValue: initialVideo)
    }

    var body: some View {
        ZStack {
            GeometryReader { _ in
                ZStack {
                    GeometryReader { video in
                        ZStack {
                            CameraPreview(session: camera.captureSession)
                            if showDiagnostics, let person = camera.personBox {
                                TrackingCorners(rect: person)
                            }
                            if camera.isRecording { ballOverlay(in: video.size) }
                        }
                    }.ignoresSafeArea()

                    LinearGradient(
                        colors: [.black.opacity(0.50), .clear, .black.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        topBar.sessionEntrance(hudShown, offset: -14)
                        Spacer(minLength: 0)
                        if showDiagnostics { diagnosticsPanel }
                        CaptureMetrics(points: motionPoints, touchTimes: camera.recentTouchTimes, time: elapsed)
                            .padding(.horizontal, 24).padding(.bottom, 14)
                            .sessionEntrance(hudShown, order: 2)
                        cameraStatus
                        bottomBar.sessionEntrance(hudShown, order: 3, offset: 28)
                    }
                }
            }

            // Full-screen — outside the geo stack so Stop never flash-blacks.
            if showProcessing {
                ProcessingOverlay(progress: processingProgress, stepIndex: processingStep)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .statusBarHidden(false)
        .preferredColorScheme(.dark)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--select-segmentation-pilot") { experimentalBallModel = "segmentation" }
            if ProcessInfo.processInfo.arguments.contains("--select-motion-model") { experimentalBallModel = "motionModel" }
            if galleryItem == nil { camera.start() }
            hudShown = true
        }
        .task {
            if DetectorPhoneBenchmark.requested {
                await DetectorPhoneBenchmark.run(camera: camera)
            }
        }
        .onDisappear {
            timerRunning = false
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if camera.isRecording { beginProcessing() }
                timerRunning = false
                camera.stop()
            } else if phase == .active, !showProcessing, sessionSummary == nil,
                      importedURL == nil {
                camera.start()
            }
        }
        .onReceive(timer) { _ in
            guard timerRunning, camera.isRecording else { return }
            elapsed = camera.recordingElapsed
        }
        .onChange(of: camera.lastTouchToken) { _, token in
            comboPeak = max(comboPeak, camera.touchCount)
        }
        .onChange(of: camera.ballBox) { _, box in
            guard let box,
                  var sample = BallStyleSample(
                    box: box,
                    confidence: camera.ballScore,
                    velocityY: camera.ballVelocityY
                  ) else {
                return
            }
            sample.time = Date.timeIntervalSinceReferenceDate
            liveTrail.append(sample)
            if liveTrail.count > 18 { liveTrail.removeFirst(liveTrail.count - 18) }
        }
        .onChange(of: camera.recordingElapsed) { _, time in
            guard camera.isRecording else { return }
            elapsed = time
            motionPoints.append(CaptureMotionPoint(time: time, y: camera.ballBox.map { Double($0.midY) }))
            motionPoints.removeAll { $0.time < time - 6 }
        }
        .onChange(of: camera.isRecording) { _, recording in
            timerRunning = recording
            liveTrail = []
            if recording {
                comboPeak = 0
                motionPoints = []
                sessionNumber = JugglingSessionIdentity.begin()
            }
        }
        .onChange(of: camera.recordingError) { _, error in
            guard let error else { return }
            timerRunning = false
            showProcessing = false
            importError = error
        }
        .onChange(of: camera.recordingURL) { _, url in
            guard let url, showProcessing else { return }
            let summary = SessionSummary.make(
                touches: camera.touchCount,
                duration: elapsed,
                bestCombo: max(comboPeak, camera.touchCount),
                personalBest: JugglingRecords.personalBest,
                videoURL: url,
                touchesMarked: camera.recordedTouches,
                track: camera.recordedTrack, sessionNumber: sessionNumber
            )
            pendingSummary = summary
            Task { await finishProcessing(with: summary) }
        }
        .photosPicker(isPresented: $showGallery, selection: $galleryItem, matching: .videos)
        .task(id: galleryItem) {
            guard let item = galleryItem else { return }
            await importMovie(item)
        }
        .onChange(of: importedVideo.progress) { _, progress in
            guard importedURL != nil else { return }
            processingProgress = 0.1 + progress * 0.9
            processingStep = progress < 0.85 ? 1 : 2
        }
        .onChange(of: importedVideo.isRunning) { _, running in
            guard !running, let url = importedURL else { return }
            importedURL = nil
            galleryItem = nil
            guard importedVideo.status == "done" else {
                try? FileManager.default.removeItem(at: url)
                showProcessing = false
                importError = importedVideo.status
                camera.start()
                return
            }
            processingProgress = 1
            processingStep = 4
            presentWithoutSlide(SessionSummary.make(
                touches: importedVideo.touchCount,
                duration: importedVideo.videoDuration,
                bestCombo: importedVideo.touchCount,
                personalBest: JugglingRecords.personalBest,
                videoURL: url,
                touchesMarked: importedVideo.recordedTouches,
                track: importedVideo.recordedTrack, sessionNumber: JugglingSessionIdentity.begin()
            ))
        }
        .alert("Video unavailable", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Please try another video.")
        }
        .fullScreenCover(item: $sessionSummary) { summary in
            PostSessionFlowView(
                summary: summary,
                onFinished: {
                    sessionSummary = nil
                    camera.clearRecording()
                    dismiss()
                },
                onRecordAnother: {
                    sessionSummary = nil
                    camera.clearRecording()
                    elapsed = 0
                    comboPeak = 0
                    motionPoints = []
                    sessionNumber = JugglingSessionIdentity.next()
                    camera.start()
                    // The HUD builds back in as the editor slides away.
                    Task {
                        try? await Task.sleep(for: .milliseconds(220))
                        hudShown = true
                    }
                }
            )
            .onAppear {
                // Cover is up — drop overlay underneath without a black flash.
                showProcessing = false
                isFinishingSession = false
                hudShown = false
            }
        }
    }

    // MARK: - Processing

    @MainActor
    private func importMovie(_ item: PhotosPickerItem) async {
        guard !camera.isRecording, !camera.isPreparingRecording,
              !camera.isFinishingRecording, !showProcessing else { return }
        showProcessing = true
        processingProgress = 0.02
        processingStep = 0
        camera.stop()
        do {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: movie.url)
                showProcessing = false
                return
            }
            importedURL = movie.url
            importedVideo.analyse(url: movie.url)
        } catch {
            showProcessing = false
            galleryItem = nil
            importError = error.localizedDescription
            camera.start()
        }
    }

    private func beginProcessing() {
        pendingSummary = nil
        isFinishingSession = false
        // Immediate — no animation delay (that was the black gap after Stop).
        showProcessing = true
        processingProgress = 0.06
        processingStep = 0
        Task { await pulseWhileWaitingForFile() }
    }

    /// Keep the overlay alive + ticking while AVAssetWriter finishes the file.
    @MainActor
    private func pulseWhileWaitingForFile() async {
        let ticks: [(Double, Int)] = [
            (0.18, 0),
            (0.32, 0),
            (0.42, 1),
            (0.52, 1),
        ]
        for (progress, step) in ticks {
            guard showProcessing, sessionSummary == nil, !isFinishingSession else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                processingProgress = max(processingProgress, progress)
                processingStep = max(processingStep, step)
            }
            try? await Task.sleep(nanoseconds: 280_000_000)
            if pendingSummary != nil { return }
        }
    }

    @MainActor
    private func finishProcessing(with summary: SessionSummary) async {
        guard !isFinishingSession, sessionSummary == nil else { return }
        isFinishingSession = true
        showProcessing = true
        withAnimation(.easeInOut(duration: 0.25)) {
            processingStep = 1
            processingProgress = max(processingProgress, 0.55)
        }

        var finished = summary
        finished.visualTrack = try? await Task.detached(priority: .userInitiated) {
            try await BallVisualRefiner.refineVideo(
                source: summary.videoURL,
                frames: summary.track
            ) { pct in
                Task { @MainActor in
                    // Map refine 0…1 into overlay 0.55…0.92
                    let mapped = 0.55 + pct * 0.37
                    withAnimation(.linear(duration: 0.12)) {
                        self.processingProgress = max(self.processingProgress, mapped)
                        self.processingStep = pct < 0.85 ? 2 : 3
                    }
                }
            }
        }.value

        withAnimation(.easeInOut(duration: 0.25)) {
            processingProgress = 1
            processingStep = 4
        }
        // Leaves time for the overlay's completion beat before the editor takes over.
        try? await Task.sleep(nanoseconds: 420_000_000)

        pendingSummary = nil
        // Present the editor first; overlay hides in cover onAppear.
        presentWithoutSlide(finished)
    }

    /// The processing overlay and editor share a dark ground, so the cover appears in
    /// place and the editor's own entrance carries the motion instead of a modal slide.
    private func presentWithoutSlide(_ summary: SessionSummary) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { sessionSummary = summary }
    }

    // MARK: - Ball tracking

    @ViewBuilder
    private func ballOverlay(in size: CGSize) -> some View {
        let sample: BallStyleSample? = camera.ballBox.flatMap {
            BallStyleSample(box: $0, confidence: camera.ballScore,
                            velocityY: camera.ballVelocityY)
        }
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            BallStyleOverlay(
                style: liveStyle,
                presentation: .live,
                intensity: liveIntensity,
                sample: sample,
                trail: liveTrail,
                time: timeline.date.timeIntervalSinceReferenceDate
            )
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Capture HUD

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button {
                    if camera.isRecording {
                        timerRunning = false
                        beginProcessing()
                        camera.stopRecording()
                    } else { camera.stop(); dismiss() }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel("Close").accessibilityIdentifier("capture-close")
                .disabled(camera.isPreparingRecording || camera.isFinishingRecording)
                Spacer()
                CaptureSessionBadge(number: sessionNumber, recording: camera.isRecording,
                                    preparing: camera.isPreparingRecording)
            }.zIndex(1)
            CaptureTouchCounter(count: controlState == .ready ? 0 : camera.touchCount, warn: camera.tooShaky)
                .allowsHitTesting(false)
            if camera.tooShaky {
                Text("Hold the camera steadier").font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                    .transition(.sessionDrop)
            }
        }
        .foregroundStyle(.white).padding(.horizontal, 24).padding(.top, 8)
        .animation(SessionMotion.snap, value: camera.tooShaky)
    }

    private var cameraStatus: some View {
        VStack {
            if !camera.isReady && !controlState.isBusy {
                Text(camera.status == "camera permission denied" ? "Allow camera access in Settings, or choose a video." :
                     camera.status == "camera unavailable" ? "Camera unavailable. Choose a video to get started." : "Starting camera…")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                    .accessibilityIdentifier("capture-camera-status")
                    .transition(.sessionRise)
            }
        }
        .animation(SessionMotion.fade, value: camera.isReady)
    }

    // MARK: - Bottom

    private var controlState: CaptureControlState {
        if showProcessing || camera.isFinishingRecording { return .finishing }
        if camera.isPreparingRecording { return .preparing }
        return camera.isRecording ? .recording : .ready
    }

    private var bottomBar: some View {
        CaptureControls(state: controlState, cameraReady: camera.isReady,
            onGallery: { showGallery = true },
            onRecord: {
                if camera.isRecording {
                    timerRunning = false
                    beginProcessing()
                    camera.stopRecording()
                } else {
                    elapsed = 0
                    camera.startRecording()
                }
            },
            onFlip: { camera.flipCamera() })
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Experimental detector diagnostics

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if camera.isPreparingRecording {
                Text("Preparing recording and detection…")
            } else if !camera.isRecording {
                Text(camera.isReady ? "Preview only · detection off" : camera.status)
                    .accessibilityIdentifier("record-detection-idle")
            } else {
                HStack {
                    Text(String(format: "%.0f processed fps", camera.fps))
                    Spacer()
                    Text(String(format: "ball %.2f", camera.ballScore))
                    Spacer()
                    Text("seen \(camera.detections)")
                }
                Text(camera.performance.model)
                Text(String(format: "inference %.0f ms · detector %.0f ms · p95 %.0f ms",
                            camera.performance.inferenceMS, camera.performance.totalMS, camera.performance.p95MS))
                Text(String(format: "app %.0f MB · peak %.0f MB · load %.0f ms",
                            camera.performance.memoryMB, camera.performance.peakMemoryMB, camera.performance.modelLoadMS))
                Text("capture drops \(camera.performance.captureDrops) · thermal \(camera.performance.thermal)")
            }
            if let log = camera.performance.logURL {
                ShareLink("Share performance CSV", item: log)
            }
            if let err = camera.detectorError {
                Text(err).foregroundStyle(Theme.warn)
            }
        }
        .font(Theme.mono)
        .foregroundStyle(.white.opacity(0.8))
        .padding(12)
        .background(Theme.panel(RoundedRectangle(cornerRadius: 12)))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func formatElapsed(_ t: TimeInterval) -> String {
        let total = max(0, Int(t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Back-compat alias used by older call sites.
typealias LiveView = RecordView
