import AVFoundation
import Observation

@MainActor @Observable
final class SavedShotPhasePlayer {
    private(set) var player: AVPlayer?
    private(set) var frameTimes: [Double] = []
    private(set) var duration = 0.0
    private(set) var index = 0
    private(set) var playing = false
    private(set) var seeking = false
    var slow = true
    var time: Double { frameTimes.indices.contains(index) ? frameTimes[index] : 0 }
    var canMark: Bool { player != nil && !playing && !seeking && !frameTimes.isEmpty }
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var playbackEnd = Double.infinity

    func open(recording: ShotRecording) async throws {
        let asset = try await BallDistanceMedia.playbackComposition(of: recording)
        let frames = try await Self.frameTimes(url: recording.video)
        let length = try await asset.load(.duration).seconds
        try Task.checkCancellation()
        guard !frames.isEmpty, length.isFinite, length > 0 else { throw ShotRecordingStore.StoreError.incomplete }
        frameTimes = frames; duration = length; index = 0
        let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = next
        observer = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.seeking, let stamp = self.player?.currentTime().seconds, stamp.isFinite else { return }
                self.index = Self.frameIndex(at: stamp, times: self.frameTimes)
                self.finishIfAtEnd()
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: next.currentItem, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishIfAtEnd() }
            }
        seek(index: 0)
    }

    func seek(index requested: Int, resume: Bool = false, end: Double? = nil) {
        guard let player, !frameTimes.isEmpty else { return }
        player.pause(); playing = false; seeking = true
        let token = UUID(); generation = token
        let target = min(max(requested, 0), frameTimes.count - 1)
        let time = frameTimes[target]
        // Keep the scrubber responsive; marking remains disabled until this
        // exact seek completes. No gesture-end callback is needed to unlock it.
        index = target
        playbackEnd = end ?? duration
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: playbackEnd, preferredTimescale: 600_000)
        Task { @MainActor [weak self, weak player] in
            guard let player else { return }
            let complete = await player.seek(to: CMTime(seconds: time, preferredTimescale: 600_000),
                toleranceBefore: .zero, toleranceAfter: .zero)
            guard let self, self.generation == token, self.player === player else { return }
            self.seeking = false
            if complete {
                self.index = target
                if resume { self.playing = true; player.playImmediately(atRate: self.slow ? 0.25 : 1) }
            } else {
                self.index = Self.frameIndex(at: player.currentTime().seconds, times: self.frameTimes)
            }
        }
    }

    func seek(time: Double) { seek(index: Self.frameIndex(at: time, times: frameTimes)) }
    func step(_ delta: Int) { seek(index: index + delta) }
    func pause() {
        player?.pause(); playing = false
        if !seeking, let stamp = player?.currentTime().seconds, stamp.isFinite { seek(time: stamp) }
    }
    func togglePlay() {
        if playing { pause() }
        else { seek(index: index >= frameTimes.count - 1 ? 0 : index, resume: true) }
    }
    func play(from start: Double, through end: Double) {
        seek(index: Self.frameIndex(at: start, times: frameTimes), resume: true, end: end)
    }
    func close() {
        generation = UUID(); player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observer = nil; player = nil; playing = false; seeking = false
    }

    private func finishIfAtEnd() {
        guard playing, !seeking, let current = player?.currentTime().seconds,
              current >= min(playbackEnd, duration) - 0.001 else { return }
        // A playback range ends before rendering its boundary sample. Seek to
        // the marked landing frame so the paused image shows that contact.
        seek(time: min(playbackEnd, frameTimes.last ?? 0))
    }

    nonisolated static func frameIndex(at time: Double, times: [Double]) -> Int {
        guard time.isFinite, !times.isEmpty else { return 0 }
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time + 0.000_001 { low = mid + 1 } else { high = mid }
        }
        return max(0, low - 1)
    }

    /// Read compressed sample timestamps, without decoding images or loading AI.
    nonisolated static func frameTimes(url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShotRecordingStore.StoreError.incomplete
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ShotRecordingStore.StoreError.incomplete }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ShotRecordingStore.StoreError.incomplete }
        defer { reader.cancelReading() }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let time = sample.presentationTimeStamp.seconds
            if time.isFinite, time >= 0 { times.append(time) }
        }
        guard reader.status == .completed else { throw reader.error ?? ShotRecordingStore.StoreError.incomplete }
        // Compressed streams can arrive in decode order, with B frames out of presentation order.
        return Array(Set(times)).sorted()
    }
}
