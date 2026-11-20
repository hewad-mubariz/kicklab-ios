import Foundation

enum LearnLevel: String, CaseIterable, Identifiable {
    case basics, rhythm, control, advanced
    var id: String { rawValue }
    var title: String {
        switch self {
        case .basics: return "Basics"
        case .rhythm: return "Build rhythm"
        case .control: return "Control"
        case .advanced: return "Advanced"
        }
    }
    var number: String { String(format: "%02d", Self.allCases.firstIndex(of: self)! + 1) }
    var subtitle: String {
        switch self {
        case .basics: return "Get comfortable. Every little touch counts."
        case .rhythm: return "Join your touches, one small sequence at a time."
        case .control: return "Keep the ball where you want it."
        case .advanced: return "Change the height. Move with the ball."
        }
    }
}

enum CoachMotion: String {
    case bounceCatch, touchCatch, otherFootCatch, twoTouchCatch, alternatingCatch
    case alternating, closeControl, otherFoot, lowTouches, changeHeight, moving, thigh

    var duration: Double {
        switch self {
        case .bounceCatch, .touchCatch, .otherFootCatch: return 5.6
        case .twoTouchCatch, .alternatingCatch: return 6.4
        case .changeHeight: return 5.2
        case .thigh: return 3.4
        default: return 3.2
        }
    }
    var endsWithCatch: Bool {
        [.bounceCatch, .touchCatch, .otherFootCatch, .twoTouchCatch, .alternatingCatch].contains(self)
    }
}

struct LearnLesson: Identifiable, Equatable {
    let id: String
    let level: LearnLevel
    let title: String
    let summary: String
    let motion: CoachMotion
    let target: String
    let cue: String
    let steps: [String]
    let practiceCues: [String]
    let easierID: String

