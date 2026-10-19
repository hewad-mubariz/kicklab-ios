//
//  RecordView.swift
//  kicklab
//
//  Live juggling capture HUD. Preview and a bounded model warmup run on entry.
//  Detection and recording start only on Record, after tracking is ready.
//

import AVFoundation
import Combine
import PhotosUI
import SwiftUI

struct RecordView: View {
    @State private var recoveredVideoSaved = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var player: PlayerStore
    @State private var sessionOwner: UUID?
    @State private var resultID = UUID()
    @State private var resultStartedAt = Date()
    @StateObject private var camera = CameraSession()
    @StateObject private var importedVideo = VideoAnalyzer()

    @State private var showGallery = false
    @State private var galleryItem: PhotosPickerItem?
    @State private var importedURL: URL?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?
    @State private var elapsed: TimeInterval = 0
    @State private var timerRunning = false
    @State private var comboPeak = 0
    @State private var sessionNumber = JugglingSessionIdentity.next()
    @State private var motionPoints: [CaptureMotionPoint] = []

    @State private var showProcessing = false
    @State private var processingProgress: Double = 0
    @State private var processingStep = 0
    @State private var pendingSummary: SessionSummary?
    @State private var sessionSummary: SessionSummary?
    @State private var isFinishingSession = false
    @State private var hudShown = false

