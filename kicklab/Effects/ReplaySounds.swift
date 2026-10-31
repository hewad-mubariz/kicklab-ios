//
//  ReplaySounds.swift
//  kicklab
//
//  Short synthesized cues on touches and ball changes. Every sound is computed from
//  the same formulas in the editor and the export, so the saved video plays what
//  the replay played. No bundled audio files; nothing here listens to the microphone.
//

import AVFoundation
import Foundation

/// A cue on every counted touch.
nonisolated enum TouchSound: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case none, thud, pop, click, kick, snare, laser, bubble, coin, bell, whistle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .thud: "Thud"
        case .pop: "Pop"
        case .click: "Click"
        case .kick: "Kick"
        case .snare: "Snare"
        case .laser: "Laser"
        case .bubble: "Bubble"
        case .coin: "Coin"
        case .bell: "Bell"
        case .whistle: "Whistle"
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash.fill"
        case .thud: "circle.fill"
        case .pop: "smallcircle.filled.circle"
        case .click: "cursorarrow.click"
        case .kick: "soccerball"
        case .snare: "music.quarternote.3"
        case .laser: "bolt.horizontal.fill"
        case .bubble: "drop.fill"
        case .coin: "dollarsign.circle"
        case .bell: "bell.fill"
        case .whistle: "music.note"
        }
    }
}

/// A cue at the moment the ball changes.
nonisolated enum BallSwapSound: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case none, whoosh, chime, zap, shimmer, drop, glitch, thunder, sparkle, flip, warp
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .whoosh: "Whoosh"
        case .chime: "Chime"
        case .zap: "Zap"
        case .shimmer: "Shimmer"
        case .drop: "Drop"
        case .glitch: "Glitch"
        case .thunder: "Thunder"
        case .sparkle: "Sparkle"
        case .flip: "Flip"
        case .warp: "Warp"
        }
    }

    var symbol: String {
        switch self {
        case .none: "speaker.slash.fill"
        case .whoosh: "wind"
        case .chime: "bell"
        case .zap: "bolt.fill"
        case .shimmer: "sparkles"
        case .drop: "arrow.down.to.line"
        case .glitch: "waveform.path"
        case .thunder: "cloud.bolt.fill"
        case .sparkle: "star.fill"
        case .flip: "arrow.triangle.2.circlepath"
        case .warp: "tornado"
        }
    }
}

nonisolated enum ReplaySound: Hashable, Sendable {
    case touch(TouchSound)
    case swap(BallSwapSound)
    /// The fanfare with a streak milestone, in the counter style's own voice.
    case milestone(ExportBadgeStyle)

    var isSilent: Bool {
        switch self {
        case .touch(let sound): sound == .none
        case .swap(let sound): sound == .none
        case .milestone: false
        }
    }
}

