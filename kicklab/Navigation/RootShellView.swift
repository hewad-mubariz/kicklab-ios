import PhotosUI
import SwiftUI

struct RootShellView: View {
    @AppStorage("kicklab.appearance") private var appearance = "dark"
    @AppStorage("kicklab.juggling.personalBest") private var personalBest = 0
    @State private var capture: HomeCapture?
    @State private var sheet: HomeSheet?
    @State private var showImport = false
    @State private var importedVideo: PhotosPickerItem?

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        HomeView(
            personalBest: personalBest,
            onJuggling: { capture = HomeCapture(mode: .juggling) },
            onPowerShot: { capture = HomeCapture(mode: .powerShot) },
            onImport: { showImport = true },
            onProfile: { sheet = .profile },
            onSetupGuide: { sheet = .setup }
        )
        .preferredColorScheme(preferredScheme)
        .tint(Theme.accent)
        .photosPicker(isPresented: $showImport, selection: $importedVideo, matching: .videos)
        .onChange(of: importedVideo) { _, _ in openImportedVideoIfReady() }
        .onChange(of: showImport) { _, _ in openImportedVideoIfReady() }
        .fullScreenCover(item: $capture) { destination in
            switch destination.mode {
            case .juggling:
                RecordView(initialVideo: destination.importedVideo)
            case .powerShot:
                ShotGeometryCaptureView(showsCloseButton: true)
            }
        }
        .sheet(item: $sheet) { destination in
            switch destination {
            case .profile:
                TrainingProfileView(personalBest: personalBest, appearance: $appearance)
                    .preferredColorScheme(preferredScheme)
            case .setup: TrainingCameraGuide()
            }
        }
    }

    private func openImportedVideoIfReady() {
        // The picker must finish dismissing before presenting the analysis screen.
        guard !showImport, let item = importedVideo, capture == nil else { return }
        importedVideo = nil
        capture = HomeCapture(mode: .juggling, importedVideo: item)
    }
}

private struct HomeCapture: Identifiable {
    enum Mode { case juggling, powerShot }
    let id = UUID()
    let mode: Mode
    var importedVideo: PhotosPickerItem?
}

private enum HomeSheet: String, Identifiable {
    case profile, setup
    var id: String { rawValue }
}
