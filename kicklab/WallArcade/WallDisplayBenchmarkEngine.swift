#if WALL_GAMES_PREVIEW
import Foundation

nonisolated struct WallDelayObservation: Codable, Sendable {
    let captureTime: Double
    let receivedTime: Double
    let brightness: Double
    let exposure: Double
    let iso: Double
}

/// Optical round-trip evidence, not an AirPlay acknowledgement. All times are
/// converted to CMClockGetHostTimeClock before entering this state machine.
nonisolated struct WallDisplayBenchmarkEngine: Sendable {
    struct Command: Codable, Sendable { let time: Double; let lit: Bool; let pulse: Int }
    struct Sample: Codable, Sendable {
        let pulse: Int
        let sent: Double
        let lastDark: Double?
        let firstBright: Double?
        let confirmed: Double?
        let exposure: Double?
        let status: String
        var milliseconds: Double? { status == "detected" ? firstBright.map { ($0-sent)*1000 } : nil }
        var bracketMS: Double? {
            guard let lastDark, let firstBright else { return nil }
            return (firstBright-lastDark)*1000
        }
    }
    enum Phase: String, Sendable { case darkCalibration, brightCalibration, settling, waiting, holding, complete, failed }
    private(set) var phase = Phase.darkCalibration
    private(set) var lit = false
    private(set) var message = "Checking dark level…"
    private(set) var commands: [Command] = []
    private(set) var observations: [WallDelayObservation] = []
    private(set) var samples: [Sample] = []
    private(set) var dark: Double?
    private(set) var bright: Double?
    private var darkNoise = 0.0
    private var since: Double
    private var lastCapture = -Double.infinity
    private var lastDark: WallDelayObservation?
    private var candidate: WallDelayObservation?
    private var darkSince: Double?
    let count: Int
    var finished: Bool { phase == .complete || phase == .failed }
    var detected: [Double] { samples.compactMap(\.milliseconds) }
    var valid: Bool { phase == .complete && detected.count >= max(1, Int(ceil(Double(count)*0.8))) }

    init(at now: Double, count: Int = 12) {
        since = now; self.count = count
        commands = [Command(time: now, lit: false, pulse: 0)]
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count-1, max(0, Int(ceil(Double(sorted.count)*fraction))-1))]
    }

    mutating func receive(_ frame: WallDelayObservation, now: Double) {
        guard !finished, frame.captureTime.isFinite, frame.brightness.isFinite,
              frame.captureTime > lastCapture, frame.captureTime <= now+0.01 else { return }
        lastCapture = frame.captureTime
        observations.append(frame)
        if let dark, let bright, frame.captureTime >= since {
            let low = dark+(bright-dark)*0.35, high = dark+(bright-dark)*0.65
            if phase == .settling {
                if frame.brightness <= low {
                    if darkSince == nil { darkSince = frame.captureTime }
                    lastDark = frame
                } else { darkSince = nil; lastDark = nil }
            } else if phase == .waiting {
                if frame.brightness <= low { lastDark = frame; candidate = nil }
                else if frame.brightness >= high {
                    if let first = candidate, frame.captureTime-first.captureTime <= 0.10 {
                        let gap = lastDark.map { first.captureTime-$0.captureTime } ?? .infinity
                        let good = gap <= 0.10 && first.captureTime >= since
                        samples.append(Sample(pulse: samples.count+1, sent: since,
                            lastDark: lastDark?.captureTime, firstBright: first.captureTime,
                            confirmed: frame.captureTime, exposure: first.exposure,
                            status: good ? "detected" : "capture_gap"))
                        phase = .holding; since = now
                        message = "Measured \(samples.count) / \(count)"
                        candidate = nil
                    } else { candidate = frame }
                } else { candidate = nil }
            }
        }
        advance(to: now)
    }

    mutating func advance(to now: Double) {
        guard !finished else { return }
        switch phase {
        case .darkCalibration, .brightCalibration:
            guard now-since >= 3 else { return }
            let levels = observations.filter { $0.captureTime >= now-0.6 && $0.captureTime >= since+2 }.map(\.brightness)
            guard levels.count >= 8, now-lastCapture < 0.2,
                  let level = Self.percentile(levels, 0.5),
                  let low = Self.percentile(levels, 0.1), let high = Self.percentile(levels, 0.9) else {
                fail("No steady camera frames. Keep the app open and try again.", at: now); return
            }
            if phase == .darkCalibration {
                dark = level; darkNoise = high-low
                phase = .brightCalibration; since = now
                emit(true, at: now); message = "Checking bright level…"
            } else {
                bright = level
                let contrast = level-(dark ?? level)
                guard contrast >= 18, max(darkNoise, high-low) <= contrast*0.2 else {
                    fail("Patch not clear enough. Tap inside the projected white patch in the camera view, then retry.", at: now); return
                }
                settle(at: now)
            }
        case .settling:
            // Wait for the projected dark state before issuing another flash.
            // Unequal spacing helps expose accidental matches to periodic lighting.
            let pause = [0.55, 0.71, 0.63, 0.82][samples.count % 4]
            if let darkSince, now-since >= pause, lastCapture-darkSince >= 0.15,
               now-lastCapture < 0.15, let lastDark, lastCapture-lastDark.captureTime < 0.05 {
                phase = .waiting; since = now; candidate = nil
                emit(true, at: now); message = "Flash \(samples.count+1) / \(count)"
            } else if now-since > 3 {
                fail("The wall did not return to dark. Keep the patch clear and retry.", at: now)
            }
        case .waiting:
            if now-since > 2 {
                samples.append(Sample(pulse: samples.count+1, sent: since, lastDark: lastDark?.captureTime,
                    firstBright: nil, confirmed: nil, exposure: nil, status: "timeout"))
                finishOrSettle(at: now)
            }
        case .holding:
            if now-since >= 0.25 { finishOrSettle(at: now) }
        case .complete, .failed: break
        }
    }

    mutating func cancel(at now: Double) { fail("Stopped. Partial evidence saved; run again for a comparison.", at: now) }
    private mutating func finishOrSettle(at now: Double) {
        if samples.count >= count {
            phase = .complete; emit(false, at: now)
            message = valid ? "Benchmark complete" : "Too few reliable flashes. Retry for a comparison."
        } else { settle(at: now) }
    }
    private mutating func settle(at now: Double) {
        phase = .settling; since = now; darkSince = nil; lastDark = nil; candidate = nil
        emit(false, at: now); message = "Waiting for the wall…"
    }
    private mutating func fail(_ reason: String, at now: Double) {
        phase = .failed; message = reason; emit(false, at: now)
    }
    private mutating func emit(_ value: Bool, at now: Double) {
        lit = value
        commands.append(Command(time: now, lit: value, pulse: samples.count+1))
    }
}
#endif
