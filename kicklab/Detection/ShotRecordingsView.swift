import AVKit
import SwiftUI

struct ShotRecordingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = ShotRecordingStore.Library()
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Each shot is saved automatically on this iPhone with its measurement data. You can replay it offline and export it when you return.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if loading {
                    ProgressView("Loading saved shots")
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else if library.recordings.isEmpty {
                    ContentUnavailableView("No saved shots yet", systemImage: "play.rectangle",
                        description: Text("Record a Power Shot and wait for “Saved” before leaving the recorder."))
                }
                ForEach(library.recordings) { recording in
                    NavigationLink {
                        ShotRecordingReplayView(recording: recording)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill").font(.largeTitle)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.headline)
                                Text("Video + measurement data · \(ByteCountFormatter.string(fromByteCount: recording.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let estimate = recording.lastRollEstimateM {
                                    Text(String(format: "Last roll estimate: %.2f m · experimental", estimate))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                if let peak = recording.peakRollingSpeedKMH {
                                    Text(String(format: "Peak rolling speed: %.1f km/h · experimental", peak))
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }.padding(.vertical, 5)
                    }.accessibilityIdentifier("saved-shot-\(recording.id)")
                }
                if library.incompleteCount > 0 {
                    Section {
                        Text("\(library.incompleteCount) recording(s) did not finish saving. Their files are still on this iPhone, but they are not ready for replay and analysis.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Saved shots")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("saved-shots-done")
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
        }.tint(.primary)
    }

    private func reload() async {
        do {
            library = try await Task.detached(priority: .userInitiated) {
                try ShotRecordingStore.load()
            }.value
            error = nil
        } catch { self.error = "Could not load saved shots: \(error.localizedDescription)" }
        loading = false
    }
}

private struct ShotRecordingReplayView: View {
    let recording: ShotRecording
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var preparing = false
    @State private var export: ShotExport?
    @State private var error: String?
    @State private var duration: Double?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let player {
                    VideoPlayer(player: player).frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                } else if error == nil { ProgressView("Opening replay").frame(height: 320) }
                ShotEffectsButton(recording: recording) { player?.pause() }
                VStack(alignment: .leading, spacing: 8) {
                    Label("Saved on this iPhone", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    Text(recording.date.formatted(date: .complete, time: .shortened))
                    if let duration { Text(String(format: "%.1f seconds", duration)) }
                    Text("Your video and measurement data are kept together. No internet connection is needed.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let estimate = recording.lastRollEstimateM {
                        Text(String(format: "Last distance estimate: %.2f m", estimate)).font(.title3.bold())
                        Text("Experimental distance from the last starting point. Floor scale and rolling contact are unverified. The live observations are included in Export video + data.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let peak = recording.peakRollingSpeedKMH {
                        Text(String(format: "Peak rolling speed: %.1f km/h", peak)).font(.title3.bold())
                        Text("Experimental estimate smoothed over 0.6 seconds. Rolling ball only; speed accuracy is unverified.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if recording.limitedFrames > 0 {
                        Text("Camera tracking was limited during part of this shot. The recording has been kept for review.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    player?.pause()
                    Task { await prepareExport() }
                } label: {
                    if preparing { ProgressView("Preparing export…") }
                    else { Label("Export video + data", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.borderedProminent).disabled(preparing)
                .accessibilityIdentifier("export-shot-bundle")
                Text("Export includes both files needed for measurement and the original video. Choose Save to Files or AirDrop when you need a copy.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding()
        }
        .navigationTitle("Replay").navigationBarTitleDisplayMode(.inline)
        .task { await loadReplay() }
        .onDisappear { player?.pause() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
        .sheet(item: $export) { item in ShotExportSheet(url: item.url) }
    }

    private func loadReplay() async {
        guard player == nil else { return }
        do {
            let rotation = try await Task.detached {
                try ShotRecordingStore.previewRotation(recording)
            }.value
            let asset = AVURLAsset(url: recording.video)
            let length = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ShotRecordingStore.StoreError.incomplete
            }
            let size = try await track.load(.naturalSize)
            let composition = AVMutableComposition()
            guard let replayTrack = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ShotRecordingStore.StoreError.incomplete
            }
            try replayTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length),
                                           of: track, at: .zero)
            var transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            transform.tx = -bounds.minX; transform.ty = -bounds.minY
            replayTrack.preferredTransform = transform
            guard !Task.isCancelled else { return }
            duration = length.seconds
            player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        } catch { self.error = "Replay could not open: \(error.localizedDescription)" }
    }

    private func prepareExport() async {
        preparing = true; error = nil
        defer { preparing = false }
        do {
            let recording = recording
            let url = try await Task.detached(priority: .userInitiated) {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("PowerShotExports", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                return try ShotRecordingStore.export(recording, to: destination)
            }.value
            export = ShotExport(url: url)
        } catch { self.error = "Export failed: \(error.localizedDescription)" }
    }
}

private struct ShotExport: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ShotExportSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