/// Deterministic mono PCM for each cue, rendered once and shared.
nonisolated enum ReplaySoundSynth {
    static let sampleRate = 44_100.0

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var store: [ReplaySound: [Float]] = [:]
        func value(_ key: ReplaySound, make: () -> [Float]) -> [Float] {
            lock.lock()
            if let hit = store[key] { lock.unlock(); return hit }
            lock.unlock()
            let made = make()
            lock.lock(); store[key] = made; lock.unlock()
            return made
        }
    }
    private static let cache = Cache()

    static func samples(_ sound: ReplaySound) -> [Float] {
        guard !sound.isSilent else { return [] }
        return cache.value(sound) { render(sound) }
    }

    static func duration(_ sound: ReplaySound) -> Double { Double(samples(sound).count) / sampleRate }

    /// Peak level per slice, 0...1, for drawing a cue's waveform. Short cues fill only the start
    /// of a quarter-second window, so a click looks short and a bell looks long.
    static func envelope(_ sound: ReplaySound, bars: Int) -> [Float] {
        let samples = samples(sound)
        guard bars > 0, !samples.isEmpty else { return [] }
        let window = max(samples.count, Int(sampleRate * 0.25))
        let slice = max(1, window / bars)
        let peaks: [Float] = (0..<bars).map { bar in
            let start = bar * slice, end = min(samples.count, start + slice)
            guard start < end else { return 0 }
            return samples[start..<end].reduce(Float(0)) { max($0, abs($1)) }
        }
        let top = peaks.max() ?? 0
        guard top > 0 else { return peaks }
        // Square root lifts quiet tails enough to read at icon size.
        return peaks.map { $0 > 0 ? max(0.08, ($0 / top).squareRoot()) : 0 }
    }

    // MARK: - Building blocks

    /// Phase of a tone whose frequency slides exponentially from `f0` to `f1` over `over` seconds.
    private static func sweepPhase(_ t: Double, _ f0: Double, _ f1: Double, over: Double) -> Double {
        guard over > 0, f0 > 0, f1 > 0, abs(f1 - f0) > 0.01 else { return 2 * .pi * f0 * t }
        let ratio = f1 / f0
        if t >= over {
            let head = 2 * .pi * f0 * over / log(ratio) * (ratio - 1)
            return head + 2 * .pi * f1 * (t - over)
        }
        return 2 * .pi * f0 * over / log(ratio) * (pow(ratio, t / over) - 1)
    }

    private static func envelope(_ t: Double, attack: Double, decay: Double) -> Double {
        guard t >= 0 else { return 0 }
        let rise = attack > 0 ? min(1, t / attack) : 1
        return rise * exp(-max(0, t - attack) / decay)
    }

    private struct Noise {
        private var state: UInt32
        init(seed: UInt32) { state = seed | 1 }
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(1 << 24) * 2 - 1
        }
    }

    private static func render(_ sound: ReplaySound) -> [Float] {
        let (duration, gain, voice): (Double, Double, (Double, inout Noise, inout Double) -> Double)
        switch sound {
        case .touch(let touch): (duration, gain, voice) = touchVoice(touch)
        case .swap(let swap): (duration, gain, voice) = swapVoice(swap)
        case .milestone(let style): (duration, gain, voice) = milestoneVoice(style)
        }
        let count = Int(duration * sampleRate)
        var noise = Noise(seed: seed(sound))
        var state = 0.0
        var out = [Float](repeating: 0, count: count)
        var peak = 0.0
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let fade = min(1, (duration - t) / 0.01)
            let value = voice(t, &noise, &state) * fade
            out[i] = Float(value)
            peak = max(peak, abs(value))
        }
        let normalize = peak > 0.0001 ? gain / peak : 0
        for i in 0..<count { out[i] = Float(tanh(Double(out[i]) * normalize * 1.2) / tanh(1.2)) }
        return out
    }

    /// A seed that is the same in every process, unlike Hashable's per-run hashing.
    private static func seed(_ sound: ReplaySound) -> UInt32 {
        let name: String
        switch sound {
        case .touch(let touch): name = "touch:" + touch.rawValue
        case .swap(let swap): name = "swap:" + swap.rawValue
        case .milestone(let style): name = "milestone:" + style.rawValue
        }
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }

    private static func lowpass(_ x: Double, _ state: inout Double, cutoff: Double) -> Double {
        let a = 1 - exp(-2 * .pi * cutoff / sampleRate)
        state += a * (x - state)
        return state
    }

    // MARK: - Touch cues

    private static func touchVoice(_ sound: TouchSound) -> (Double, Double, (Double, inout Noise, inout Double) -> Double) {
        switch sound {
        case .none:
            return (0.01, 0, { _, _, _ in 0 })
        case .thud:
            return (0.22, 0.85, { t, n, s in
                let body = sin(sweepPhase(t, 95, 55, over: 0.12)) * envelope(t, attack: 0.002, decay: 0.07)
                let snap = lowpass(n.next(), &s, cutoff: 1800) * envelope(t, attack: 0.0005, decay: 0.006) * 0.8
                return body + snap
            })
        case .pop:
            return (0.14, 0.8, { t, _, _ in
                sin(sweepPhase(t, 640, 220, over: 0.05)) * envelope(t, attack: 0.001, decay: 0.035)
            })
        case .click:
            return (0.06, 0.7, { t, n, s in
                let tick = sin(2 * .pi * 2400 * t) * envelope(t, attack: 0.0003, decay: 0.004)
                let grain = lowpass(n.next(), &s, cutoff: 6000) * envelope(t, attack: 0.0003, decay: 0.008)
                return tick * 0.7 + grain
            })
        case .kick:
            return (0.32, 0.9, { t, n, _ in
                let body = sin(sweepPhase(t, 160, 48, over: 0.09)) * envelope(t, attack: 0.001, decay: 0.16)
                let beater = n.next() * envelope(t, attack: 0.0003, decay: 0.004) * 0.5
                return tanh((body + beater) * 1.8)
            })
        case .snare:
            return (0.24, 0.8, { t, n, s in
                let rattle = lowpass(n.next(), &s, cutoff: 5000) * envelope(t, attack: 0.001, decay: 0.07)
                let body = sin(sweepPhase(t, 210, 150, over: 0.05)) * envelope(t, attack: 0.001, decay: 0.05)
                return rattle * 0.9 + body * 0.6
            })
        case .laser:
            return (0.18, 0.75, { t, _, _ in
                let phase = sweepPhase(t, 2600, 260, over: 0.14)
                return (sin(phase) + 0.3 * sin(phase * 3)) * envelope(t, attack: 0.002, decay: 0.09)
            })
        case .bubble:
            return (0.16, 0.75, { t, _, _ in
                sin(sweepPhase(t, 320, 1100, over: 0.09)) * envelope(t, attack: 0.004, decay: 0.05)
            })
        case .coin:
            return (0.34, 0.7, { t, _, _ in
                let first = t < 0.07 ? sin(2 * .pi * 988 * t) + 0.2 * sin(2 * .pi * 988 * 3 * t) : 0
                let age = t - 0.07
                let second = age >= 0 ? (sin(2 * .pi * 1319 * age) + 0.2 * sin(2 * .pi * 1319 * 3 * age)) * exp(-age / 0.12) : 0
                return (first + second) * min(1, t / 0.002)
            })
        case .bell:
            return (0.5, 0.7, { t, _, _ in
                let f = 880.0
                let partials = [(1.0, 1.0, 0.3), (2.0, 0.5, 0.18), (2.76, 0.35, 0.12), (5.4, 0.18, 0.06)]
                return partials.reduce(0.0) { sum, p in
                    sum + p.1 * sin(2 * .pi * f * p.0 * t) * exp(-t / p.2)
                } * min(1, t / 0.001)
            })
        case .whistle:
            return (0.22, 0.6, { t, _, _ in
                let vibrato = 1 + 0.012 * sin(2 * .pi * 28 * t)
                return sin(2 * .pi * 1760 * vibrato * t) * envelope(t, attack: 0.02, decay: 0.09)
            })
        }
    }

    // MARK: - Milestone fanfares

    /// Each counter's celebration has its own sound, matched to what it shows.
    private static func milestoneVoice(_ style: ExportBadgeStyle) -> (Double, Double, (Double, inout Noise, inout Double) -> Double) {
        switch style {
        case .normal, .classic:
            return fanfareVoice()
        case .odometer:
            // Arcade bells ring out while the prize ticket ratchets.
            return (0.8, 0.75, { t, n, _ in
                var value = 0.0
                for k in 0..<6 {
                    let age = t - Double(k) * 0.065
                    guard age >= 0 else { continue }
                    let f = k % 2 == 0 ? 1568.0 : 2093.0
                    let ring = sin(2 * .pi * f * age) + 0.4 * sin(2 * .pi * f * 2.76 * age) * exp(-age / 0.03)
                    value += ring * exp(-age / (k == 5 ? 0.25 : 0.08)) * min(1, age / 0.002)
                }
                let tick = (t - 0.15).truncatingRemainder(dividingBy: 0.032)
                if t > 0.15, t < 0.7, tick < 0.004 { value += 0.5 * n.next() * (1 - tick / 0.004) }
                return value
            })
        case .broadcast:
            // A TV sting: a whoosh into two brass stabs.
            return (0.75, 0.8, { t, n, s in
                var value = 0.0
                if t < 0.2 { value += 0.7 * lowpass(n.next(), &s, cutoff: 800 + 3000 * t / 0.2) * sin(t / 0.2 * .pi) }
                let stabs: [([Double], Double, Double)] = [([392, 493.9, 587.3], 0.16, 0.12), ([523.3, 659.3, 784], 0.3, 0.4)]
                for (chord, start, length) in stabs {
                    let age = t - start
                    guard age >= 0 else { continue }
                    let envelope = min(1, age / 0.01) * (age < length ? 1 : exp(-(age - length) / 0.06))
                    for f in chord {
                        for h in 1...5 { value += 0.22 * sin(2 * .pi * f * Double(h) * age) / Double(h) * envelope }
                    }
                }
                return value
            })
        case .comic:
            // A cartoon punch, then a boing.
            return (0.6, 0.9, { t, n, phase in
                phase += 2 * .pi * (55 + 170 * exp(-t / 0.035)) / sampleRate
                var value = tanh(2.2 * (sin(phase) * exp(-t / 0.16) + 0.7 * n.next() * exp(-t / 0.025)))
                let age = t - 0.12
                if age > 0 { value += 0.45 * sin(2 * .pi * 300 * age + 3 * sin(2 * .pi * 11 * age)) * exp(-age / 0.18) }
                return value
            })
        case .neon:
            // The tube strikes with clicks, then hums.
            return (0.8, 0.7, { t, n, _ in
                var value = 0.0
                for click in [0.0, 0.075, 0.13] where t >= click && t < click + 0.012 { value += n.next() * (1 - (t - click) / 0.012) }
                let lit = Milestones.neonPower(t) * (t > 0.3 ? exp(-(t - 0.3) / 0.25) : 1)
                var buzz = 0.0
                for h in 1...8 { buzz += sin(2 * .pi * 120 * Double(h) * t) / Double(h) }
                value += 0.4 * buzz * lit
                let a = t - 0.19
                if a > 0, a < 0.25 { value += 0.2 * sin(2 * .pi * (2800 * a - 3000 * a * a)) * exp(-a / 0.08) }
                return value
            })
        case .molten:
            // A deep whump, a rush of air and crackling embers.
            return (0.9, 0.8, { t, n, s in
                var value = 0.9 * sin(2 * .pi * (48 * t + 3 * (1 - exp(-t / 0.05)))) * exp(-t / 0.22)
                value += 0.8 * lowpass(n.next(), &s, cutoff: 600 + 2500 * exp(-t / 0.15)) * exp(-t / 0.3)
                let pop = n.next()
                if t > 0.08, abs(pop) > 0.985 { value += pop * 1.6 * exp(-(t - 0.08) / 0.35) }
                return value
            })
        case .glitch:
            // An 8-bit level-up, bit-crushed.
            return (0.7, 0.65, { t, _, _ in
                let held = (t * 11_025).rounded(.down) / 11_025
                let notes = [523.25, 659.25, 783.99, 1046.5, 1318.5]
                let index = min(notes.count - 1, Int(held / 0.055))
                let age = held - Double(index) * 0.055
                let square: Double = sin(2 * .pi * notes[index] * age) >= 0 ? 1 : -1
                let envelope = index == notes.count - 1 ? exp(-max(0, age - 0.1) / 0.15) : 1
                return (square * 0.5 * envelope * 8).rounded() / 8
            })
        case .graffiti:
            // A rattle of the can, then a long spray.
            return (0.75, 0.7, { t, n, s in
                var value = 0.0
                for click in [0.0, 0.07] {
                    let age = t - click
                    if age >= 0, age < 0.03 { value += 0.9 * sin(2 * .pi * 3200 * age) * exp(-age / 0.006) }
                }
                let spray = t - 0.12
                if spray > 0 {
                    let x = n.next()
                    value += 1.4 * (x - lowpass(x, &s, cutoff: 3500)) * min(1, spray / 0.05) * exp(-max(0, spray - 0.3) / 0.12)
                }
                return value
            })
        case .jelly:
            // Bubbles: quick rising bloops.
            return (0.6, 0.75, { t, _, _ in
                var value = 0.0
                for (k, start) in [0.0, 0.09, 0.17, 0.26].enumerated() {
                    let age = t - start
                    guard age >= 0, age < 0.12 else { continue }
                    let f = 380 + 140 * Double(k)
                    value += sin(2 * .pi * f * (age + 1.5 * age * age / 0.12)) * sin(age / 0.12 * .pi)
                }
                return value
            })
        case .goldCoin:
            // Ka-ching: a metallic tick and two coin rings.
            return (0.85, 0.75, { t, n, _ in
                var value = t < 0.03 ? 0.6 * n.next() * (1 - t / 0.03) : 0
                for (f, start) in [(1975.5, 0.0), (2637.0, 0.09)] {
                    let age = t - start
                    guard age >= 0 else { continue }
                    let ring = sin(2 * .pi * f * age) + 0.5 * sin(2 * .pi * f * 2.76 * age) * exp(-age / 0.08)
                        + 0.25 * sin(2 * .pi * f * 5.4 * age) * exp(-age / 0.05)
                    value += ring * exp(-age / 0.3) * min(1, age / 0.002)
                }
                return value + 0.12 * sin(2 * .pi * 5274 * t) * (0.5 + 0.5 * sin(2 * .pi * 14 * t)) * exp(-t / 0.4)
            })
        case .chalk:
            // Chalk taps on the board, then a bright bell for the gold star.
            return (0.85, 0.7, { t, n, s in
                var value = 0.0
                for tap in [0.0, 0.11, 0.2] {
                    let age = t - tap
                    if age >= 0, age < 0.03 { value += 2.5 * lowpass(n.next(), &s, cutoff: 1800) * exp(-age / 0.008) }
                }
                let age = t - 0.4
                if age > 0 {
                    let bell = sin(2 * .pi * 1760 * age) + 0.3 * sin(2 * .pi * 4400 * age) * exp(-age / 0.05)
                    value += 0.8 * bell * exp(-age / 0.28) * min(1, age / 0.002)
                }
                return value
            })
        }
    }

    /// Four bright rising notes and a shimmering tail: a quick fanfare, not a jingle.
    private static func fanfareVoice() -> (Double, Double, (Double, inout Noise, inout Double) -> Double) {
        (0.78, 0.8, { t, _, _ in
            let notes: [(Double, Double)] = [(1046.5, 0), (1318.5, 0.07), (1568, 0.14), (2093, 0.21)]
            var value = 0.0
            for (index, note) in notes.enumerated() {
                let age = t - note.1
                guard age >= 0 else { continue }
                let decay = index == notes.count - 1 ? 0.32 : 0.12
                value += (sin(2 * .pi * note.0 * age) + 0.3 * sin(2 * .pi * note.0 * 2 * age)
                          + 0.12 * sin(2 * .pi * note.0 * 3 * age)) * exp(-age / decay) * min(1, age / 0.003)
            }
            let tail = t - 0.21
            if tail > 0 {
                let tremolo = 0.6 + 0.4 * sin(2 * .pi * 11 * tail)
                value += 0.25 * sin(2 * .pi * 4186 * tail) * tremolo * exp(-tail / 0.25)
            }
            return value
        })
    }

    // MARK: - Swap cues

    private static func swapVoice(_ sound: BallSwapSound) -> (Double, Double, (Double, inout Noise, inout Double) -> Double) {
        switch sound {
        case .none:
            return (0.01, 0, { _, _, _ in 0 })
        case .whoosh:
            return (0.42, 0.8, { t, n, s in
                // The filter opens then closes again, like air passing.
                let swell = sin(min(1, t / 0.42) * .pi)
                let cutoff = 300 + 3200 * swell * swell
                return lowpass(n.next(), &s, cutoff: cutoff) * (0.2 + 0.8 * swell)
            })
        case .chime:
            return (0.55, 0.7, { t, _, _ in
                let notes = [(1046.5, 0.0), (1318.5, 0.07), (1568.0, 0.14)]
                return notes.reduce(0.0) { sum, note in
                    let age = t - note.1
                    guard age >= 0 else { return sum }
                    return sum + (sin(2 * .pi * note.0 * age) + 0.25 * sin(2 * .pi * note.0 * 2.01 * age)) * exp(-age / 0.17) * min(1, age / 0.002)
                }
            })
        case .zap:
            return (0.16, 0.8, { t, n, _ in
                let tone = sin(sweepPhase(t, 1900, 110, over: 0.1)) * envelope(t, attack: 0.001, decay: 0.07)
                return tone + n.next() * envelope(t, attack: 0.0005, decay: 0.01) * 0.4
            })
        case .shimmer:
            return (0.5, 0.6, { t, _, _ in
                let partials: [Double] = [2093, 2637, 3136, 3951, 4699, 5274]
                return partials.enumerated().reduce(0.0) { sum, p in
                    let tremolo = 0.6 + 0.4 * sin(2 * .pi * (5.5 + Double(p.offset)) * t)
                    return sum + sin(2 * .pi * p.element * t) * tremolo / Double(p.offset + 2)
                } * envelope(t, attack: 0.03, decay: 0.18)
            })
        case .drop:
            return (0.5, 0.9, { t, _, _ in
                tanh(sin(sweepPhase(t, 240, 38, over: 0.4)) * 1.6) * envelope(t, attack: 0.004, decay: 0.3)
            })
        case .glitch:
            return (0.24, 0.7, { t, n, _ in
                // Grains of square wave at pitches that jump every 15 ms.
                let grain = Int(t / 0.015)
                let pitch = 180 + 1400 * abs(sin(Double(grain) * 2.7))
                let square: Double = sin(2 * .pi * pitch * t) > 0 ? 1 : -1
                let gate = (grain % 3 == 2) ? 0.2 : 1.0
                return (square * 0.7 + n.next() * 0.15) * gate * envelope(t, attack: 0.001, decay: 0.2)
            })
        case .thunder:
            return (0.6, 0.85, { t, n, s in
                let rumble = lowpass(n.next(), &s, cutoff: 160 + 500 * exp(-t / 0.08)) * envelope(t, attack: 0.005, decay: 0.22)
                let sub = sin(2 * .pi * 44 * t) * envelope(t, attack: 0.01, decay: 0.3) * 0.5
                return rumble * 2.2 + sub
            })
        case .sparkle:
            return (0.36, 0.6, { t, _, _ in
                let blip = Int(t / 0.035)
                let age = t - Double(blip) * 0.035
                let pitch = 1500 * pow(1.14, Double(blip))
                return sin(2 * .pi * pitch * age) * exp(-age / 0.012) * exp(-t / 0.3)
            })
        case .flip:
            return (0.24, 0.7, { t, _, _ in
                let phase = t < 0.11 ? sweepPhase(t, 320, 1300, over: 0.11)
                    : sweepPhase(0.11, 320, 1300, over: 0.11) + sweepPhase(t - 0.11, 1300, 320, over: 0.11)
                return sin(phase) * envelope(t, attack: 0.004, decay: 0.16)
            })
        case .warp:
            return (0.4, 0.7, { t, _, _ in
                let modulator = sin(2 * .pi * (30 + 220 * min(1, t / 0.3)) * t) * 4
                return sin(2 * .pi * 420 * t + modulator) * envelope(t, attack: 0.01, decay: 0.16)
            })
        }
    }
}

