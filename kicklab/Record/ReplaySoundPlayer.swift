import AVFoundation
import Combine
import Foundation

/// Plays replay cues in the editor: each one as the clip passes it, and once on a tap in the
/// picker. A small pool of player nodes lets a touch and a ball change sound together.
/// Scrubbing stays silent; a seek simply moves the cursor.
@MainActor
final class ReplaySoundPlayer: ObservableObject {
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var next = 0
    private var buffers: [ReplaySound: AVAudioPCMBuffer] = [:]
    private var format: AVAudioFormat?
    private var cursor: Double?
    private var started = false
    private var sessionActive = false
    /// Which cue was last previewed from the picker, for the chip's own feedback.
    @Published private(set) var previewed: ReplaySound?
    @Published private(set) var previewCount = 0

    private var soundtrack = ReplaySoundtrack()

    func update(_ soundtrack: ReplaySoundtrack) {
        guard self.soundtrack != soundtrack else { return }
        self.soundtrack = soundtrack
        if soundtrack.isEmpty { stopEngine(); return }
        // Render each cue now, so the first touch never waits on the synthesizer.
        for sound in Set(soundtrack.events.map(\.sound)) { _ = buffer(for: sound) }
    }

    /// The clip jumped: cues before `time` are in the past, nothing plays for the jump itself.
    func seek(to time: Double) { cursor = time }

    /// Playback reached `time`; plays every cue passed since the last call.
    func advance(to time: Double, playing: Bool) {
        defer { cursor = time }
        guard playing, !soundtrack.isEmpty, let cursor else { return }
        // A rewind or a loop restart resets rather than replaying everything in between.
        guard time > cursor, time - cursor < 0.5 else { return }
        for event in soundtrack.events(after: cursor, through: time) {
            play(event.sound)
        }
    }

    /// Plays one cue now, e.g. when it is picked.
    func preview(_ sound: ReplaySound) {
        previewed = sound
        previewCount += 1
        play(sound)
    }

    func stop() {
        stopEngine()
        cursor = nil
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }

    private func play(_ sound: ReplaySound) {
        guard !sound.isSilent, let buffer = buffer(for: sound), startEngine() else { return }
        let player = players[next % players.count]
        next += 1
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    private func buffer(for sound: ReplaySound) -> AVAudioPCMBuffer? {
        if let hit = buffers[sound] { return hit }
        let samples = ReplaySoundSynth.samples(sound)
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: ReplaySoundSynth.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffers[sound] = buffer
        return buffer
    }

    private func startEngine() -> Bool {
        if started { return true }
        // The default session follows the ring switch, which would make every pick sound broken.
        // Media playback is audible in silent mode, like any video app, and keeps the route.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
        } catch {
            NSLog("Replay sounds session: %@", error.localizedDescription)
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: ReplaySoundSynth.sampleRate, channels: 1) else { return false }
        if players.isEmpty {
            players = (0..<4).map { _ in AVAudioPlayerNode() }
            for player in players {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                player.volume = 0.9
            }
        }
        self.format = format
        do {
            try engine.start()
            started = true
            return true
        } catch {
            NSLog("Replay sounds: %@", error.localizedDescription)
            return false
        }
    }

    private func stopEngine() {
        guard started else { return }
        for player in players { player.stop() }
        engine.stop()
        started = false
    }
}
