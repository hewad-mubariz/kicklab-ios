import AVFoundation
import SwiftUI

extension ShotRecordingStore {
    /// Shots from the AR recorder are stored sensor-side up, with the phone's turn kept in
    /// the frame log. One upright copy (no re-encode) lets tracking, replay and export all
    /// see the shot the way it was filmed.
    static func uprightVideo(for recording: ShotRecording) async throws -> URL {
        let target = recording.directory.appendingPathComponent("upright.mov")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let rotation = try previewRotation(recording)
        let asset = AVURLAsset(url: recording.video)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw StoreError.incomplete }
        let size = try await source.load(.naturalSize)
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StoreError.incomplete
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        var transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
        let bounds = CGRect(origin: .zero, size: size).applying(transform)
        transform.tx = -bounds.minX; transform.ty = -bounds.minY
        track.preferredTransform = transform
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw StoreError.incomplete
        }
        let temporary = recording.directory.appendingPathComponent("upright-\(UUID().uuidString).mov")
        try await session.export(to: temporary, as: .mov)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        return target
    }
}

/// "Add effects" on a saved shot: prepares the upright copy, then opens the effects replay.
struct ShotEffectsButton: View {
    let recording: ShotRecording
    var onOpen: () -> Void = {}
    @State private var preparing = false
    @State private var video: PreparedShot?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 8) {
            Button {
                onOpen()
                Task { await open() }
            } label: {
                HStack(spacing: 10) {
                    if preparing { ProgressView().tint(TrainingHomeStyle.buttonInk) } else { Image(systemName: "sparkles") }
                    Text("Add effects")
                }
                .font(.headline)
                .foregroundStyle(TrainingHomeStyle.buttonInk)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(TrainingHomeStyle.lime, in: .capsule)
            }
            .buttonStyle(SessionPressStyle(scale: 0.97))
            .disabled(preparing)
            .accessibilityIdentifier("shot-add-effects")
            if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
        }
        .fullScreenCover(item: $video) { shot in
            ShotEffectsReplayView(video: shot.url, trackCache: recording.directory.appendingPathComponent("ball-track.plist")) {
                video = nil
            }
        }
    }

    private func open() async {
        preparing = true; problem = nil
        defer { preparing = false }
        do { video = PreparedShot(url: try await ShotRecordingStore.uprightVideo(for: recording)) }
        catch { problem = "This shot couldn’t be prepared. \(error.localizedDescription)" }
    }
}

private struct PreparedShot: Identifiable {
    let url: URL
    var id: URL { url }
}
