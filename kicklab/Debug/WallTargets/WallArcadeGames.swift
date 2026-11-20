#if DEBUG
import CoreGraphics
import Foundation

/// Uses the camera's monotonic host clock. Historical contacts are mapped into
/// the same paused timeline as the animation, not the later callback time.
nonisolated struct WallGameClock: Equatable {
    struct Segment: Equatable {
        var host: Double
        var active: Double
        var end: Double?
    }
    private(set) var segments: [Segment] = []
    var running: Bool { segments.last.map { $0.end == nil } ?? false }
    mutating func start(at host: Double) { segments = [.init(host: host, active: 0)] }
    mutating func pause(at host: Double) {
        guard running, let last = segments.last, host >= last.host else { return }
        segments[segments.count - 1].end = host
    }
    mutating func resume(at host: Double) {
        guard !running, let last = segments.last, let end = last.end, host >= end else { return }
        segments.append(.init(host: host, active: last.active + end - last.host))
    }
    func time(at host: Double) -> Double? {
        guard host.isFinite, let segment = segments.last(where: { $0.host <= host }) else { return nil }
        return segment.active + max(0, min(host, segment.end ?? host) - segment.host)
    }
    var json: [[String: Double]] {
        segments.map { s in
            var result = ["hostStart": s.host, "activeStart": s.active]
            if let end = s.end { result["hostEnd"] = end }
            return result
        }
    }
}

nonisolated enum WallArcadeCue: String, CaseIterable {
    case memoryHit, memoryMiss, meteorHit, shieldLost, victory, defeat
    case tileClaim, goal, keeperSave
}

nonisolated struct WallArcadeEvent: Equatable, Identifiable {
    let id: Int
    let kind: String
    let time: Double
    var contactTime: Double? = nil
    var target: Int? = nil
    var point: CGPoint? = nil
    var cue: WallArcadeCue? = nil
    var player: Int? = nil
    var json: [String: Any] {
        ["id": id, "kind": kind, "activeTime": time,
         "contactActiveTime": contactTime as Any? ?? NSNull(),
         "target": target as Any? ?? NSNull(),
         "player": player as Any? ?? NSNull(),
         "point": point.map { [Double($0.x), Double($0.y)] } as Any? ?? NSNull()]
    }
}

/// Five sequences of two through six steps, using four symbols. Mistakes replay the same sequence;
/// demonstrations never accept shots, and confirmation grace does not extend
/// the player's actual response deadline.
nonisolated struct WallMemoryStrike: Equatable {
    enum Phase: String { case watching, recalling, interlude, finished }
    static let rounds = 5
    static let leadIn = 1.2, flash = 0.75, gap = 0.35, grace = 0.8
    let seed: UInt64
    let pattern: [Int]
    private(set) var phase = Phase.watching
    private(set) var phaseStart = 0.0
    private(set) var round = 1
    private(set) var lives = 3
    private(set) var cursor = 0
    private(set) var score = 0
    private(set) var completedRounds = 0
    private(set) var won = false
    private(set) var events: [WallArcadeEvent] = []
    var sequence: [Int] { Array(pattern.prefix(round + 1)) }
    var watchEnd: Double { phaseStart + Self.leadIn + Double(sequence.count) * (Self.flash + Self.gap) + 0.4 }
    var deadline: Double { phaseStart + Double(sequence.count) * 8 + 6 }

    init(seed: UInt64) {
        self.seed = seed
        var value = seed, result: [Int] = []
        for _ in 0..<6 {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            var next = Int((value >> 32) % UInt64(WallTargetLayout.memoryPads.targets.count)) + 1
            if next == result.last { next = next % WallTargetLayout.memoryPads.targets.count + 1 }
            result.append(next)
        }
        pattern = result
    }
    func highlighted(at time: Double) -> Int? {
        guard phase == .watching, time >= phaseStart + Self.leadIn else { return nil }
        let elapsed = time - phaseStart - Self.leadIn
        let index = Int(elapsed / (Self.flash + Self.gap))
        guard sequence.indices.contains(index),
              elapsed.truncatingRemainder(dividingBy: Self.flash + Self.gap) < Self.flash else { return nil }
        return sequence[index]
    }
    mutating func advance(at time: Double) {
        guard time.isFinite else { return }
        switch phase {
        case .watching:
            if time >= watchEnd {
                let end = watchEnd
                phase = .recalling; phaseStart = end; cursor = 0
                events.append(.init(id: events.count, kind: "recall_started", time: end))
            }
        case .recalling:
            if time > deadline + Self.grace { mistake(at: time, kind: "timeout") }
        case .interlude:
            if time >= phaseStart + 1.6 {
                phase = .watching; phaseStart = time; cursor = 0
                events.append(.init(id: events.count, kind: "sequence_started", time: time))
            }
        case .finished: break
        }
    }
    @discardableResult
    mutating func hit(target: Int, point: CGPoint, contact: Double, now: Double) -> Bool {
        advance(at: now)
        guard phase == .recalling, contact.isFinite, contact >= phaseStart,
              contact <= deadline, contact <= now, sequence.indices.contains(cursor) else { return false }
        guard target == sequence[cursor] else {
            events.append(.init(id: events.count, kind: "wrong_pad", time: now, contactTime: contact,
                                target: target, point: point, cue: .memoryMiss))
            mistake(at: now, kind: "retry")
            return false
        }
        score += 100; cursor += 1
        events.append(.init(id: events.count, kind: "correct_pad", time: now, contactTime: contact,
                            target: target, point: point, cue: .memoryHit))
        if cursor == sequence.count {
            completedRounds += 1; score += round * 100
            if round == Self.rounds {
                phase = .finished; won = true; score += lives * 100
                events.append(.init(id: events.count, kind: "memory_complete", time: now, cue: .victory))
            } else { round += 1; phase = .interlude; phaseStart = now }
        }
        return true
    }
    private mutating func mistake(at time: Double, kind: String) {
        // Repeating a failed prefix must not earn a higher score than recalling
        // it correctly on the first attempt. Completed-round points stay earned.
        score = max(0, score - cursor * 100)
        lives -= 1; cursor = 0; phaseStart = time
        phase = lives == 0 ? .finished : .interlude
        events.append(.init(id: events.count, kind: lives == 0 ? "memory_failed" : kind, time: time,
                            cue: lives == 0 ? .defeat : kind == "timeout" ? .memoryMiss : nil))
    }
}

