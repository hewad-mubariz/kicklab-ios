import AVFoundation

/// Counter, timer, graph and sounds sit over native playback. Only edits to the
/// video pixels need the SDR proxy and the effects compositor.
nonisolated struct ReplayPlaybackSelection: Equatable {
    let scene: SceneSelection?
    let usesCompositor: Bool

    init(edit: SessionEditState) {
        scene = edit.scene
        usesCompositor = edit.requiresVisualTrack || edit.environment != .original || edit.scene != nil
    }

    @MainActor
    func media(summary: SessionSummary, sceneModel: StadiumPreviewModel) async throws -> ScenePlayback {
        guard usesCompositor else {
            return ScenePlayback(url: summary.videoURL, track: summary.renderTrack)
        }
        return try await sceneModel.media(summary: summary, selection: scene)
    }

    @MainActor
    func playerItem(asset: AVAsset) async throws -> AVPlayerItem {
        let item = AVPlayerItem(asset: asset)
        if usesCompositor, let track = try await asset.loadTracks(withMediaType: .video).first {
            item.videoComposition = try await EffectVideoGeometry.composition(track: track,
                duration: asset.load(.duration), shortEdge: 1080)
        }
        return item
    }
}
