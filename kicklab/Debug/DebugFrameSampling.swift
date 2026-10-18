#if DEBUG
import Foundation

/// Input sparsity experiments, not a CPU/GPU or iPhone hardware emulator.
/// Only TouchCountingDebug wires this into live capture, after the video writer.
nonisolated enum DebugFrameProfile: String, CaseIterable, Codable, Sendable {
    case normal, fps20, fps15, fps10, fps7, paced, gaps30, gaps15

    var title: String {
        switch self {
        case .normal: "Normal · up to 30 fps"
        case .fps20: "20 fps analysis"
        case .fps15: "15 fps analysis"
        case .fps10: "10 fps analysis"
        case .fps7: "7 fps analysis (iPhone 11 live)"
        case .paced: "Device-paced replay (live speed)"
        case .gaps30: "30 fps + gaps"
        case .gaps15: "15 fps + gaps"
        }
    }

    var framesPerSecond: Double {
        switch self {
        case .normal, .gaps30, .paced: 30
        case .fps20: 20
        case .fps15, .gaps15: 15
        case .fps10: 10
        case .fps7: 7
        }
    }

    var hasGaps: Bool { self == .gaps30 || self == .gaps15 }
}

nonisolated struct DebugFrameSampling: Sendable {
    let profile: DebugFrameProfile
    private var origin: Double?
    private var lastTime: Double?
    private var nextSlot = 0.0
    private(set) var rateSkipped = 0
    private(set) var gapSkipped = 0

    init(profile: DebugFrameProfile) { self.profile = profile }

    var skipped: Int { rateSkipped + gapSkipped }

    /// Uses the source clock: selected frames retain their real timestamps and
    /// identities. A late frame never produces a catch-up burst or a queue wait.
    mutating func allows(_ sourceTime: Double) -> Bool {
        guard sourceTime.isFinite else { return false }
        if let lastTime, sourceTime <= lastTime { return false }
        lastTime = sourceTime
        guard profile != .normal else { return true } // Existing throttle stays byte-for-byte unchanged.
        if origin == nil { origin = sourceTime }
        let elapsed = sourceTime - origin!
        let tolerance = 0.0005
        let cycle = floor((elapsed + tolerance) / 3)
        if profile.hasGaps, cycle >= 1, elapsed - cycle * 3 < 0.2 - tolerance {
            gapSkipped += 1
            return false
        }
        let slot = floor((elapsed + tolerance) * profile.framesPerSecond)
        guard slot >= nextSlot else {
            rateSkipped += 1
            return false
        }
        nextSlot = slot + 1
        return true
    }
}

nonisolated struct DebugFrameTestSnapshot: Codable, Sendable {
    var profile = DebugFrameProfile.normal
    var rateSkipped = 0
    var gapSkipped = 0
    var receivedFPS = 0.0
    var captureDrops = 0
    var writerDrops = 0
    var replaced = 0
    var maxAnalysisGapMS = 0.0
    var skipped: Int { rateSkipped + gapSkipped }
}

/// Capture-queue state; publishing is limited to twice a second so the HUD does
/// not itself create a substantial new capture workload.
nonisolated struct DebugFrameTestRun {
    private var sampling: DebugFrameSampling
    private(set) var snapshot: DebugFrameTestSnapshot
    private var lastPublish: Double?
    private var lastAnalysisTime: Double?
    private var windowTime: Double?
    private var windowFrames = 0

    init(profile: DebugFrameProfile) {
        sampling = .init(profile: profile)
        snapshot = .init(profile: profile)
    }

    mutating func allows(_ time: Double) -> Bool {
        let allowed = sampling.allows(time)
        snapshot.rateSkipped = sampling.rateSkipped
        snapshot.gapSkipped = sampling.gapSkipped
        return allowed
    }

    mutating func submitted(at time: Double) {
        if let lastAnalysisTime {
            snapshot.maxAnalysisGapMS = max(snapshot.maxAnalysisGapMS, (time - lastAnalysisTime) * 1_000)
        }
        lastAnalysisTime = time
    }

    mutating func observe(at time: Double, capture: CaptureCadenceSnapshot,
                          writerDrops: Int, replaced: Int) -> DebugFrameTestSnapshot? {
        snapshot.captureDrops = capture.captureDrops
        snapshot.writerDrops = writerDrops
        snapshot.replaced = replaced
        if let start = windowTime {
            windowFrames += 1
            if time - start >= 1 {
                snapshot.receivedFPS = Double(windowFrames) / (time - start)
                windowTime = time
                windowFrames = 0
            }
        } else { windowTime = time }
        guard lastPublish == nil || time - lastPublish! >= 0.5 else { return nil }
        lastPublish = time
        return snapshot
    }
}

nonisolated struct DebugFrameTestReport: Encodable, Sendable {
    let recordedAt: Date
    let videoFile: String?
    let test: DebugFrameTestSnapshot
    let capture: CaptureCadenceSnapshot
    let touches: Int
    let analysisFailed: Bool

    /// Small sidecar for comparing takes without confusing deliberate skips with
    /// AVFoundation drops. Never changes the saved count or recording metadata.
    func save() {
        let folder = URL.documentsDirectory.appendingPathComponent("FrameRateTests", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch { print("Frame-rate test report could not be saved: \(error)") }
    }
}
#endif