nonisolated struct WallMeteorDefence: Equatable {
    enum Phase: String { case defending, interlude, finished }
    struct Meteor: Equatable, Identifiable {
        let id: Int
        let lane: Double
        let drift: Double
        let spawn: Double
        let duration: Double
        static let radius = 0.20
        var arrival: Double { spawn + duration }
        func position(at time: Double) -> CGPoint {
            let p = min(1, max(0, (time - spawn) / duration))
            return CGPoint(x: lane + drift * p, y: 0.22 + 1.27 * p)
        }
        /// Circle/ellipse overlap in board coordinates. Sampling the outline in
        /// footprint space preserves perspective, without a rectangular hitbox.
        func overlaps(_ point: CGPoint, footprint: WallContactFootprint, at time: Double) -> Bool {
            guard footprint.isValid else { return false }
            let c = position(at: time), r = Self.radius
            if hypot(point.x - c.x, point.y - c.y) <= r { return true }
            for i in 0..<32 {
                let angle = Double(i) * .pi / 16
                let x = c.x + cos(angle) * r - point.x, y = c.y + sin(angle) * r - point.y
                let u = (x * footprint.yAxis.y - y * footprint.yAxis.x) / footprint.determinant
                let v = (y * footprint.xAxis.x - x * footprint.xAxis.y) / footprint.determinant
                if u * u + v * v <= 1 { return true }
            }
            return false
        }
    }
    static let waves = 3, perWave = 4
    static let confirmationGrace = 0.8
    let seed: UInt64
    private(set) var phase = Phase.defending
    private(set) var wave = 1
    private(set) var shields = 3
    private(set) var score = 0
    private(set) var destroyed = 0
    private(set) var won = false
    private(set) var meteors: [Meteor] = []
    private(set) var resolved: Set<Int> = []
    private(set) var phaseStart = 0.0
    private(set) var events: [WallArcadeEvent] = []

    init(seed: UInt64) { self.seed = seed; spawnWave(at: 0) }
    func visible(at time: Double) -> [Meteor] {
        meteors.filter { !resolved.contains($0.id) && time >= $0.spawn }
    }
    mutating func advance(at time: Double) {
        guard time.isFinite, phase != .finished else { return }
        if phase == .interlude {
            if time >= phaseStart + 2.5 { wave += 1; spawnWave(at: time) }
            return
        }
        for meteor in meteors where !resolved.contains(meteor.id) && time > meteor.arrival + Self.confirmationGrace {
            resolved.insert(meteor.id); shields -= 1
            events.append(.init(id: events.count, kind: "city_hit", time: time, target: meteor.id,
                                point: meteor.position(at: meteor.arrival), cue: .shieldLost))
            if shields == 0 {
                phase = .finished
                events.append(.init(id: events.count, kind: "city_lost", time: time, cue: .defeat))
                return
            }
        }
        finishWaveIfNeeded(at: time)
    }
    @discardableResult
    mutating func hit(point: CGPoint, footprint: WallContactFootprint, contact: Double, now: Double) -> Int? {
        advance(at: now)
        guard phase == .defending, contact.isFinite, contact <= now,
              WallTargetLayout.meteorField.contains(point), footprint.isValid else { return nil }
        let candidates = meteors.filter {
            !resolved.contains($0.id) && contact >= $0.spawn && contact <= $0.arrival
                && $0.overlaps(point, footprint: footprint, at: contact)
        }
        guard let meteor = candidates.min(by: {
            let a = $0.position(at: contact), b = $1.position(at: contact)
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }) else { return nil }
        resolved.insert(meteor.id); destroyed += 1; score += 150 * wave
        events.append(.init(id: events.count, kind: "meteor_destroyed", time: now, contactTime: contact,
                            target: meteor.id, point: meteor.position(at: contact), cue: .meteorHit))
        finishWaveIfNeeded(at: now)
        return meteor.id
    }
    private mutating func finishWaveIfNeeded(at time: Double) {
        guard meteors.allSatisfy({ resolved.contains($0.id) }) else { return }
        if wave == Self.waves {
            won = true; phase = .finished; score += shields * 250
            events.append(.init(id: events.count, kind: "city_saved", time: time, cue: .victory))
        } else {
            phase = .interlude; phaseStart = time
            events.append(.init(id: events.count, kind: "wave_complete", time: time))
        }
    }
    private mutating func spawnWave(at time: Double) {
        phase = .defending; phaseStart = time
        let lanes = [0.53, 1.18, 1.82, 2.47]
        let offset = Int((seed &+ UInt64(wave * 3)) % 4)
        meteors = (0..<Self.perWave).map { i in
            let lane = (i * 3 + offset) % 4
            return Meteor(id: (wave - 1) * Self.perWave + i + 1, lane: lanes[lane],
                          drift: lane < 2 ? 0.10 : -0.10, spawn: time + 1.2 + Double(i) * 5.5,
                          duration: 12 - Double(wave - 1))
        }
        events.append(.init(id: events.count, kind: "wave_started", time: time))
    }
}
#endif