    static let all: [LearnLesson] = [
        .init(id: "bounce-catch", level: .basics, title: "Bounce. Catch. Repeat.",
              summary: "Find the ball's rhythm before adding a touch.", motion: .bounceCatch,
              target: "Try 3 relaxed bounce-and-catches", cue: "Let it bounce. Bring it back to you.",
              steps: ["Hold the ball in front of you.", "Drop it onto a firm, level surface.", "Let it rise, then catch it comfortably."],
              practiceCues: ["Drop the ball and let it bounce. Then catch it.", "Again, at your own pace. Keep the ball close.", "One more try. Catch it, reset, and relax."], easierID: "bounce-catch"),
        .init(id: "touch-catch", level: .basics, title: "One touch. One catch.",
              summary: "Your first little keepy-uppy starts here.", motion: .touchCatch,
              target: "Try 3 single touches, catching each one", cue: "A gentle touch. Then catch and reset.",
              steps: ["Hold the ball just in front of your kicking foot.", "Drop it and gently lift it with your laces.", "Catch the ball. That completes the repetition."],
              practiceCues: ["Let's try one. Drop, a gentle touch, and catch.", "Keep it close. Aim to lift the ball back toward your hands.", "One more, when you're ready. A touch, a catch, and reset."], easierID: "bounce-catch"),
        .init(id: "other-foot-catch", level: .basics, title: "Meet your other foot.",
              summary: "Give both sides a comfortable starting point.", motion: .otherFootCatch,
              target: "Try 3 touch-and-catches with your less comfortable foot", cue: "Same small touch. A different foot.",
              steps: ["Choose your less comfortable foot.", "Drop the ball over that foot and give it one small lift.", "Catch and reset after every attempt."],
              practiceCues: ["Choose your other foot. One gentle touch, then catch.", "Take your time. We are practising one touch, not a record.", "Try another. Keep the drop close to your foot."], easierID: "touch-catch"),
        .init(id: "two-touch", level: .rhythm, title: "Make it two.",
              summary: "Connect two touches before your catch.", motion: .twoTouchCatch,
              target: "Try 3 sets of two touches and a catch", cue: "One. Two. Catch. You set the pace.",
              steps: ["Start with your comfortable foot.", "Lift the ball twice, keeping the touches small.", "Catch after the second touch, then start again."],
              practiceCues: ["Let's connect two. One, two, then catch.", "If it gets away, reset with one touch and a catch.", "Try your next pair. Give yourself time between attempts."], easierID: "touch-catch"),
        .init(id: "alternate-catch", level: .rhythm, title: "A little left. A little right.",
              summary: "Share two touches between your feet.", motion: .alternatingCatch,
              target: "Try 3 alternating pairs, then catch", cue: "One foot, then the other. Keep it gentle.",
              steps: ["Start with one small lift.", "Guide the next touch to your other foot.", "Catch after the pair and reset your balance."],
              practiceCues: ["One foot, then the other, then catch. Let's try together.", "Keep the transfer small. You can reset after each pair.", "Another pair when you're ready. Stay relaxed."], easierID: "other-foot-catch"),
        .init(id: "steady-five", level: .rhythm, title: "Find your rhythm.",
              summary: "Build a short run you can repeat.", motion: .alternating,
              target: "Explore a run of up to 5 touches", cue: "Small touches. Time to get ready for the next.",
              steps: ["Start with two comfortable touches.", "Add another when the ball stays within reach.", "Reset whenever you need. Try to repeat a controlled run."],
              practiceCues: ["Start with a short run. Two or three touches is fine.", "Keep it close. Give yourself time for the next touch.", "Try another run. Stop and reset whenever you need."], easierID: "alternate-catch"),
        .init(id: "keep-close", level: .control, title: "Keep it close.",
              summary: "For the moments when the ball runs away.", motion: .closeControl,
              target: "Try 3 short runs within comfortable reach", cue: "Bring the ball up, toward you.",
              steps: ["Choose a clear space and start with a short run.", "Use a small lift rather than a forward kick.", "If you start chasing, catch or reset and begin again."],
              practiceCues: ["Let's keep it close. Start with just a few touches.", "If you are chasing the ball, reset. Try a smaller lift.", "One more short run. Focus on where the ball goes."], easierID: "two-touch"),
        .init(id: "other-foot-rhythm", level: .control, title: "Give both feet a voice.",
              summary: "Build a little rhythm on your less confident side.", motion: .otherFoot,
              target: "Try 3 short runs on your less comfortable foot", cue: "A small run on your other side.",
              steps: ["Choose your less comfortable foot.", "Try two controlled touches before adding a third.", "Return to touch-and-catch whenever you need."],
              practiceCues: ["Try a short run on your other foot.", "Two controlled touches are a useful start. Keep it manageable.", "Try again. A catch between attempts is completely fine."], easierID: "other-foot-catch"),
        .init(id: "low-touches", level: .control, title: "Little lifts.",
              summary: "Explore a lower, more compact rhythm.", motion: .lowTouches,
              target: "Try 3 short runs with smaller lifts", cue: "Less force. Stay ready for the next touch.",
              steps: ["Begin at your usual comfortable height.", "Make the next few lifts a little smaller.", "Reset if the faster rhythm becomes uncomfortable."],
              practiceCues: ["Start comfortably. Now try a slightly smaller lift.", "Stay ready for the next touch. Reset if it feels rushed.", "Try another short run. Small and comfortable."], easierID: "keep-close"),
        .init(id: "change-height", level: .advanced, title: "Change the height.",
              summary: "Choose a higher touch, then return to your rhythm.", motion: .changeHeight,
              target: "Try a higher touch followed by a controlled lower touch", cue: "Lift a little higher. Then settle back in.",
              steps: ["Begin with a steady, comfortable rhythm.", "Make one deliberate, slightly higher lift.", "Let it return, then try a smaller touch. Reset as needed."],
              practiceCues: ["Start with your usual rhythm. Try one slightly higher lift.", "Watch it come back. Return to a smaller touch.", "Try the change again. Keep it within a comfortable height."], easierID: "steady-five"),
        .init(id: "move-with-ball", level: .advanced, title: "Take it with you.",
              summary: "Add one small sideways step to your control.", motion: .moving,
              target: "Try a short run with one small sideways step", cue: "One small step. Bring your rhythm along.",
              steps: ["Check you have clear space on both sides.", "Start a steady run, then shift one small step sideways.", "Settle again before trying another step."],
              practiceCues: ["Find your rhythm, then try one small sideways step.", "Settle your balance before moving again.", "Another try. Keep the step small and the ball within reach."], easierID: "keep-close"),
        .init(id: "foot-thigh", level: .advanced, title: "Foot, meet thigh.",
              summary: "Explore a new contact and return to your foot.", motion: .thigh,
              target: "Try one foot-to-thigh transition, then reset", cue: "Lift toward your thigh. Give it a soft landing.",
              steps: ["Lift the ball toward your thigh with a controlled foot touch.", "Raise your thigh to meet it, using the thigh rather than the kneecap.", "Try returning to a foot touch, or catch and reset."],
              practiceCues: ["Try a controlled lift toward your thigh. Catch if you need.", "Use the broad part of your thigh, away from your kneecap.", "Try the transition again. Keep it comfortable."], easierID: "change-height")
    ]

    static func lesson(_ id: String) -> LearnLesson { all.first { $0.id == id } ?? all[1] }
}
