import AVFoundation
import Foundation

/// Reads selected windows of the original composition without changing its clock,
/// transform or color conversion. The codec still decodes preceding keyframes.
nonisolated final class PreparationFrameReader {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let composition: AVVideoComposition
    private var ranges: [CMTimeRange?]
    private var nextRange = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderVideoCompositionOutput?
    private(set) var decodedFrames = 0
    private(set) var readSeconds = 0.0
    private(set) var openedReaders = 0

    init(asset: AVAsset, track: AVAssetTrack, composition: AVVideoComposition,
         duration: CMTime, times: [Double], selective: Bool) {
        self.asset = asset; self.track = track; self.composition = composition
        let planned = selective ? Self.ranges(times: times, frameDuration: composition.frameDuration, duration: duration) : nil
        ranges = planned?.map(Optional.some) ?? [nil]
    }

    /// Padding preserves request rounding tolerance; sourceTrackIDForFrameTiming
    /// in the composition preserves the actual timestamps of variable-rate media.
    /// Nearby requests share one reader. Dense requests use sequential decoding.
    static func ranges(times: [Double], frameDuration: CMTime, duration: CMTime) -> [CMTimeRange]? {
        let step = frameDuration.seconds, length = duration.seconds
        guard step.isFinite, step > 0, length.isFinite, length > 0,
              length / step < Double(Int32.max - 4), !times.isEmpty,
              times.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= length }) else { return nil }
        let total = Int(ceil(length / step)), join = Int(ceil(0.25 / step))
        var windows: [(Int, Int)] = []
        for time in times.sorted() {
            let first = max(0, Int(floor(time / step)) - 2)
            let last = min(total, Int(ceil(time / step)) + 3)
            guard first < last else { continue }
            if let previous = windows.last, first <= previous.1 + join {
                windows[windows.count - 1].1 = max(last, previous.1)
            } else { windows.append((first, last)) }
        }
        guard !windows.isEmpty, windows.reduce(0, { $0 + $1.1 - $1.0 }) < total / 2 else { return nil }
        return windows.map { first, last in
            let start = CMTimeMultiply(frameDuration, multiplier: Int32(first))
            let end = CMTimeMinimum(duration, CMTimeMultiply(frameDuration, multiplier: Int32(last)))
            return CMTimeRange(start: start, end: end)
        }
    }

    func nextSample() throws -> CMSampleBuffer? {
        let started = ProcessInfo.processInfo.systemUptime
        defer { readSeconds += ProcessInfo.processInfo.systemUptime - started }
        while true {
            if reader == nil {
                guard nextRange < ranges.count else { return nil }
                let next = try AVAssetReader(asset: asset)
                if let range = ranges[nextRange] { next.timeRange = range }
                nextRange += 1
                let out = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings:
                    [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                out.videoComposition = composition; out.alwaysCopiesSampleData = false
                next.add(out)
                guard next.startReading() else { throw next.error ?? NSError(domain: "PreparationFrameReader", code: 1) }
                reader = next; output = out; openedReaders += 1
            }
            if let sample = output?.copyNextSampleBuffer() { decodedFrames += 1; return sample }
            if reader?.status == .failed { throw reader!.error ?? NSError(domain: "PreparationFrameReader", code: 2) }
            cancelCurrent()
        }
    }

    private func cancelCurrent() {
        if reader?.status == .reading { reader?.cancelReading() }
        output = nil; reader = nil
    }
    func cancel() { cancelCurrent(); nextRange = ranges.count }
    deinit { cancelCurrent() }
}
