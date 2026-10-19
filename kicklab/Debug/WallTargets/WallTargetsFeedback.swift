#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Foundation

/// Short hit sounds, played once on the phone rather than once per
/// board view (the projector and phone both observe the same game state).
@MainActor
final class WallTargetsFeedback {
    static let shared = WallTargetsFeedback()
    private var hit: AVAudioPlayer?
    private var clear: AVAudioPlayer?
    private var prepared = false
    static let soundPreference = "wallTargets.hitSoundsEnabled"

    init() {
        hit = try? AVAudioPlayer(data: Self.sound(cleared: false))
        clear = try? AVAudioPlayer(data: Self.sound(cleared: true))
        hit?.volume = 0.70
        clear?.volume = 0.65
        hit?.prepareToPlay()
        clear?.prepareToPlay()
    }

    func play(cleared: Bool) {
        guard UserDefaults.standard.object(forKey: Self.soundPreference) == nil
                || UserDefaults.standard.bool(forKey: Self.soundPreference) else { return }
        if !prepared { prepare() }
        hit?.stop()
        clear?.stop()
        let player = cleared ? clear : hit
        player?.currentTime = 0
        player?.play()
    }

    /// Warm the output route before the first throw, instead of on its hit.
    func prepare() {
        guard UserDefaults.standard.object(forKey: Self.soundPreference) == nil
                || UserDefaults.standard.bool(forKey: Self.soundPreference) else { return }
        prepared = configureAudio()
        hit?.prepareToPlay()
        clear?.prepareToPlay()
    }

    /// A route change or interruption can invalidate the warmed audio session.
    func invalidatePreparation() { prepared = false }

    private func configureAudio() -> Bool {
        // Hit feedback is audible in Silent mode; media volume and the current
        // phone/AirPlay route still apply. No microphone input is requested.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch { return false }
    }

    private static func sound(cleared: Bool) -> Data {
        // A rounded percussive strike with a short, plucked tail. Clearing the
        // board adds three rising notes; neither cue contains speech or a sustained beep.
        let rate = 44100, duration = cleared ? 0.48 : 0.18
        let count = Int(Double(rate) * duration)
        let notes = cleared ? [523.25, 659.25, 783.99] : [740.0]
        var data = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8)); word(UInt32(36 + count * 2))
        data.append(Data("WAVEfmt ".utf8)); word(UInt32(16))
        word(UInt16(1)); word(UInt16(1)); word(UInt32(rate)); word(UInt32(rate * 2))
        word(UInt16(2)); word(UInt16(16))
        data.append(Data("data".utf8)); word(UInt32(count * 2))
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            var tone = 0.0
            for (index, frequency) in notes.enumerated() {
                let age = t - Double(index) * 0.075
                guard age >= 0 else { continue }
                let envelope = min(1, age / 0.002) * exp(-age / (cleared ? 0.075 : 0.035))
                let phase = 2 * Double.pi * frequency * age
                tone += envelope * (0.68 * sin(phase) + 0.22 * sin(phase * 2.01) * exp(-age / 0.025)
                                    + 0.10 * sin(phase * 3.97) * exp(-age / 0.012))
            }
            if !cleared {
                tone += 0.35 * sin(2 * .pi * 185 * t) * min(1, t / 0.002) * exp(-t / 0.022)
            }
            let fade = min(1, (duration - t) / 0.02)
            word(Int16(max(-1, min(1, tone * fade / 1.5)) * 24000))
        }
        return data
    }
}
#endif
