import AVFoundation

/// Counter, timer, graph and sounds sit over native playback. Only edits to the
/// video pixels need the effects compositor. Try the source before converting it.
nonisolated struct ReplayPlaybackSelection: Equatable {
    let scene: SceneSelection?
    let usesCompositor: Bool

    init(edit: SessionEditState) {
        scene = edit.scene
        usesCompositor = edit.requiresVisualTrack || edit.environment != .original || edit.scene != nil
    }

    @MainActor
    func media(summary: SessionSummary, sceneModel: StadiumPreviewModel,
               compatibility: Bool = false) async throws -> ScenePlayback {
        guard usesCompositor else {
            return ScenePlayback(url: summary.videoURL, track: summary.renderTrack)
        }
        if scene == nil {
            let url = compatibility
                ? try await EffectPreviewCache.shared.compatibilityURL(for: summary.videoURL)
                : try await EffectPreviewCache.shared.previewURL(for: summary.videoURL)
            return ScenePlayback(url: url, track: summary.renderTrack)
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