    #if DEBUG
    @AppStorage("debug.touchOutlines") private var showTouchOutlines = true
    @State private var processingReviewStarted = false
    private var processingReviewPath: String? { SessionDesignReview.argument("--capture-processing-video") }
    #else
    private var processingReviewPath: String? { nil }
    #endif

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
                            if camera.isRecording && subscriptions.isPro {
                                LiveEffectSurface(frames: camera.liveEffectFrames)
                            }
                            #if DEBUG
                            if camera.isRecording && showTouchOutlines {
                                ActivePlayerDebugOverlay(players: camera.activePlayers, selection: camera.activePlayer,
                                                         fillsFrame: true)
                                LiveTouchDebugOverlay(event: camera.touchDiagnostic)
                            }
                            #endif
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
                        CaptureMetrics(points: motionPoints, touchTimes: camera.recentTouchTimes, time: elapsed,
                                       showGraph: subscriptions.isPro, showsTouchMetrics: subscriptions.isPro)
                            .padding(.horizontal, 24).padding(.bottom, 14)
                            .sessionEntrance(hudShown, order: 2)
                        cameraStatus
                        #if DEBUG && TOUCH_COUNTING_DEBUG
                        DebugFrameTestControls(camera: camera)
                        #endif
                        bottomBar.sessionEntrance(hudShown, order: 3, offset: 28)
                    }
                }
            }

            // Full-screen — outside the geo stack so Stop never flash-blacks. The overlay's own
            // background fills the screen; its content stays inside the safe area.
            if showProcessing {
                importProcessingOverlay
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .statusBarHidden(false)
        .debugRuntimeOverlay(performance: camera.performance, capture: camera.capturePerformance,
                             recording: camera.isRecording)
        .preferredColorScheme(.dark)
        .onAppear {
            if galleryItem == nil, processingReviewPath == nil { camera.start() }
            hudShown = true
        }
        .task {
            #if DEBUG
            if let path = processingReviewPath {
                await reviewSavedCapture(path)
                return
            }
            #endif
        }
        .onDisappear {
            timerRunning = false
            camera.stop()
            if importedVideo.isRunning { importTask?.cancel(); importedVideo.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                if camera.isRecording { beginProcessing() }
                timerRunning = false
                camera.stop()
            } else if phase == .active, !showProcessing, sessionSummary == nil,
                      importedURL == nil, processingReviewPath == nil {
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
        .onChange(of: camera.recordingElapsed) { _, time in
            guard camera.isRecording else { return }
            elapsed = time
            motionPoints.append(CaptureMotionPoint(time: time, y: camera.ballBox.map { Double($0.midY) }))
            motionPoints.removeAll { $0.time < time - 6 }
        }
        .onChange(of: camera.isRecording) { _, recording in
            timerRunning = recording
            if recording {
                ProductAnalytics.shared.track(.trainingStarted(.juggling))
                sessionOwner = account.user?.id
                resultID = UUID(); resultStartedAt = Date()
                comboPeak = 0
                motionPoints = []
                sessionNumber = JugglingSessionIdentity.begin()
            }
        }
        .onChange(of: camera.isFinishingRecording) { _, finishing in
            // Keep the save/review flow synchronized with recorder finalization.
            if finishing, camera.recordingError == nil, !showProcessing { beginProcessing() }
            if !finishing, let error = camera.recordingError { importError = error }
        }
        .onChange(of: camera.recordingError) { _, error in
            guard let error else { return }
            timerRunning = false
            showProcessing = false
            if !camera.isFinishingRecording { importError = error }
        }
        .onChange(of: camera.recordingURL) { _, url in
            guard let url, showProcessing, camera.recordingError == nil else { return }
            var summary = SessionSummary.make(
                touches: camera.touchCount,
                duration: elapsed,
                bestCombo: max(comboPeak, camera.touchCount),
                personalBest: JugglingRecords.personalBest,
                videoURL: url,
                touchesMarked: camera.recordedTouches,
                track: camera.recordedTrack, sessionNumber: sessionNumber
            )
            summary.debugContacts = camera.recordedDiagnostics
            pendingSummary = summary
            finishProcessing(with: summary)
            saveAccountResult(summary, source: .recording)
        }
        .photosPicker(isPresented: $showGallery, selection: $galleryItem, matching: .videos, preferredItemEncoding: .current)
        .onChange(of: galleryItem, initial: true) { _, item in
            guard let item else { return }
            importTask = Task { await importMovie(item) }
        }
        .onChange(of: importedVideo.progress) { _, progress in
            guard importedURL != nil else { return }
            processingProgress = 0.1 + progress * 0.8
            processingStep = progress < 0.85 ? 1 : 2
        }
        .onChange(of: importedVideo.isRunning) { _, running in
            importDidFinish(running: running)
        }
        .alert("Video unavailable", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            if camera.recordingError != nil, let recovered = camera.recordingURL {
                Button("Save available video") {
                    importError = nil
                    Task {
                        do {
                            try await ShotEffectExporter.saveToPhotos(recovered)
                            recoveredVideoSaved = true
                        } catch { importError = error.localizedDescription }
                    }
                }
            }
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Please try another video.")
        }
        .videoSavedConfirmation(isPresented: $recoveredVideoSaved)
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
                },
                historySessionID: resultID,
                ownerID: sessionOwner
            )
            .onAppear {
                // Cover is up — drop overlay underneath without a black flash.
                showProcessing = false
                isFinishingSession = false
                hudShown = false
            }
        }
    }

    #if DEBUG
    /// Exercises the real saved-capture processing and nested editor presentation.
    /// Unlike --session-design, this retains the normal settings persistence path.
    @MainActor
    private func reviewSavedCapture(_ path: String) async {
        guard !processingReviewStarted else { return }
        processingReviewStarted = true
        if UserDefaults.standard.data(forKey: "kicklab.export.overlays.v1") == nil {
            ExportOverlaySettings().save()
        }
        let url = SessionDesignReview.fileURL(path)
        beginProcessing()
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            // Select fresh saved-pixel mask analysis; this sentinel is not a detection
            // or a touch. The resulting visual track comes entirely from the video.
            let maskedCapture = RecordedFrame(time: 0, x: 0, y: 0, width: 0, height: 0,
                score: 0, smoothedX: 0, smoothedY: 0, vy: 0, motion: .unknown,
                detected: false, person: nil, usesBallMasks: true)
            let summary = SessionSummary.make(touches: 0, duration: duration, bestCombo: 0,
                personalBest: JugglingRecords.personalBest, videoURL: url,
                touchesMarked: [], track: [maskedCapture], sessionNumber: sessionNumber)
            pendingSummary = summary
            finishProcessing(with: summary)
            // Exercise real persistence only with the isolated, network-free UI
            // review store. Normal detector reviews never submit sample scores.
            if SessionHistoryReview.requested { saveAccountResult(summary, source: .recording) }
        } catch {
            showProcessing = false
            importError = error.localizedDescription
        }
    }
    #endif

    // MARK: - Processing

    private func importDidFinish(running: Bool) {
        guard !running, let url = importedURL else { return }
        importedURL = nil
        galleryItem = nil
        guard importedVideo.status == "done" else {
            try? FileManager.default.removeItem(at: url)
            showProcessing = false
            if importedVideo.status != "cancelled" {
                importError = importedVideo.status
                camera.start()
            }
            return
        }
        var summary = SessionSummary.make(
            touches: importedVideo.touchCount, duration: importedVideo.videoDuration,
            bestCombo: importedVideo.touchCount, personalBest: JugglingRecords.personalBest,
            videoURL: url, touchesMarked: importedVideo.recordedTouches,
            track: importedVideo.recordedTrack, sessionNumber: JugglingSessionIdentity.begin())
        if !importedVideo.visualRecoveries.isEmpty { summary.visualTrack = importedVideo.renderTrack }
        summary.debugContacts = importedVideo.counterTrace?.diagnostics ?? []
        finishProcessing(with: summary, framesUseCompositionClock: true)
        saveAccountResult(summary, source: .gallery)
    }

    private var importProcessingOverlay: some View {
        let cancel: (() -> Void)? = importedURL == nil ? nil : { cancelImport() }
        let message = importedVideo.isCooling ? "Cooling down. Your video will continue automatically."
            : importedVideo.isRunning && !importedVideo.canContinueInBackground
                ? "Keep Juggle Dude open. Processing resumes when you return." : nil
        return ProcessingOverlay(progress: processingProgress, stepIndex: processingStep,
                                 statusMessage: message, onCancel: cancel, isPaused: importedVideo.isCooling,
                                 videoInfo: importedURL == nil ? nil : importedVideo.processingInfo)
    }

    @MainActor
    private func cancelImport() {
        let source = importedURL
        importedURL = nil
        galleryItem = nil
        importTask?.cancel()
        importedVideo.cancel()
        showProcessing = false
        if scenePhase == .active { camera.start() }
        Task {
            await importedVideo.waitUntilFinished()
            if let source { try? FileManager.default.removeItem(at: source) }
        }
    }

    @MainActor
    private func importMovie(_ item: PhotosPickerItem) async {
        guard !camera.isRecording, !camera.isPreparingRecording,
              !camera.isFinishingRecording, !showProcessing else { return }
        sessionOwner = account.user?.id
        resultID = UUID(); resultStartedAt = Date()
        ProductAnalytics.shared.track(.importStarted)
        showProcessing = true
        processingProgress = 0.02
        processingStep = 0
        camera.stop()
        do {
            try await VideoBackgroundWork.shared.run(title: "Importing video") {
                try await importSelectedMovie(item)
            }
            ProductAnalytics.shared.track(.importFinished(.completed))
        } catch is CancellationError {
            ProductAnalytics.shared.track(.importFinished(.cancelled))
            showProcessing = false
            galleryItem = nil
        } catch {
            ProductAnalytics.shared.track(.importFinished(.failed))
            showProcessing = false
            galleryItem = nil
            importError = error.localizedDescription
            camera.start()
        }
    }

    @MainActor
    private func importSelectedMovie(_ item: PhotosPickerItem) async throws {
        // Cancel can return to the picker before the previous worker has
        // released its reader/model. Let that teardown finish before a new
        // URL is published; analyse() deliberately ignores overlapping calls.
        await importedVideo.waitUntilFinished()
        try Task.checkCancellation()
        guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: movie.url)
            throw CancellationError()
        }
        importedURL = movie.url
        importedVideo.analyse(url: movie.url)
        await importedVideo.waitUntilFinished()
        try Task.checkCancellation()
        if importedVideo.status != "done" {
            throw NSError(domain: "VideoImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: importedVideo.status])
        }
    }

    private func saveAccountResult(_ summary: SessionSummary, source: SavedJugglingResult.Source) {
        if source == .recording {
            ProductAnalytics.shared.track(.trainingCompleted(.juggling, duration: summary.duration))
        }
        let completed = source == .recording ? resultStartedAt.addingTimeInterval(summary.duration) : resultStartedAt
        player.recordSession(id: resultID, owner: sessionOwner, summary: summary,
            source: source, completedAt: completed)
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
    private func finishProcessing(with summary: SessionSummary, framesUseCompositionClock: Bool = false) {
        guard !isFinishingSession, sessionSummary == nil else { return }
        isFinishingSession = true
        showProcessing = true
        withAnimation(.easeInOut(duration: 0.25)) {
            processingStep = 1
            processingProgress = max(processingProgress, 0.55)
        }

        var finished = summary
        finished.framesUseCompositionClock = framesUseCompositionClock
        finished.needsVisualPreparation = !summary.track.isEmpty
        // The live/import count and video are already ready. Precise ball effects
        // belong to a shared on-demand session task, never the Save gate.
        processingProgress = 1
        processingStep = 4

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
                .accessibilityLabel(camera.isPreparingRecording ? "Cancel recording setup" : "Close")
                .accessibilityIdentifier("capture-close")
                .disabled(camera.isFinishingRecording)
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
        VStack(spacing: 8) {
            if camera.trackingPreparationError != nil, !controlState.isBusy {
                Text("Tracking couldn’t get ready.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                Button("Try again") { camera.prepareTracking() }
                    .font(.system(size: 14, weight: .semibold)).tint(SessionStyle.mint)
                    .frame(minHeight: 44)
                    .disabled(!camera.isReady)
                    .accessibilityIdentifier("capture-retry-preparation")
            }
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
        if camera.isPreparingTracking { return .warming }
        return camera.isRecording ? .recording : .ready
    }

    private var bottomBar: some View {
        CaptureControls(state: controlState, cameraReady: camera.isReady, trackingReady: camera.isTrackingReady,
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


}

/// Back-compat alias used by older call sites.
typealias LiveView = RecordView
