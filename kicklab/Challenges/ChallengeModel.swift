import Combine
import Foundation
import SwiftUI

/// One entry of the 60-challenge catalogue. Rules describe the intended judging; only
/// counted streaks are judged automatically today (see `Judging`).
struct JuggleChallenge: Identifiable, Hashable {
    enum Group: String, CaseIterable, Identifiable {
        case streaks, tricks, oneFoot, footwork, timed, speed, rounds, friends
        var id: String { rawValue }

        /// The groups that have a path; friend formats live in the friend row instead.
        static let paths: [Group] = [.streaks, .tricks, .oneFoot, .footwork, .timed, .speed, .rounds]

        var title: LocalizedStringKey {
            switch self {
            case .streaks: "Streaks"
            case .tricks: "Tricks"
            case .oneFoot: "One foot"
            case .footwork: "Footwork"
            case .timed: "Timed"
            case .speed: "Speed"
            case .rounds: "Rounds"
            case .friends: "Friends"
            }
        }

        var about: LocalizedStringKey {
            switch self {
            case .streaks: "Touches in a row. A hand, a catch or the ground ends the streak."
            case .tricks: "Freestyle tricks. You check these on your replay for now."
            case .oneFoot: "One foot only. You check these on your replay for now."
            case .footwork: "Follow a left and right pattern. You check these on your replay for now."
            case .timed: "The clock starts at Go and never pauses."
            case .speed: "Get there fast. Time runs from Go."
            case .rounds: "Three rounds with a rest between them."
            case .friends: "Same rules for both of you. Play at different times."
            }
        }
    }

    enum Level: Int {
        case starter = 1, build, advanced, expert
        var title: LocalizedStringKey {
            switch self {
            case .starter: "Starter"
            case .build: "Build"
            case .advanced: "Advanced"
            case .expert: "Expert"
            }
        }
    }

    enum Side: String { case left, right, weaker }

    enum FriendFormat: String {
        case streakDuel, sprintDuel, firstToTwenty, bestOfThree, mirrorMe, weakFootFaceoff, teamHundred, consistencyDuel
    }

    enum Rule: Hashable {
        case streak(target: Int)
        case beatYourBest
        case oneFoot(Side, target: Int)
        case pattern(String, repeats: Int)
        case bestStreak(seconds: Int)
        case sprint(seconds: Int)
        case keepItUp(seconds: Int)
        case inTime(target: Int, seconds: Int)
        case race(target: Int, seconds: Int)
        case series([Int])
        case steady(seconds: Int, minimum: Int)
        /// Around the world: the foot circles the ball while it is in the air.
        case aroundTheWorld(count: Int)
        case friend(FriendFormat)
    }

    enum Judging {
        /// The camera's counted streak decides it.
        case autoCounted
        /// The app counts touches; the player checks the technique on the replay.
        case practice
        /// Needs the timed-round engine, which isn't built yet.
        case timerComing
        case friendMatch
        case checkedTogether

        var label: LocalizedStringKey {
            switch self {
            case .autoCounted: "Auto-counted"
            case .practice: "Practice"
            case .timerComing: "Timer coming"
            case .friendMatch: "Friend match"
            case .checkedTogether: "Checked together"
            }
        }

        var detail: LocalizedStringKey {
            switch self {
            case .autoCounted: "The camera counts your streak, the same way as a normal session."
            case .practice: "The app counts your touches. You check your feet on the replay, then mark it done."
            case .timerComing: "The round timer isn’t in the app yet. For now this opens a normal session."
            case .friendMatch: "Same rules and the same number of tries for both of you."
            case .checkedTogether: "You both watch the shared video and agree on the result."
            }
        }

        var symbol: String {
            switch self {
            case .autoCounted: "video"
            case .practice: "eye"
            case .timerComing: "stopwatch"
            case .friendMatch, .checkedTogether: "person.2"
            }
        }
    }

    let number: Int
    let title: String
    let group: Group
    let level: Level
    let rule: Rule
    let objective: String

    var id: String { String(format: "%02d", number) }

    static func with(id: String) -> JuggleChallenge? { catalogue.first { $0.id == id } }
    static func path(_ group: Group) -> [JuggleChallenge] { catalogue.filter { $0.group == group } }
    static var friendFormats: [JuggleChallenge] { path(.friends) }

