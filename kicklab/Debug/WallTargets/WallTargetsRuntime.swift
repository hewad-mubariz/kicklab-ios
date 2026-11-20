#if DEBUG
import Foundation

/// Whole-process footprint and iOS thermal pressure, sampled once per second.
/// Peak is the largest sample while this wall-camera object is open, not an
/// instantaneous allocation peak or the detector's memory alone.
nonisolated struct WallRuntimeSample: Codable, Equatable, Sendable {
    var uptime = 0.0
    var memoryMiB: Double?
    var peakMemoryMiB: Double?
    var thermalState = -1
    var analysisFPS = 0.0
    var captureFPS = 0.0
    var inferenceMS = 0.0
    var cameraResting = true
    /// Optional so recordings from before the power investigation still decode.
    var wallTime: Double?
    var power: WallPowerReading?
    /// Queue-owned interval totals; absent in recordings made before this report.
    var work: WallWorkSample?

    var thermalLabel: String {
        switch thermalState {
        case 0: "Normal"
        case 1: "Fair"
        case 2: "Serious"
        case 3: "Critical"
        default: "Checking"
        }
    }
    var canStartRound: Bool { (0...1).contains(thermalState) }
    var shouldEndRound: Bool { thermalState >= 3 }
    var allowsMacPreview: Bool { (0...1).contains(thermalState) }
    var startNotice: String? {
        if thermalState < 0 { return "Checking phone temperature…" }
        return canStartRound ? nil : "Phone hot · let it cool before the next round"
    }
}

nonisolated enum WallRuntimePolicy {
    static let referenceFPS = 15.0
    /// Alignment and recording continue independently. Never run ball/person
    /// inference merely to wait for setup, a countdown or a result screen.
    static func needsInference(scoring: Bool, collectingReference: Bool, referenceFinished: Bool) -> Bool {
        scoring || (collectingReference && !referenceFinished)
    }
}

/// Admit the first reference frame immediately, then at most about 15 per
/// second. The 1 ms allowance absorbs sensor timestamp jitter, not late bursts.
/// Gameplay never uses this cap, including when corner markers are obscured.
nonisolated struct WallInferenceCadence {
    private var lastReferenceTime: Double?

    mutating func reset() { lastReferenceTime = nil }

    mutating func admit(at time: Double, scoring: Bool, collectingReference: Bool, referenceFinished: Bool,
                        gameplayInputEnabled: Bool = true) -> Bool {
        guard time.isFinite else { return false }
        if scoring && gameplayInputEnabled { reset(); return true }
        guard collectingReference && !referenceFinished else { reset(); return false }
        if let lastReferenceTime, time >= lastReferenceTime,
           time - lastReferenceTime < 1 / WallRuntimePolicy.referenceFPS - 0.001 { return false }
        lastReferenceTime = time
        return true
    }
}

/// Wall play still inspects motion on every delivered camera frame. Only
/// expensive ball-model calls rest between shots. A periodic search covers a
/// stationary ball or motion too faint to produce a compact search hint.
nonisolated struct WallGameplayInferenceCadence {
    static let policy = "cpu-motion-wake-idle-4fps-v1"
    static let acceleratedPolicy = "spatial-motion-wake-idle-4fps-v2"
    private var activeUntil = -Double.infinity
    private var lastModelTime = -Double.infinity
    private var lastTime = -Double.infinity

    mutating func reset() {
        activeUntil = -.infinity; lastModelTime = -.infinity; lastTime = -.infinity
    }

    mutating func admit(at time: Double, motion: Bool, tracked: Bool, modelFrame: Bool) -> Bool {
        guard time.isFinite else { return false }
        if time < lastTime { reset() }
        lastTime = time
        if motion || tracked { activeUntil = max(activeUntil, time + 0.20) }
        guard modelFrame, time > lastModelTime else { return false }
        guard time <= activeUntil || time - lastModelTime >= 0.25 - 0.001 else { return false }
        lastModelTime = time
        return true
    }

    mutating func observedBall(at time: Double) {
        guard time.isFinite else { return }
        // Preserve the approach, reversal and contact decision even across a
        // missing RF observation. A model measurement is still required.
        activeUntil = max(activeUntil, time + 0.65)
    }
}

