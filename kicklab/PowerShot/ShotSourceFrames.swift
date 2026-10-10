import AVFoundation

/// Index compressed samples without decoding pixels or running inference. Frame stepping uses
/// presentation timestamps, so variable-rate and reordered footage is handled correctly.
nonisolated struct ShotSourceFrames: Equatable, Sendable {
    var times: [Double]
    var duration: Double
    var isEmpty: Bool { times.isEmpty }
    var last: Double { times.last ?? max(0, duration - 0.001) }

    init(times: [Double] = [], duration: Double = 1) {
        self.duration = max(0.001, duration)
        self.times = Array(Set(times.filter { $0.isFinite && $0 >= 0 && $0 < duration })).sorted()
    }
    func index(at time: Double) -> Int {
        guard !times.isEmpty else { return 0 }
        var low = 0, high = times.count
        while low < high {
            let mid = (low + high) / 2
            if times[mid] < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == times.count { return times.count - 1 }
        return time - times[low - 1] < times[low] - time ? low - 1 : low
    }
    func nearest(_ time: Double) -> Double {
        times.isEmpty ? min(last, max(0, time)) : times[index(at: time)]
    }
    func adjacent(to time: Double, by offset: Int) -> Double {
        guard !times.isEmpty else { return nearest(time) }
        return times[min(times.count - 1, max(0, index(at: time) + offset))]
    }
    func frameDuration(at time: Double) -> Double {
        guard !times.isEmpty else { return 1.0 / 30 }
        let i = index(at: time)
        return max(0.00001, (i + 1 < times.count ? times[i + 1] : duration) - times[i])
    }
    static func load(_ url: URL) async throws -> Self {
        let asset = AVURLAsset(url: url)
        defer { withExtendedLifetime(asset) {} }
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShotEffectExporter.Failure.noVideo
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ShotEffectExporter.Failure.writer("Couldn’t read source frames.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Usually one compressed video sample; handle multi-sample buffers too.
            var count = 0
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            var info = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
            if count > 0 {
                CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &info, entriesNeededOut: &count)
                times.append(contentsOf: info.map { $0.presentationTimeStamp.seconds })
            }
        }
        if reader.status == .failed { throw reader.error ?? ShotEffectExporter.Failure.writer("Couldn’t read source frames.") }
        return Self(times: times, duration: duration)
    }
    static func label(_ time: Double) -> String {
        let millis = Int((max(0, time) * 1000).rounded())
        return String(format: "%02d:%02d.%03d", millis / 60_000, (millis / 1000) % 60, millis % 1000)
    }
}
