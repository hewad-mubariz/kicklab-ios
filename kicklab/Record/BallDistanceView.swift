import ARKit
import Combine
import PhotosUI
import SwiftUI

/// Product capture: calibrated ground distance for new recordings, visual
/// effects for imports. The full experiment screen remains a separate tool.
struct BallDistanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var capture = ShotGeometryCapture()
    @State private var showGallery = false
    @State private var galleryItem: PhotosPickerItem?
    @State private var selectedRecording: ShotRecording?
    /// The Power Shot editor; it runs the processing screen (preparing and tracking) itself.
    @State private var editor: ShotEditorRequest?
    @State private var error: String?
    @State private var temporaryMedia: [URL] = []
    @State private var pendingStart = false
    @State private var opensReplayAfterSave = false
    @State private var startedAt = Date()
    @State private var elapsed = 0.0
    @State private var reviewRecording = false
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    #if DEBUG
    private var designState: String? { SessionDesignReview.argument("--ball-distance-design") }
    #else
    private var designState: String? { nil }
    #endif

    private var isRecording: Bool { designState == nil ? capture.recording : reviewRecording }
    /// ARKit has the floor and the resting ball on it. There is no separate setup step: the
    /// distance uses ARKit's own floor and scale, and is shown as experimental.
    private var groundReady: Bool {
        if let designState { return designState != "setup" }
        return capture.ready && capture.rollDisplay.canSetStart
    }
    private var cameraShouldRun: Bool {
        scenePhase == .active && !showGallery &&
            editor == nil && selectedRecording == nil
    }
    private var canRecord: Bool {
        if let designState { return designState != "setup" }
        return capture.canBeginRecording
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                cameraBackground(size: geometry.size)
                LinearGradient(colors: [.black.opacity(0.58), .clear, .black.opacity(0.78)],
                    startPoint: .top, endPoint: .bottom).ignoresSafeArea().allowsHitTesting(false)
                if landscape {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            topBar
                            readout(compact: true)
                            Spacer(minLength: 0)
                        }
                        VStack(spacing: 14) {
                            Spacer(minLength: 0)
                            guidance
                            captureControls
                        }.frame(width: min(330, geometry.size.width * 0.43))
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        readout(compact: false).padding(.top, 28)
                        Spacer(minLength: 20)
                        guidance.padding(.bottom, 24)
                        captureControls.padding(.bottom, 10)
                        Text("Record a roll. Add your effects after.")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                            .frame(maxWidth: .infinity).padding(.bottom, 8)
                    }.padding(.horizontal, 24).padding(.top, 8)
                }
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .photosPicker(isPresented: $showGallery, selection: $galleryItem,
            matching: .videos, preferredItemEncoding: .current)
        .onChange(of: galleryItem) { _, _ in openImportIfReady() }
        .onChange(of: showGallery) { _, _ in openImportIfReady() }
        .fullScreenCover(item: $editor) { request in
            ShotEffectsReplayView(trackCache: request.trackCache, onClose: {
                editor = nil; removeTemporaryMedia()
            }, prepare: request.prepare)
        }
        .task(id: cameraShouldRun) {
            guard designState == nil else { return }
            if cameraShouldRun { await capture.prepare() }
            else { capture.pause() }
        }
        .onAppear { reviewRecording = designState == "recording" || designState == "paused" }
        .onDisappear {
            capture.pause()
        }
        .onReceive(timer) { _ in
            guard designState == nil, capture.recording else { return }
            elapsed = Date().timeIntervalSince(startedAt)
            setStartWhenReady()
        }
        .onChange(of: capture.rollDisplay.canSetStart) { _, _ in setStartWhenReady() }
        .onChange(of: capture.finishing) { _, saving in
            if !saving, opensReplayAfterSave { openSavedCaptureIfReady() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { openSavedCaptureIfReady() }
        }
        .alert("Couldn’t open video", isPresented: Binding(get: { error != nil },
            set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private func cameraBackground(size: CGSize) -> some View {
        if designState != nil {
            Image("home-power-shot").resizable().scaledToFill()
                .frame(width: size.width, height: size.height).clipped().ignoresSafeArea()
        } else {
            // The camera never takes touches: a tap that just misses a control must not vanish into it.
            ShotGeometryPreview(capture: capture, showsTrackingOverlay: false).ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityLabel("Rear camera for ball distance")
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            Button { capture.pause(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                    .frame(width: 32, height: 32)
            }.buttonStyle(.glass).buttonBorderShape(.circle)
                .disabled(isRecording || capture.finishing)
                .accessibilityLabel("Close Ball Distance").accessibilityIdentifier("ball-distance-close")
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                Text("BALL DISTANCE").font(.system(size: 11, weight: .semibold)).tracking(1.8)
                    .accessibilityIdentifier("ball-distance-title")
                Text(isRecording ? "● REC  \(ExportPreviewTime.label(at: designState == nil ? elapsed : 7))" : "RECORD + EFFECTS")
                    .font(.system(size: 9, weight: .medium)).tracking(1).monospacedDigit()
                    .foregroundStyle(isRecording ? Color.red.opacity(0.95) : .white.opacity(0.65))
            }
            Spacer(minLength: 0)
            // Balances the back button, so the title stays centred.
            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
        }
    }

    private func readout(compact: Bool) -> some View {
        let value: String = {
            if let designState {
                return designState == "recording" || designState == "paused" ? "2.29 m" : "— m"
            }
            return capture.rollDisplay.distanceM.map { String(format: "%.2f m", $0) } ?? "— m"
        }()
        let detail = designState == "paused" ? "Last estimate · tracking paused" :
            !isRecording && !groundReady ? "Point at the ball on the ground" :
            isRecording && pendingStart ? "Hold the ball still · setting start" :
            isRecording && !capture.rollDisplay.isLive && designState == nil ? "Last estimate · tracking paused" :
            isRecording ? "From start · estimated" : "Ready for a ground roll"
        return BallDistanceReadout(value: value, detail: detail,
            paused: designState == "paused" ||
                (isRecording && !pendingStart && !capture.rollDisplay.isLive && designState == nil), compact: compact)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            if capture.finishing {
                Label("Saving your roll…", systemImage: "arrow.down.circle")
                    .accessibilityIdentifier("ball-distance-saving")
            } else if isRecording {
                Label(pendingStart ? "Keep the ball still for a moment" :
                    capture.rollDisplay.isLive || designState != nil ? "Keep the phone fixed and the ball in view" :
                    "Tracking paused · keep the ball visible", systemImage: "viewfinder")
            } else if !groundReady {
                Label("Point at the ball on the ground", systemImage: "viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityIdentifier("ball-distance-finding")
                Text(designState == nil && (capture.status.contains("access") || capture.status.contains("unavailable"))
                     ? capture.status : "Move the phone gently so it can find the floor around the resting ball.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                floorChoice
            } else {
                Label("Ready to roll", systemImage: "checkmark.circle")
                    .foregroundStyle(SessionStyle.mint)
                    .accessibilityIdentifier("ball-distance-ready")
                Text("Tap Record and keep the phone still. The start is set for you, then roll along level ground. Up to 15 seconds.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                floorChoice
            }
            if !isRecording && !capture.finishing {
                Text("Experimental: distance comes from your iPhone’s own floor tracking and can be off.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ball-distance-experimental")
            }
        }
        .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.black.opacity(0.48), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder private var floorChoice: some View {
        if capture.rollFloors.count > 1 {
            Picker("Choose the ground", selection: Binding(get: { capture.selectedRollFloorID ?? "" },
                set: { capture.selectRollFloor($0) })) {
                Text("Choose the ground").tag("")
                ForEach(Array(capture.rollFloors.enumerated()), id: \.element.id) { index, floor in
                    Text("Surface \(index + 1)").tag(floor.id)
                }
            }.pickerStyle(.menu).tint(SessionStyle.mint)
        }
    }

    private var captureControls: some View {
        HStack(alignment: .center) {
            sideButton("Import", symbol: "photo.on.rectangle", alwaysAvailable: true, action: openGallery)
                .accessibilityIdentifier("ball-distance-import")
            Spacer(minLength: 12)
            Button(action: record) {
                VStack(spacing: 10) {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(0.85), lineWidth: 3).frame(width: 80, height: 80)
                        if isRecording {
                            RoundedRectangle(cornerRadius: 7).fill(.red).frame(width: 30, height: 30)
                        } else {
                            Circle().fill(canRecord ? SessionStyle.mint : .white.opacity(0.25)).frame(width: 64, height: 64)
                            Image(systemName: "video.fill").font(.system(size: 22)).foregroundStyle(.black.opacity(0.75))
                        }
                    }
                    Text(capture.finishing ? "Saving…" : isRecording ? "Stop" : "Record")
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(.rect)
            }.buttonStyle(.plain).disabled(capture.finishing || (!isRecording && !canRecord))
                .accessibilityLabel(isRecording ? "Stop recording roll" : "Record ball distance")
                .accessibilityIdentifier("ball-distance-record")
            Spacer(minLength: 12)
            // Keeps Record centred now that Import is the only side button.
            Color.clear.frame(width: 76, height: 1).accessibilityHidden(true)
        }.frame(maxWidth: 400).frame(maxWidth: .infinity)
    }

    private func sideButton(_ title: String, symbol: String, alwaysAvailable: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 21)).frame(width: 46, height: 46)
                    .glassEffect(.regular, in: .circle)
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(width: 76)
            // The whole area answers, including the gap between icon and label.
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .disabled(!alwaysAvailable && (isRecording || capture.finishing))
    }


    /// The gallery is always reachable. A roll being recorded is stopped and saved, and does
    /// not open on its own afterwards, so the picked video is the one that opens.
    private func openGallery() {
        opensReplayAfterSave = false; pendingStart = false
        if designState == nil, capture.recording { capture.stop() }
        if designState != nil { reviewRecording = false }
        showGallery = true
    }

    private func record() {
        if designState != nil { reviewRecording.toggle(); return }
        if capture.recording { capture.stop() }
        else {
            pendingStart = true; opensReplayAfterSave = true; startedAt = Date(); elapsed = 0
            capture.begin()
            if !capture.recording { pendingStart = false; opensReplayAfterSave = false }
        }
    }

    private func setStartWhenReady() {
        guard pendingStart, capture.recording, capture.rollDisplay.canSetStart else { return }
        capture.setRollStart()
        if capture.rollDisplay.trial > 0 { pendingStart = false }
    }

    private func openImportIfReady() {
        guard !showGallery, let item = galleryItem, editor == nil else { return }
        galleryItem = nil
        beginProcessing {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            temporaryMedia.append(movie.url)
            return (movie.url, nil)
        }
    }

    private func openSelectedRecording() {
        guard let recording = selectedRecording else { return }
        selectedRecording = nil
        // The ball track is kept with the recording, so reopening skips the processing screen.
        beginProcessing(trackCache: recording.directory.appendingPathComponent("ball-track.plist")) {
            let distance = try await Task.detached { try BallDistanceTimeline.load(directory: recording.directory) }.value
            let url = try await BallDistanceMedia.uprightCopy(of: recording)
            temporaryMedia.append(url)
            return (url, distance)
        }
    }

    private func openSavedCaptureIfReady() {
        guard opensReplayAfterSave, !capture.finishing, scenePhase == .active,
              let video = capture.files.first(where: { $0.pathExtension == "mov" }), editor == nil else { return }
        opensReplayAfterSave = false; pendingStart = false
        let recording = ShotRecording(directory: video.deletingLastPathComponent(), date: Date(),
            frameCount: 0, limitedFrames: 0, bytes: 0)
        selectedRecording = recording; openSelectedRecording()
    }

    /// Opens the editor at once; its processing screen prepares the video and tracks the ball.
    private func beginProcessing(trackCache: URL? = nil,
                                 _ load: @escaping @MainActor () async throws -> (URL, BallDistanceTimeline?)) {
        guard editor == nil else { return }
        error = nil; capture.pause()
        editor = ShotEditorRequest(trackCache: trackCache) {
            // The camera's detector must let go of the model before the video is tracked.
            await capture.waitForDetectorRelease()
            try Task.checkCancellation()
            return try await load()
        }
    }

    private func removeTemporaryMedia() {
        for url in temporaryMedia { try? FileManager.default.removeItem(at: url) }
        temporaryMedia = []
    }
}

struct ShotEditorRequest: Identifiable {
    let id = UUID()
    let trackCache: URL?
    let prepare: @MainActor () async throws -> (URL, BallDistanceTimeline?)
}