    var judging: Judging {
        switch rule {
        case .streak, .beatYourBest: .autoCounted
        // Around the world switches to .autoCounted once its detector is ready.
        case .oneFoot, .pattern, .series, .aroundTheWorld: .practice
        case .bestStreak, .sprint, .keepItUp, .inTime, .race, .steady: .timerComing
        case .friend(.mirrorMe), .friend(.weakFootFaceoff): .checkedTogether
        case .friend: .friendMatch
        }
    }

    /// The camera goal for Try solo; nil opens a normal session.
    func cameraTarget(best: Int) -> Int? {
        switch rule {
        case .streak(let target), .oneFoot(_, let target), .inTime(let target, _), .race(let target, _): target
        case .beatYourBest: best + 1
        case .pattern(let pattern, let repeats): pattern.count * repeats
        case .series(let rounds): rounds.first
        default: nil
        }
    }

    /// Short text inside the cup.
    func mark(best: Int) -> String {
        switch rule {
        case .streak(let target): "\(target)"
        case .beatYourBest: "\(best + 1)"
        case .oneFoot(let side, let target): "\(side.letter)\(target)"
        case .pattern(let pattern, _): pattern
        case .bestStreak(let s), .sprint(let s), .keepItUp(let s): "\(s)s"
        case .inTime(let target, let seconds): "\(target) in \(seconds)"
        case .race(let target, _): "\(target)"
        case .series(let rounds): rounds.map(String.init).joined(separator: "·")
        case .steady(let seconds, _): "3×\(seconds)s"
        case .aroundTheWorld(let count): count == 1 ? "ATW" : "\(count)× ATW"
        case .friend(let format): format.mark
        }
    }

    /// One plain sentence for the card under a cup.
    func line(best: Int) -> String {
        switch rule {
        case .streak(let target): "Reach \(target) touches in a row."
        case .beatYourBest: best > 0 ? "One more than your best of \(best)." : "Start with 3 in a row."
        case .oneFoot(let side, let target): "\(target) in a row, \(side.rawValue) foot only."
        case .pattern(let pattern, let repeats):
            "\(pattern.count * repeats) touches: \(pattern.map(String.init).joined(separator: " ")), \(repeats) times."
        case .bestStreak(let s): "Your longest streak inside \(s) seconds."
        case .sprint(let s): "Most touches in \(s) seconds."
        case .keepItUp(let s): "One streak, kept up for \(s) seconds."
        case .inTime(let target, let seconds): "\(target) in a row within \(seconds) seconds."
        case .race(let target, _): "Race to \(target) in a row. Fastest time wins."
        case .series(let rounds): "Three streaks: \(rounds.map(String.init).joined(separator: ", "))."
        case .steady(let seconds, let minimum): "Three \(seconds)-second rounds, \(minimum)+ in each."
        case .aroundTheWorld(let count):
            count == 1 ? "Land your first around the world." : "\(count) around the worlds in a row, in one streak."
        case .friend(let format): format.line
        }
    }

    var timeNote: String? {
        switch rule {
        case .bestStreak(let s), .sprint(let s): "A 3-second countdown, then \(s) seconds. The clock never pauses."
        case .keepItUp(let s): "Runs from your first touch. Keep the same streak past \(s) seconds."
        case .inTime(_, let s): "A 3-second countdown, then \(s) seconds to get there."
        case .race(_, let s): "A 3-second countdown, then up to \(s) seconds. Lowest time is best."
        case .steady(let s, _): "Three \(s)-second rounds with a rest between them."
        default: nil
        }
    }

    /// The friend format that plays this solo rule head to head, when there is one.
    var friendVersion: JuggleChallenge? {
        switch number {
        case 28: JuggleChallenge.with(id: "53")
        case 32: JuggleChallenge.with(id: "54")
        case 42: JuggleChallenge.with(id: "55")
        default: nil
        }
    }

    /// Sizes the cup on the path: harder challenges are bigger.
    var cupRadius: CGFloat {
        switch level {
        case .starter: 34
        case .build: 38
        case .advanced: 42
        case .expert: 47
        }
    }
}

