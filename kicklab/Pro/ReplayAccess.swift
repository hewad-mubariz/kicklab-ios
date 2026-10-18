import Foundation

/// Both playback and export resolve the clip through the same access policy.
/// Locked choices stay off the video until Pro access has been verified.
nonisolated struct JugglingReplayLook: Equatable {
    var edit: SessionEditState
    var overlays: ExportOverlaySettings
    var showGraph: Bool

    var requiresPro: Bool {
        edit.isEdited || (overlays.counter.enabled && overlays.counter.style.requiresPro)
            || overlays.graph.enabled || showGraph
    }

    func allowed(isPro: Bool) -> Self {
        guard !isPro else { return self }
        var free = self
        free.edit = SessionEditState(style: .none, intensity: edit.intensity)
        free.overlays.counter.style = .normal
        free.overlays.graph.enabled = false
        free.showGraph = false
        return free
    }
}

nonisolated struct ShotReplayLook: Equatable {
    var style: ShotTrailStyle = .glowTrail
    var intensity: Double = 1
    var graphStyle: ShotGraphStyle = .comet
    var showGraph = true
    var camera = ShotCameraTrack()

    var requiresPro: Bool {
        Self.trailRequiresPro(style) || showGraph || !camera.isEmpty
    }

    static func trailRequiresPro(_ style: ShotTrailStyle) -> Bool {
        style != .none && style != .glowTrail
    }

    func allowed(isPro: Bool) -> Self {
        guard !isPro else { return self }
        var free = self
        if Self.trailRequiresPro(style) { free.style = .glowTrail }
        free.showGraph = false
        free.camera = .init()
        return free
    }
}
