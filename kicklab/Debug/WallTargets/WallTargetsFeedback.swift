#if DEBUG
import AVFoundation
import Foundation

/// Playback/session operations are serialized away from the UI and camera.
/// AVAudioPlayer.play() can block on the output route, even when preloaded.
/// The unchecked conformance is limited to this owner: only `queue` accesses
/// the output after construction. Requests retain their submission order.
nonisolated final class WallTargetsFeedback: @unchecked Sendable {
    static let shared = WallTargetsFeedback()
    static let soundPreference = "wallTargets.hitSoundsEnabled"
    private let queue = DispatchQueue(label: "kicklab.wall-hit-audio", qos: .userInteractive)
    private let output: any WallFeedbackOutput

    init(output: any WallFeedbackOutput = WallTargetsAudioOutput()) { self.output = output }

    func play(cleared: Bool, game: WallGame = .clearTheWall, remainingHealth: Int = 0, brokenBricks: Int = 1) {
        queue.async { self.output.play(cleared: cleared, game: game, remainingHealth: remainingHealth, brokenBricks: brokenBricks) }
    }

    func prepare() { queue.async { self.output.prepare() } }
    func invalidatePreparation() { queue.async { self.output.invalidatePreparation() } }
    func play(_ cue: WallArcadeCue) { queue.async { self.output.playArcade(cue) } }
}

nonisolated protocol WallFeedbackOutput: AnyObject {
    func play(cleared: Bool, game: WallGame, remainingHealth: Int, brokenBricks: Int)
    func prepare()
    func invalidatePreparation()
    func playArcade(_ cue: WallArcadeCue)
}

/// Short sounds played once per score, independent of the number of displays.
nonisolated private final class WallTargetsAudioOutput: WallFeedbackOutput {
    private var hit: AVAudioPlayer?
    private var clear: AVAudioPlayer?
    private var brickPlayers: [WallHitSound: [AVAudioPlayer]] = [:]
    private var nextVariant: [WallHitSound: Int] = [:]
    private var activeBrickPlayers: [AVAudioPlayer] = []
    private var arcadePlayers: [WallArcadeCue: AVAudioPlayer] = [:]
    private var prepared = false
    init() {
        hit = try? AVAudioPlayer(data: Self.sound(cleared: false))
        clear = try? AVAudioPlayer(data: Self.sound(cleared: true))
        hit?.volume = 0.70
        clear?.volume = 0.65
        hit?.prepareToPlay()
        clear?.prepareToPlay()
        for cue in [WallHitSound.armourCrack, .brickBreak, .brickSmash, .brickClear] {
            brickPlayers[cue] = cue.assets.compactMap { name in
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
                      let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                player.volume = 0.78
                player.prepareToPlay()
                return player
            }
        }
        for cue in WallArcadeCue.allCases {
            if let player = try? AVAudioPlayer(data: WallArcadeSound.data(for: cue)) {
                player.volume = 0.72; player.prepareToPlay(); arcadePlayers[cue] = player
            }
        }
    }

    func playArcade(_ cue: WallArcadeCue) {
        guard UserDefaults.standard.object(forKey: WallTargetsFeedback.soundPreference) == nil
            || UserDefaults.standard.bool(forKey: WallTargetsFeedback.soundPreference) else { return }
        if !prepared { prepare() }
        // One short arcade voice at a time; changing games cannot retain tails.
        arcadePlayers.values.forEach { $0.stop() }
        activeBrickPlayers.forEach { $0.stop() }; activeBrickPlayers = []
        let player = arcadePlayers[cue]
        player?.currentTime = 0; player?.play()
    }

    func play(cleared: Bool, game: WallGame = .clearTheWall, remainingHealth: Int = 0, brokenBricks: Int = 1) {
        guard UserDefaults.standard.object(forKey: WallTargetsFeedback.soundPreference) == nil
                || UserDefaults.standard.bool(forKey: WallTargetsFeedback.soundPreference) else { return }
        if !prepared { prepare() }
        if hit?.isPlaying == true { hit?.stop() }
        if clear?.isPlaying == true { clear?.stop() }
        activeBrickPlayers.removeAll { !$0.isPlaying }
        if game != .brickBlast {
            activeBrickPlayers.forEach { $0.stop() }; activeBrickPlayers = []
        }
        let cue = WallHitSound.forHit(game: game, remainingHealth: remainingHealth, cleared: cleared, brokenBricks: brokenBricks)
        let player: AVAudioPlayer?
        if let variants = brickPlayers[cue], !variants.isEmpty {
            let index = nextVariant[cue, default: 0] % variants.count
            nextVariant[cue] = index + 1
            player = variants[index]
            // Let rubble settle between quick shots instead of chopping off
            // the previous tail. Three preloaded voices is a hard upper bound.
            activeBrickPlayers.removeAll { $0 === player }
            while activeBrickPlayers.count >= 3 { activeBrickPlayers.removeFirst().stop() }
            activeBrickPlayers.append(variants[index])
        } else { player = cleared ? clear : hit }
        player?.stop()
        player?.currentTime = 0
        player?.play()
    }

    /// Warm the output route before the first throw, instead of on its hit.
    func prepare() {
        guard UserDefaults.standard.object(forKey: WallTargetsFeedback.soundPreference) == nil
                || UserDefaults.standard.bool(forKey: WallTargetsFeedback.soundPreference) else { return }
        prepared = configureAudio()
        hit?.prepareToPlay()
        clear?.prepareToPlay()
        for pool in brickPlayers.values { pool.forEach { $0.prepareToPlay() } }
        arcadePlayers.values.forEach { $0.prepareToPlay() }
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
