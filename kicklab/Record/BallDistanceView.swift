import PhotosUI
import SwiftUI

/// Record first, then open the Power Shot editor. Ground-distance capture is
/// preserved in BallDistanceGroundCaptureView for later validation.
struct BallDistanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var player: PlayerStore
    @StateObject private var camera = CameraSession(pipeline: .videoOnly)
    @State private var showGallery = false
    @State private var showSavedShots = false
    @State private var galleryItem: PhotosPickerItem?
    @State private var editor: ShotEditorRequest?
    @State private var error: String?
    @State private var temporaryMedia: [URL] = []
    /// An import the player leaves before it's tracked isn't kept; a recording always is.
    @State private var openedImport: (id: UUID, owner: UUID?)?
    @State private var shotNotSaved = false
    @State private var opensReplayAfterSave = false
    @State private var reviewRecording = false

    #if DEBUG
    private var designState: String? {
        let value = SessionDesignReview.argument("--ball-distance-design")
        return value == "live" ? nil : value
    }
    #else
    private var designState: String? { nil }
    #endif

    private var isRecording: Bool { designState == nil ? camera.isRecording : reviewRecording }
    private var isBusy: Bool { isRecording || camera.isPreparingRecording || camera.isFinishingRecording }
    private var cameraShouldRun: Bool {
        scenePhase == .active && !showGallery && !showSavedShots && editor == nil
    }
    private var canRecord: Bool {
        designState == nil ? camera.canRecord : designState != "denied"
    }
    private var permissionDenied: Bool {
        designState == "denied" || camera.status == "camera permission denied"
    }
    /// Nothing to say once the camera is ready: the shutter is the next step.
    private var showsGuidance: Bool { isBusy || permissionDenied || !canRecord }

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
                            Spacer(minLength: 0)
                        }
                        VStack(spacing: 14) {
                            Spacer(minLength: 0)
                            if showsGuidance { guidance }
                            captureControls
                        }.frame(width: min(330, geometry.size.width * 0.43))
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        topBar
                        Spacer(minLength: 20)
                        if showsGuidance { guidance.padding(.bottom, 24) }
                        captureControls.padding(.bottom, 10)
                        Text("Record your shot. Add your effects after.")
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
        .sheet(isPresented: $showSavedShots) { SavedShotsView(library: player.shots, owner: player.userID) }
        .fullScreenCover(item: $editor, onDismiss: finishEditor) { request in
            ShotEffectsReplayView(trackCache: request.trackCache, onLookChange: request.onLookChange, onClose: {
                editor = nil
            }, prepare: request.prepare)
        }
        .task(id: cameraShouldRun) {
            guard designState == nil else { return }
            if cameraShouldRun { camera.start() }
            else { camera.stop() }
        }
        .onAppear { reviewRecording = designState == "recording" }
        .onDisappear { camera.stop() }
        .onChange(of: camera.recordingURL) { _, _ in openSavedCaptureIfReady() }
        .onChange(of: camera.recordingError) { _, message in
            if let message { error = message; opensReplayAfterSave = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { openSavedCaptureIfReady() }
        }
        .alert("Video unavailable", isPresented: Binding(get: { error != nil },
            set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private func cameraBackground(size: CGSize) -> some View {
        if designState != nil {
            GeometryReader { viewport in
                Image("home-power-shot").resizable().scaledToFill()
                    .frame(width: viewport.size.width, height: viewport.size.height).clipped()
            }.ignoresSafeArea().allowsHitTesting(false)
        } else {
            CameraPreview(session: camera.captureSession, followsDeviceOrientation: true)
                .ignoresSafeArea().allowsHitTesting(false)
                .accessibilityLabel("Camera for Ball Distance")
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 16) {
            Button { camera.stop(); dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .medium))
                    .frame(width: 32, height: 32)
            }.appGlassButtonStyle().buttonBorderShape(.circle).disabled(isBusy)
                .accessibilityLabel("Close Ball Distance").accessibilityIdentifier("ball-distance-close")
                // Both sides share one width so the title stays centered.
                .frame(width: 76, alignment: .leading)
            Spacer(minLength: 0)
            VStack(spacing: 5) {
                Text("BALL DISTANCE").font(.system(size: 11, weight: .semibold)).tracking(1.8)
                    .accessibilityIdentifier("ball-distance-title")
                Text(isRecording ? "● REC  \(ExportPreviewTime.label(at: designState == nil ? camera.recordingElapsed : 7))" : "RECORD + EFFECTS")
                    .font(.system(size: 9, weight: .medium)).tracking(1).monospacedDigit()
                    .foregroundStyle(isRecording ? Color.red.opacity(0.95) : .white.opacity(0.65))
                    .accessibilityIdentifier("ball-distance-recording-status")
            }.frame(minHeight: 44)
            Spacer(minLength: 0)
            savedShotsButton.frame(width: 76, alignment: .trailing)
        }
    }

    private var savedShotsButton: some View {
        VStack(spacing: 5) {
            Button { showSavedShots = true } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 18))
                    .frame(width: 32, height: 32)
            }.appGlassButtonStyle().buttonBorderShape(.circle)
                .accessibilityLabel("Saved shots").accessibilityIdentifier("ball-distance-saved-shots")
            Text("Saved").font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .accessibilityHidden(true)
                // The word under the icon answers too, so a tap that lands on it is not lost.
                .contentShape(.rect).onTapGesture { showSavedShots = true }
        }.disabled(isBusy)
    }

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.isFinishingRecording {
                Label("Saving your video…", systemImage: "arrow.down.circle")
                    .accessibilityIdentifier("ball-distance-saving")
            } else if camera.isPreparingRecording {
                Label("Starting your recording…", systemImage: "video")
            } else if isRecording {
                Label("Keep the full shot in view", systemImage: "viewfinder")
                Text("Tap Stop when you’re ready to add effects.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
            } else if permissionDenied {
                Label("Allow camera access", systemImage: "camera")
                Text("Enable Camera in Settings, or import a video below.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.tint(SessionStyle.mint)
            } else if camera.status == "camera unavailable" {
                Label("Camera unavailable", systemImage: "camera")
                Button("Try again") { camera.stop(); camera.start() }.tint(SessionStyle.mint)
            } else {
                Label("Opening camera…", systemImage: "camera")
            }
        }
        .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).background(.black.opacity(0.48), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
    }

    private var captureControls: some View {
        HStack(alignment: .center) {
            sideButton("Import", symbol: "photo.on.rectangle") { showGallery = true }
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
                    Text(camera.isFinishingRecording ? "Saving…" : camera.isPreparingRecording ? "Starting…" : isRecording ? "Stop" : "Record")
                        .font(.system(size: 11, weight: .semibold))
                }.contentShape(.rect)
            }.buttonStyle(.plain)
                .disabled(camera.isPreparingRecording || camera.isFinishingRecording || (!isRecording && !canRecord))
                .accessibilityLabel(isRecording ? "Stop recording" : "Record video")
                .accessibilityIdentifier("ball-distance-record")
                // Refresh the native hit region when the shutter changes back from Stop.
                .id(isRecording)
            Spacer(minLength: 12)
            sideButton("Flip", symbol: "arrow.triangle.2.circlepath.camera") { camera.flipCamera() }
                .disabled(designState == nil && !camera.isReady)
                .accessibilityIdentifier("ball-distance-flip")
        }.frame(maxWidth: 400).frame(maxWidth: .infinity)
    }

    private func sideButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 21)).frame(width: 46, height: 46)
                    .appGlass(in: .circle)
                Text(title).font(.system(size: 10, weight: .medium))
            }.frame(width: 76).contentShape(.rect)
        }.buttonStyle(SessionPressStyle(scale: 0.92)).disabled(isBusy)
    }

    private func record() {
        if designState != nil { reviewRecording.toggle(); return }
        if camera.isRecording { camera.stopRecording() }
        else if camera.canRecord {
            opensReplayAfterSave = true
            camera.startRecording()
        }
    }

    private func openImportIfReady() {
        guard !showGallery, let item = galleryItem, editor == nil else { return }
        galleryItem = nil
        beginProcessing(source: .gallery) {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: movie.url)
                throw CancellationError()
            }
            temporaryMedia.append(movie.url)
            return movie.url
        }
    }

    private func openSavedCaptureIfReady() {
        guard opensReplayAfterSave, !camera.isFinishingRecording, camera.recordingError == nil,
              scenePhase == .active, let video = camera.recordingURL, editor == nil else { return }
        opensReplayAfterSave = false
        temporaryMedia.append(video)
        camera.clearRecording()
        beginProcessing(source: .recording) { video }
    }

    /// The shot is saved before the editor opens, so it's kept however the editor ends.
    private func beginProcessing(source: SavedJugglingResult.Source, _ load: @escaping @MainActor () async throws -> URL) {
        guard editor == nil else { return }
        error = nil
        camera.stop()
        let library = player.shots, owner = player.userID, id = UUID(), completedAt = Date()
        openedImport = source == .gallery ? (id, owner) : nil
        editor = ShotEditorRequest(trackCache: library.trackURL(id: id, owner: owner), prepare: {
            try Task.checkCancellation()
            let video = try await load()
            do {
                let shot = try await library.add(video: video, id: id, owner: owner, source: source, completedAt: completedAt)
                return (library.videoURL(for: shot), nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Editing still works on the temporary file; the player hears it wasn't kept after.
                shotNotSaved = true
                return (video, nil)
            }
        }, onLookChange: { try? library.saveLook($0, id: id, owner: owner) })
    }

    private func finishEditor() {
        removeTemporaryMedia()
        if let openedImport, !FileManager.default.fileExists(atPath: player.shots.trackURL(id: openedImport.id, owner: openedImport.owner).path) {
            try? player.shots.remove(id: openedImport.id, owner: openedImport.owner)
        }
        openedImport = nil
        if shotNotSaved {
            shotNotSaved = false
            error = String(localized: "This shot couldn’t be saved on this phone, so it won’t appear in Saved shots.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
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
    var onLookChange: ((ShotReplayLook) -> Void)? = nil
}
