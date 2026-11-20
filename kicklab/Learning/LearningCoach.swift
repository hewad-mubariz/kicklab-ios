import AVFoundation
import Combine

/// Output-only prompts. The coach never claims to have observed a touch.
@MainActor
final class LearningCoach: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Mode { case demonstration, practice, reflection }
    @Published private(set) var mode: Mode = .demonstration
    @Published private(set) var caption = "Let's try together. One little step at a time."
    @Published private(set) var speaking = false
    @Published private(set) var round = 0
    @Published var voiceEnabled = true { didSet { if !voiceEnabled { stopSpeech() } } }
    @Published private(set) var voiceUnavailable = false
    private let speech = AVSpeechSynthesizer()
    private var practice: Task<Void, Never>?
    private var oldAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
    private var interruption: NSObjectProtocol?

    override init() {
        super.init()
        speech.delegate = self
        interruption = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                               object: nil, queue: .main) { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.pause() }
        }
    }
    deinit {
        practice?.cancel()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
    }
    func introduce(_ lesson: LearnLesson) { say("Let's try together. \(lesson.cue)") }
    func start(_ lesson: LearnLesson) {
        practice?.cancel()
        mode = .practice; round = 0
        say("Let's try together. Have your ball ready. Three tries, at your pace.")
        practice = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(7))
                for (index, cue) in lesson.practiceCues.enumerated() {
                    try Task.checkCancellation()
                    guard let self else { return }
                    self.round = index + 1; self.say(cue)
                    try await Task.sleep(for: .seconds(10))
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.mode = .reflection
                self.say("Take a breath. How did that feel? We can try again or make it a little easier.")
                self.practice = nil
            } catch { /* Pausing, leaving and restarting cancel all pending cues. */ }
        }
    }
    func finish() {
        practice?.cancel(); practice = nil; mode = .reflection
        say("How did that feel? Choose what works for you.")
    }
    func pause() {
        practice?.cancel(); practice = nil
        if mode == .practice {
            mode = .demonstration
            caption = "Take your time. Start a fresh round when you're ready."
        }
        stopSpeech()
    }
    func reset() { pause(); mode = .demonstration; round = 0 }
    func say(_ text: String) {
        stopSpeech(); caption = text
        guard voiceEnabled else { return }
        guard let utterance = Self.utterance(text) else {
            voiceUnavailable = true; return
        }
        voiceUnavailable = false
        let audio = AVAudioSession.sharedInstance()
        oldAudio = (audio.category, audio.mode, audio.categoryOptions)
        do {
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true)
        } catch { restoreAudio(); voiceUnavailable = true; return }
        speaking = true; speech.speak(utterance)
    }
    static func utterance(_ text: String) -> AVSpeechUtterance? {
        guard let voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US") else { return nil }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.88
        utterance.pitchMultiplier = 1.02
        return utterance
    }
    private func stopSpeech() {
        speech.stopSpeaking(at: .immediate); speaking = false; restoreAudio()
    }
    private func restoreAudio() {
        guard let oldAudio else { return }; self.oldAudio = nil
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(oldAudio.0, mode: oldAudio.1, options: oldAudio.2)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, !self.speech.isSpeaking else { return }
            self.speaking = false; self.restoreAudio()
        }
    }
}