extension JuggleChallenge.Side {
    var letter: String {
        switch self {
        case .left: "L"
        case .right: "R"
        case .weaker: "W"
        }
    }
}

extension JuggleChallenge.FriendFormat {
    var mark: String { self == .teamHundred ? "100" : self == .mirrorMe ? "L·R" : "VS" }

    var shortName: LocalizedStringKey {
        switch self {
        case .streakDuel: "Streak duel"
        case .sprintDuel: "Sprint duel"
        case .firstToTwenty: "First to 20"
        case .bestOfThree: "Best of 3"
        case .mirrorMe: "Mirror me"
        case .weakFootFaceoff: "Weak foot"
        case .teamHundred: "Team 100"
        case .consistencyDuel: "Steady duel"
        }
    }

    var symbol: String {
        switch self {
        case .streakDuel: "flame"
        case .sprintDuel: "stopwatch"
        case .firstToTwenty: "flag.checkered"
        case .bestOfThree: "3.circle"
        case .mirrorMe: "arrow.left.arrow.right"
        case .weakFootFaceoff: "shoe"
        case .teamHundred: "person.2"
        case .consistencyDuel: "chart.bar"
        }
    }

    var line: String {
        switch self {
        case .streakDuel: "Best streak in 30 seconds. Three tries each."
        case .sprintDuel: "Most touches in 30 seconds. Three tries each."
        case .firstToTwenty: "Fastest to 20 in a row. Three tries each."
        case .bestOfThree: "Three 30-second rounds. Win the most rounds."
        case .mirrorMe: "Set 8 left and right touches. Your friend copies them."
        case .weakFootFaceoff: "10 in a row with your weaker foot. You can both win."
        case .teamHundred: "Reach 100 touches together. Best 30-second try each."
        case .consistencyDuel: "Three 20-second rounds. Your weakest round counts."
        }
    }

    var isTeam: Bool { self == .teamHundred }
    var lowestWins: Bool { self == .firstToTwenty }
}

/// What the player has finished. Streak goals come from the recorded best; practice
/// goals are marked done by the player after checking the replay.
@MainActor
final class ChallengeProgress: ObservableObject {
    static let shared = ChallengeProgress()
    private static let markedKey = "kicklab.challenges.marked"
    private static let ballKey = "kicklab.challenges.ballAt"

    @Published private(set) var marked: Set<String>
    /// Review fixtures keep progress in memory so a test run never changes real progress.
    private let persists = !ProcessInfo.processInfo.arguments.contains("--history-review")
    private var spots: [String: String]

    private init() {
        marked = persists ? Set(UserDefaults.standard.stringArray(forKey: Self.markedKey) ?? []) : []
        spots = persists ? (UserDefaults.standard.dictionary(forKey: Self.ballKey) as? [String: String]) ?? [:] : [:]
    }

    /// For the around-the-world detector: the most around the worlds landed in a row in one
    /// streak. Marks every Tricks challenge that count reaches.
    func recordAroundTheWorlds(inARow count: Int) {
        for challenge in JuggleChallenge.path(.tricks) {
            if case .aroundTheWorld(let needed) = challenge.rule, count >= needed, !marked.contains(challenge.id) {
                mark(challenge, done: true)
            }
        }
    }

    func isDone(_ challenge: JuggleChallenge, best: Int) -> Bool {
        switch challenge.rule {
        case .streak(let target): best >= target
        default: marked.contains(challenge.id)
        }
    }

    func mark(_ challenge: JuggleChallenge, done: Bool) {
        if done { marked.insert(challenge.id) } else { marked.remove(challenge.id) }
        if persists { UserDefaults.standard.set(Array(marked).sorted(), forKey: Self.markedKey) }
    }

    /// Where the ball sat on each path the last time it was shown, so a new finish can hop it on.
    func ballSpot(for group: JuggleChallenge.Group) -> String? { spots[group.rawValue] }

    func setBallSpot(_ id: String, for group: JuggleChallenge.Group) {
        guard spots[group.rawValue] != id else { return }
        spots[group.rawValue] = id
        if persists { UserDefaults.standard.set(spots, forKey: Self.ballKey) }
    }
}