/// Every cue on the clip, in order. The editor plays them as the clip passes each one;
/// the export mixes them into the saved audio.
nonisolated struct ReplaySoundtrack: Hashable, Sendable {
    struct Event: Hashable, Sendable {
        let time: Double
        let sound: ReplaySound
    }
    let events: [Event]

    init(events: [Event] = []) {
        self.events = events.filter { $0.time.isFinite && $0.time >= 0 && !$0.sound.isSilent }.sorted { $0.time < $1.time }
    }

    /// Touch cues on every touch; where the look changes, the change cue plays instead; on a
    /// milestone, the fanfare plays instead of both. Every touch is one sound at most.
    /// `touchTimes` sorted.
    init(edit: SessionEditState, touchTimes: [Double], milestones: ExportBadgeStyle? = nil) {
        let celebrated = milestones == nil ? [] : Set(Milestones.touchIndices(touchCount: touchTimes.count))
        let swaps = (edit.swapSound == .none ? [] : edit.lookSwaps(touchTimes: touchTimes))
            .filter { !celebrated.contains($0.index) }
        let changed = Set(swaps.map(\.index))
        var events: [Event] = []
        if edit.touchSound != .none {
            events += touchTimes.enumerated().filter { !changed.contains($0.offset) && !celebrated.contains($0.offset) }
                .map { Event(time: $0.element, sound: .touch(edit.touchSound)) }
        }
        events += swaps.map { Event(time: $0.time, sound: .swap(edit.swapSound)) }
        if let milestones { events += celebrated.sorted().map { Event(time: touchTimes[$0], sound: .milestone(milestones)) } }
        self.init(events: events)
    }

    var isEmpty: Bool { events.isEmpty }

    /// Cues starting after `from` up to and including `to`.
    func events(after from: Double, through to: Double) -> ArraySlice<Event> {
        guard to > from else { return [] }
        var lo = 0, hi = events.count
        while lo < hi { let mid = (lo + hi) / 2; if events[mid].time <= from { lo = mid + 1 } else { hi = mid } }
        var end = lo
        while end < events.count && events[end].time <= to { end += 1 }
        return events[lo..<end]
    }

    /// Adds every cue overlapping the frames `start..<start+count` into `left`/`right`.
    func mix(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, start: Int, count: Int,
             sampleRate: Double = ReplaySoundSynth.sampleRate, gain: Float = 0.9) {
        let chunkEnd = start + count
        for event in events {
            let samples = ReplaySoundSynth.samples(event.sound)
            let begin = Int((event.time * sampleRate).rounded())
            let finish = begin + samples.count
            if begin >= chunkEnd { break }
            guard finish > start else { continue }
            let first = max(begin, start), last = min(finish, chunkEnd)
            for frame in first..<last {
                let value = samples[frame - begin] * gain
                left[frame - start] += value
                right[frame - start] += value
            }
        }
    }

    /// A mono render of the whole soundtrack, for tests and previews.
    func render(duration: Double, sampleRate: Double = ReplaySoundSynth.sampleRate) -> [Float] {
        let count = max(0, Int((duration * sampleRate).rounded()))
        var left = [Float](repeating: 0, count: count), right = [Float](repeating: 0, count: count)
        guard count > 0 else { return [] }
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                mix(into: l.baseAddress!, r.baseAddress!, start: 0, count: count, sampleRate: sampleRate)
            }
        }
        return left.map { max(-1, min(1, $0)) }
    }

    enum Failure: LocalizedError {
        case decode(String), encode(String)
        var errorDescription: String? {
            switch self {
            case .decode(let reason): "Couldn’t read the clip’s audio. \(reason)"
            case .encode(let reason): "Couldn’t write the replay sounds. \(reason)"
            }
        }
    }

    /// The clip's own audio with every cue mixed in, as one stereo AAC file covering
    /// `duration` from zero. Silence stands in where the clip has no sound, or everywhere
    /// when `includeSource` is false. Written with AVAssetWriter so the track drops straight
    /// into the export composition.
    func mixedAudio(source: AVAsset, duration: CMTime, includeSource: Bool = true) async throws -> URL {
        let rate = ReplaySoundSynth.sampleRate
        let totalFrames = max(1, Int((CMTimeGetSeconds(duration) * rate).rounded()))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("juggledude-sounds-\(UUID().uuidString).m4a")
        var description = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw Failure.encode("Unsupported audio format.")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.encode("Cannot encode the replay sounds.") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.encode(writer.error?.localizedDescription ?? "Encoding did not start.") }
        writer.startSession(atSourceTime: .zero)
        var written = 0, finished = false
        defer { if !finished { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) } }
        func write(_ fill: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void, count: Int) async throws {
            guard count > 0 else { return }
            var left = [Float](repeating: 0, count: count), right = [Float](repeating: 0, count: count)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    fill(l.baseAddress!, r.baseAddress!, count)
                    mix(into: l.baseAddress!, r.baseAddress!, start: written, count: count, sampleRate: rate)
                }
            }
            var interleaved = [Float](repeating: 0, count: count * 2)
            for frame in 0..<count {
                interleaved[frame * 2] = max(-1, min(1, left[frame]))
                interleaved[frame * 2 + 1] = max(-1, min(1, right[frame]))
            }
            let length = count * 8
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
                  interleaved.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                      offsetIntoDestination: 0, dataLength: length) }) == kCMBlockBufferNoErr else {
                throw Failure.encode("Out of audio memory.")
            }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: Int32(rate)), decodeTimeStamp: .invalid)
            var size = 8
            var sample: CMSampleBuffer?
            guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
                throw Failure.encode("Cannot build an audio sample.")
            }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw Failure.encode(writer.error?.localizedDescription ?? "Encoding stopped.") }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard input.append(sample) else { throw Failure.encode(writer.error?.localizedDescription ?? "Cannot write the replay sounds.") }
            written += count
        }
        func silence(until frame: Int) async throws {
            while written < frame {
                try await write({ _, _, _ in }, count: min(frame - written, Int(rate)))
            }
        }
        let tracks = includeSource ? try await source.loadTracks(withMediaType: .audio) : []
        if !tracks.isEmpty {
            let reader = try AVAssetReader(asset: source)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.decode("Unsupported audio track.") }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: .zero, duration: duration)
            guard reader.startReading() else { throw Failure.decode(reader.error?.localizedDescription ?? "Decoding did not start.") }
            defer { reader.cancelReading() }
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                let position = Int((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * rate).rounded())
                if position > written { try await silence(until: min(position, totalFrames)) }
                // Already covered frames (an overlapping start) are skipped, not doubled.
                let skip = max(0, written - position)
                guard skip < frames, written < totalFrames else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                let status = interleaved.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { throw Failure.decode("Audio sample copy failed.") }
                let available = min(frames - skip, interleaved.count / 2 - skip, totalFrames - written)
                guard available > 0 else { continue }
                try await write({ left, right, count in
                    for frame in 0..<count {
                        left[frame] = interleaved[(skip + frame) * 2]
                        right[frame] = interleaved[(skip + frame) * 2 + 1]
                    }
                }, count: available)
            }
            if reader.status == .failed { throw Failure.decode(reader.error?.localizedDescription ?? "Decoding stopped.") }
        }
        try await silence(until: totalFrames)
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(written), timescale: Int32(rate)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.encode(writer.error?.localizedDescription ?? "Encoding did not finish.") }
        finished = true
        return url
    }
}
