#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Foundation

/// Short synthesized chimes, played once on the phone rather than once per
/// board view (the projector and phone both observe the same game state).
@MainActor
final class WallTargetsFeedback {
    private var hit: AVAudioPlayer?
    private var clear: AVAudioPlayer?

    init() {
        hit = try? AVAudioPlayer(data: Self.chime(frequencies: [880, 1320], duration: 0.16))
        clear = try? AVAudioPlayer(data: Self.chime(frequencies: [660, 880, 1320], duration: 0.45))
        hit?.volume = 0.55
        clear?.volume = 0.65
        hit?.prepareToPlay()
        clear?.prepareToPlay()
    }

    func play(cleared: Bool) {
        // Mix with other audio. No microphone permission or recording session is needed.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let player = cleared ? clear : hit
        player?.currentTime = 0
        player?.play()
    }

    private static func chime(frequencies: [Double], duration: Double) -> Data {
        let rate = 22050, count = Int(Double(rate) * duration)
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
            let envelope = min(1, t / 0.008) * pow(max(0, 1 - t / duration), 2)
            let tone = frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(frequencies.count)
            word(Int16(tone * envelope * 16000))
        }
        return data
    }
}
#endif