/// Keep every analysed frame and every provisional/confirmed ball observation.
/// Quiet, intentionally unanalysed video is only context, so sample it at 10 Hz.
/// This never changes capture, inference, tracking or the contact clock.
nonisolated struct WallRecordingCadence {
    static let policy = "all-analysis-and-ball-frames-idle-video-10fps-v1"
    private var lastRecorded: Double?
    func shouldRecord(at time: Double, inferenceRan: Bool?, hasBall: Bool, source: Int) -> Bool {
        guard time.isFinite else { return false }
        if inferenceRan != false || hasBall || source == 5 { return true }
        guard let lastRecorded, time >= lastRecorded else { return true }
        return time - lastRecorded >= 0.1 - 0.001
    }
    mutating func recorded(at time: Double) { lastRecorded = time }
}

/// Synchronous elapsed wall time, not CPU utilization, GPU busy time or energy.
/// The whole-frame stage includes the other stages; do not sum it with them.
nonisolated struct WallWorkSample: Codable, Equatable, Sendable {
    struct Stage: Codable, Equatable, Sendable {
        var calls = 0
        var totalMS = 0.0
        var maximumMS = 0.0
    }
    var windowSeconds: Double
    var stages: [String: Stage]
    var referenceFramesSkipped: Int
    var idleModelFramesSkipped: Int?
    var sceneMotionWakeFrames: Int?
    var gamePhaseFramesSkipped: Int?
}

nonisolated struct WallWorkMeter {
    enum Stage: String { case frame, pixelTracking, motionSearch, boardModel, fullFrameModel, bodyPose, recording, macPreview }
    private var windowStart: Double
    private var stages: [String: WallWorkSample.Stage] = [:]
    private var referenceFramesSkipped = 0
    private var idleModelFramesSkipped = 0
    private var sceneMotionWakeFrames = 0
    private var gamePhaseFramesSkipped = 0

    init(at time: Double) { windowStart = time }

    mutating func note(_ stage: Stage, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        var value = stages[stage.rawValue, default: .init()]
        value.calls += 1
        value.totalMS += milliseconds
        value.maximumMS = max(value.maximumMS, milliseconds)
        stages[stage.rawValue] = value
    }

    mutating func skippedReferenceFrame() { referenceFramesSkipped += 1 }
    mutating func observedSceneMotion(_ moving: Bool) { if moving { sceneMotionWakeFrames += 1 } }
    mutating func skippedIdleModelFrame() { idleModelFramesSkipped += 1 }
    mutating func skippedGamePhaseFrame() { gamePhaseFramesSkipped += 1 }

    mutating func take(at time: Double) -> WallWorkSample {
        let sample = WallWorkSample(windowSeconds: max(0, time - windowStart),
            stages: stages, referenceFramesSkipped: referenceFramesSkipped,
            idleModelFramesSkipped: idleModelFramesSkipped, sceneMotionWakeFrames: sceneMotionWakeFrames, gamePhaseFramesSkipped: gamePhaseFramesSkipped)
        windowStart = time
        stages.removeAll(keepingCapacity: true)
        referenceFramesSkipped = 0
        idleModelFramesSkipped = 0
        sceneMotionWakeFrames = 0
        gamePhaseFramesSkipped = 0
        return sample
    }
}

#if BALL_DETECTION_DEBUG
import SwiftUI

struct WallTargetsRuntimeHUD: View {
    let sample: WallRuntimeSample
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let power = sample.power {
                Text(power.label)
                    .foregroundStyle((power.batteryPercent ?? 100) <= 15 ? .orange : .white)
            }
            Text("RAM \(memory(sample.memoryMiB)) · Peak \(memory(sample.peakMemoryMiB)) MiB")
            Text("Thermal: \(sample.thermalLabel)")
                .foregroundStyle(sample.thermalState >= 2 ? .orange : .white)
            Text(sample.cameraResting ? "Camera resting" : String(format: "Camera %.0f · Analysis %.0f fps", sample.captureFPS, sample.analysisFPS))
            if sample.thermalState >= 2 {
                Text(sample.cameraResting ? "Cooling · wait for Fair or Normal"
                     : sample.shouldEndRound ? "Critical heat · ending this round" : "Phone hot · save & cool; Mac preview paused")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(.white)
        .background(.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wall.runtimeReport")
    }
    private func memory(_ value: Double?) -> String {
        value.map { String(format: "%.0f", $0) } ?? "—"
    }
}
#endif
#endif
