import AVFoundation

/// The clip's sound for an export to copy or mix. iPhone recordings with spatial audio carry it
/// twice: an enabled 4-channel APAC track and a disabled stereo AAC fallback, of which a player
/// picks one. Copying both left the saved file playing them together, and mixing both added the
/// same sound to itself, so it doubled and clipped. Where a clip has such alternates, the stereo
/// AAC track is kept, since every player and app reads it; tracks that all play together are kept.
nonisolated enum ClipAudio {
    static func tracks(of asset: AVAsset) async throws -> [AVAssetTrack] {
        let all = try await asset.loadTracks(withMediaType: .audio)
        guard all.count > 1 else { return all }
        var enabled = [AVAssetTrack]()
        for track in all {
            if try await track.load(.isEnabled) { enabled.append(track) }
        }
        // No disabled alternates: every track is meant to be heard.
        guard enabled.count < all.count else { return all }
        for track in all {
            if try await isStereoAAC(track) { return [track] }
        }
        return enabled.isEmpty ? [all[0]] : enabled
    }

    private static func isStereoAAC(_ track: AVAssetTrack) async throws -> Bool {
        try await track.load(.formatDescriptions).contains { format in
            guard let audio = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return false }
            return audio.mFormatID == kAudioFormatMPEG4AAC && audio.mChannelsPerFrame <= 2
        }
    }
}
