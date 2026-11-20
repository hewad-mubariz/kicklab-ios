#if DEBUG
import Foundation

/// Small, original mono cues built once at startup; no speech or looping music.
nonisolated enum WallArcadeSound {
    static func data(for cue: WallArcadeCue) -> Data {
        let rate = 44100, duration: Double
        switch cue {
        case .memoryHit: duration = 0.22
        case .memoryMiss: duration = 0.30
        case .meteorHit: duration = 0.46
        case .shieldLost: duration = 0.40
        case .victory: duration = 0.65
        case .defeat: duration = 0.50
        case .tileClaim: duration = 0.25
        case .goal: duration = 0.62
        case .keeperSave: duration = 0.34
        }
        let count = Int(Double(rate) * duration)
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + count * 2))
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2))
        word(UInt16(2)); word(UInt16(16)); data.append(Data("data".utf8)); word(UInt32(count * 2))
        var noise: UInt64 = 9127
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            noise = noise &* 6364136223846793005 &+ 1
            let n = Double((noise >> 32) & 65535) / 32768 - 1
            let attack = min(1, t / 0.003), fade = min(1, (duration - t) / 0.04)
            var value: Double
            switch cue {
            case .memoryHit:
                value = (sin(2 * .pi * 660 * t) + 0.3 * sin(2 * .pi * 1330 * t)) * exp(-t / 0.055)
            case .memoryMiss:
                value = 0.7 * sin(2 * .pi * (240 * t - 180 * t * t)) * exp(-t / 0.09)
            case .meteorHit:
                value = 0.65 * sin(2 * .pi * (120 * t - 80 * t * t)) * exp(-t / 0.085)
                    + 0.40 * n * exp(-t / 0.10) + 0.22 * sin(2 * .pi * 1660 * t) * exp(-t / 0.035)
            case .shieldLost:
                value = 0.8 * sin(2 * .pi * 92 * t) * exp(-t / 0.12) + 0.18 * n * exp(-t / 0.05)
            case .tileClaim:
                value = 0.7 * sin(2 * .pi * 440 * t) * exp(-t / 0.065)
                    + 0.35 * sin(2 * .pi * 880 * t) * exp(-t / 0.045) + 0.15 * n * exp(-t / 0.012)
            case .goal:
                value = 0.65 * sin(2 * .pi * (130 * t - 75 * t * t)) * exp(-t / 0.06)
                    + 0.22 * n * exp(-t / 0.09)
                for (j, note) in [523.25, 659.25, 1046.5].enumerated() {
                    let a = t - 0.10 - Double(j) * 0.095
                    if a >= 0 { value += 0.55 * sin(2 * .pi * note * a) * min(1, a / 0.003) * exp(-a / 0.075) }
                }
            case .keeperSave:
                value = 0.85 * sin(2 * .pi * (105 * t - 60 * t * t)) * exp(-t / 0.06)
                    + 0.32 * n * exp(-t / 0.035)
            case .victory, .defeat:
                let notes = cue == .victory ? [523.25, 659.25, 783.99, 1046.5] : [392.0, 329.6, 261.6]
                value = 0
                for (j, note) in notes.enumerated() {
                    let a = t - Double(j) * 0.09
                    if a >= 0 { value += 0.6 * sin(2 * .pi * note * a) * min(1, a / 0.003) * exp(-a / 0.08) }
                }
            }
            word(Int16(max(-0.9, min(0.9, value * attack * fade * 0.64)) * 32767))
        }
        return data
    }
}
#endif
