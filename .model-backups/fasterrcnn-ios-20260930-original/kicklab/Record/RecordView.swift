//
//  RecordView.swift
//  kicklab
//
//  Live juggling capture HUD. Preview runs immediately; recording starts only
//  when you hit Start. Stop shows a processing overlay, then the post-session
//  flow (Complete → Effects / Stats → Share).
//

import AVFoundation
import Combine
import PhotosUI
import SwiftUI

struct RecordView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraSession()
    @StateObject private var importedVideo = VideoAnalyzer()

    @State private var pulses: [Int: CGPoint] = [:]
    @State private var showGallery = false
    @State private var galleryItem: PhotosPickerItem?
    @State private var importedURL: URL?
    @State private var importError: String?
    @State private var elapsed: TimeInterval = 0
    @State private var timerRunning = false
    @State private var showDiagnostics = false
    @State private var comboPeak = 0
    @State private var liveTrail: [BallStyleSample] = []
    /// Subtle live skin — Neon instrument; full styles picked in Replay.
    private let liveStyle = BallStyle.neon
    private let liveIntensity = 0.85

    @State private var showProcessing = false
    @State private var processingProgress: Double = 0
    @State private var processingStep = 0
    @State private var pendingSummary: SessionSummary?
    @State private var sessionSummary: SessionSummary?
    @State private var isFinishingSession = false

    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                ZStack {
                    CameraPreview(session: camera.captureSession)
                        .ignoresSafeArea()

                    if let person = camera.personBox {
                        TrackingCorners(rect: person)
                            .frame(width: geo.size.width, height: geo.size.height)
                    }

                    ballOverlay(in: geo.size)

                    ForEach(Array(pulses.keys), id: \.self) { token in
                        if let p = pulses[token] {
                            TouchPulse(position: CGPoint(x: p.x * geo.size.width,
                                                         y: p.y * geo.size.height))
                        }
                    }

                    LinearGradient(
                        colors: [.black.opacity(0.50), .clear, .black.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                    VStack(spacing: 0) {
                        topBar
                        Spacer(minLength: 0)
                        if showDiagnostics { diagnosticsPanel }
                        bottomBar
                    }

                    HStack {
                        Spacer()
                        sideStats
                            .padding(.trailing, 14)
                    }
                    .padding(.top, 168)
                    .frame(maxHeight: .infinity, alignment: .top)
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
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .onAppear {
            camera.start()
        }
        .onDisappear {
            timerRunning = false
            camera.stop()
        }
        .onReceive(timer) { _ in
            guard timerRunning, camera.isRecording else { return }
            elapsed += 0.25
        }
        .onChange(of: camera.lastTouchToken) { _, token in
            guard let at = camera.lastTouchAt else { return }
            pulses[token] = at
            comboPeak = max(comboPeak, camera.touchCount)
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                pulses.removeValue(forKey: token)
            }
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
        .onChange(of: camera.isRecording) { _, recording in
            if !recording { timerRunning = false }
            if recording {
                comboPeak = 0
                liveTrail = []
            }
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
                track: camera.recordedTrack
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
            sessionSummary = SessionSummary.make(
                touches: importedVideo.touchCount,
                duration: importedVideo.videoDuration,
                bestCombo: importedVideo.touchCount,
                personalBest: JugglingRecords.personalBest,
                videoURL: url,
                touchesMarked: importedVideo.recordedTouches,
                track: importedVideo.recordedTrack
            )
        }
        .alert("Couldn’t open video", isPresented: Binding(
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
                    camera.start()
                }
            )
            .onAppear {
                // Cover is up — drop overlay underneath without a black flash.
                showProcessing = false
                isFinishingSession = false
            }
        }
    }

    // MARK: - Processing

    @MainActor
    private func importMovie(_ item: PhotosPickerItem) async {
        guard !camera.isRecording, !showProcessing else { return }
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
        try? await Task.sleep(nanoseconds: 280_000_000)

        pendingSummary = nil
        // Present Session Complete first; overlay hides in cover onAppear.
        sessionSummary = finished
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

    private var sideStats: some View {
        VStack(spacing: 10) {
            LiveStatCard(symbol: "shoe", value: "\(camera.touchCount)", label: "Touches")
            LiveStatCard(symbol: "arrow.up.and.down", value: heightLabel, label: "Height")
            LiveStatCard(symbol: "bolt.fill", value: "\(max(comboPeak, camera.touchCount))", label: "Combo")
        }
        .opacity(camera.isRecording ? 1 : 0.55)
    }

    private var heightLabel: String {
        guard let ball = camera.ballBox else { return "—" }
        let estimate = max(0.2, min(1.6, (1.0 - Double(ball.midY)) * 1.4))
        return String(format: "%.1f m", estimate)
    }

    // MARK: - Top

    private var topBar: some View {
        ZStack(alignment: .top) {
            HStack {
                Button {
                    if camera.isRecording { camera.stopRecording() }
                    camera.stop()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(SessionStyle.panel.opacity(0.65), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.7))
                }
                .accessibilityLabel("Close")

                Spacer()

                recBadge
            }

            VStack(spacing: 4) {
                LiveTouchCounter(
                    value: camera.touchCount,
                    warn: camera.tooShaky,
                    size: 100
                )

                if camera.tooShaky {
                    Text("Hold the camera steadier")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.warn)
                } else if camera.isRecording {
                    Text("Touches in a row")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                } else {
                    Text("Hit start when ready")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .padding(.top, 36)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
    }

    private var recBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(camera.isRecording ? 1 : 0.35)
            Text(camera.isRecording ? "REC" : "READY")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
            Text(formatElapsed(elapsed))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 28) {
            sideControl(
                systemName: "photo.on.rectangle",
                title: "Gallery"
            ) {
                showGallery = true
            }
            .accessibilityLabel("Choose video from gallery")
            .accessibilityIdentifier("record-gallery-picker")
            .opacity(camera.isRecording || showProcessing ? 0.35 : 1)
            .disabled(camera.isRecording || showProcessing)

            Button {
                if camera.isRecording {
                    timerRunning = false
                    beginProcessing()
                    camera.stopRecording()
                } else {
                    elapsed = 0
                    timerRunning = true
                    camera.startRecording()
                }
            } label: {
                VStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.red.opacity(0.95), lineWidth: 2)
                            .shadow(color: .red.opacity(0.65), radius: 12)
                            .frame(width: 78, height: 78)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white)
                                .frame(width: 28, height: 28)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 64, height: 64)
                        }
                    }
                    Text(camera.isRecording ? "Stop Recording" : "Start Recording")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .buttonStyle(.plain)
            .disabled(showProcessing)
            .accessibilityLabel(camera.isRecording ? "Stop Recording" : "Start Recording")

            sideControl(systemName: "arrow.triangle.2.circlepath.camera", title: "Flip") {
                camera.flipCamera()
            }
            .opacity(camera.isRecording || showProcessing ? 0.35 : 1)
            .disabled(camera.isRecording || showProcessing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .padding(.top, 8)
    }

    private func sideControl(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(SessionStyle.panel.opacity(0.65), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 0.7))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .buttonStyle(.plain)
        .frame(width: 72)
    }

    // MARK: - Diagnostics (hidden)

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: "%.0f fps", camera.fps))
                Spacer()
                Text(String(format: "ball %.2f", camera.ballScore))
                Spacer()
                Text("seen \(camera.detections)")
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
