import Foundation
@testable import kicklab

/// SplitMix64, so a failing session can be replayed from its seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// One stretch between two counted touches, played through a simulated detector.
/// Detection rates start from what the phones measured: in play, the iPhone 11
/// found the ball on 87 to 100% of its 7 to 10 replies per second.
struct SimulatedGap {
    struct Detector: CustomStringConvertible {
        var repliesPerSecond: Double
        var ballRate: Double
        var personRate: Double
        /// False ball boxes per second. The worst run measured 2 in 3.5 s.
        var straysPerSecond: Double
        /// Chance per reply of the phone falling behind, for up to `longestStallMS`.
        var stallRate: Double
        var longestStallMS: Int
        /// Chance per reply of missing the ball in a run, for up to `longestBlindMS`.
        var blindRate: Double
        var longestBlindMS: Int
        var description: String {
            "\(repliesPerSecond) Hz, ball \(ballRate), person \(personRate), strays \(straysPerSecond)/s, stalls \(stallRate), blind \(blindRate)"
        }
    }
    enum SavedVideo { case sameDetector, unreadable, cleanView }

    var lengthMS: Int
    var ballOut: [ClosedRange<Int>] = []
    var personOut: [ClosedRange<Int>] = []
    var detector: Detector
    var savedVideo: SavedVideo = .sameDetector

    private func contains(_ ranges: [ClosedRange<Int>], _ time: Int) -> Bool { ranges.contains { $0.contains(time) } }

    func assess(using random: inout SeededGenerator) -> StreakVisibilityEvidence.Assessment {
        let startMS = 10_000
        var evidence = StreakVisibilityEvidence()
        let period = 1_000/detector.repliesPerSecond
        var time = Double(startMS)+Double.random(in: 0...period, using: &random)
        var blindUntil = 0.0
        while time < Double(startMS+lengthMS) {
            if detector.stallRate > 0, Double.random(in: 0..<1, using: &random) < detector.stallRate {
                time += Double(Int.random(in: 300...max(300, detector.longestStallMS), using: &random))
            }
            if detector.blindRate > 0, time >= blindUntil, Double.random(in: 0..<1, using: &random) < detector.blindRate {
                blindUntil = time+Double(Int.random(in: 100...max(100, detector.longestBlindMS), using: &random))
            }
            let offset = Int(time)-startMS
            guard offset < lengthMS else { break }
            let ballThere = !contains(ballOut, offset)
            let ball = ballThere && time >= blindUntil
                ? Double.random(in: 0..<1, using: &random) < detector.ballRate
                : Double.random(in: 0..<1, using: &random) < detector.straysPerSecond/detector.repliesPerSecond
            let person = !contains(personOut, offset) && Double.random(in: 0..<1, using: &random) < detector.personRate
            evidence.record(timeMS: Int(time), personVisible: person, ballVisible: ball)
            time += period*Double.random(in: 0.8...1.25, using: &random)
        }
        var saved = random
        let before = Double(startMS)/1000, after = Double(startMS+lengthMS)/1000
        return evidence.assess(touchTimes: [before, after], existingBoundaries: []) { window in
            guard savedVideo != .unreadable else { return [] }
            let clean = savedVideo == .cleanView
            return stride(from: window.startMS+250, to: window.endMS, by: 500).map { target in
                let offset = target-startMS
                let ball = !contains(ballOut, offset)
                    ? clean || Double.random(in: 0..<1, using: &saved) < detector.ballRate
                    : !clean && Double.random(in: 0..<1, using: &saved) < detector.straysPerSecond/detector.repliesPerSecond
                let person = !contains(personOut, offset)
                    && (clean || Double.random(in: 0..<1, using: &saved) < detector.personRate)
                return .init(timeMS: target, personVisible: person, ballVisible: ball)
            }
        }
    }
}

/// Sessions a player and a referee would both call one unbroken streak, and
/// sessions they would both call a stop.
enum StreakScenario: String, CaseIterable {
    // A valid streak: nothing may end it.
    case touchesMissedByTheCounter, highKick, twoHighKicksInARow, ballHiddenByTheBody, playerAtTheEdgeOfFrame,
         phoneFallingBehind, liveDetectorBlind, savedVideoUnreadable
    // A real stop.
    case ballGone, playerAndBallGone, playerGoneBallInView

    var isValidStreak: Bool {
        switch self {
        case .ballGone, .playerAndBallGone, .playerGoneBallInView: false
        default: true
        }
    }
    var expectedStops: Set<ContactReviewReason> {
        switch self {
        case .ballGone: [.ballOutOfView]
        case .playerAndBallGone: [.playerOutOfView, .ballOutOfView]
        case .playerGoneBallInView: [.playerOutOfView]
        default: []
        }
    }

    /// Ordinary phones, from an old one running warm to a fast one.
    static func detector(using random: inout SeededGenerator) -> SimulatedGap.Detector {
        .init(repliesPerSecond: [7, 8, 10, 15, 20, 30].randomElement(using: &random)!,
              ballRate: [0.75, 0.87, 0.95, 1].randomElement(using: &random)!,
              personRate: [0.9, 0.97, 1].randomElement(using: &random)!,
              straysPerSecond: [0, 0.1, 0.3, 0.6].randomElement(using: &random)!,
              stallRate: 0, longestStallMS: 0, blindRate: 0, longestBlindMS: 0)
    }

    func gap(using random: inout SeededGenerator) -> SimulatedGap {
        var detector = Self.detector(using: &random)
        switch self {
        case .touchesMissedByTheCounter:
            return .init(lengthMS: Int.random(in: 3_000...12_000, using: &random), detector: detector)
        case .highKick:
            // Up to 11 m high with the frame ending as low as 1.5 m: 2.78 s out of frame.
            let out = Self.timeOutOfFrameMS(height: Double.random(in: 3...11, using: &random),
                                            frameTop: Double.random(in: 1.5...3, using: &random))
            let leaves = Int.random(in: 150...500, using: &random)
            return .init(lengthMS: max(3_000, leaves+out+Int.random(in: 100...800, using: &random)),
                         ballOut: [leaves...leaves+out], detector: detector)
        case .twoHighKicksInARow:
            let first = Int.random(in: 1_500...2_400, using: &random), second = Int.random(in: 1_500...2_400, using: &random)
            let leaves = Int.random(in: 150...500, using: &random), between = Int.random(in: 1_200...2_000, using: &random)
            let back = leaves+first+between
            return .init(lengthMS: back+second+Int.random(in: 100...800, using: &random),
                         ballOut: [leaves...leaves+first, back...back+second], detector: detector)
        case .ballHiddenByTheBody:
            // The longest measured in 56 minutes was 1.57 s; this allows 2.5 s.
            let hidden = Int.random(in: 500...2_500, using: &random), from = Int.random(in: 200...1_000, using: &random)
            return .init(lengthMS: from+hidden+Int.random(in: 500...2_000, using: &random),
                         ballOut: [from...from+hidden], detector: detector)
        case .playerAtTheEdgeOfFrame:
            detector.personRate = Double.random(in: 0.5...0.8, using: &random)
            return .init(lengthMS: Int.random(in: 3_000...12_000, using: &random), detector: detector)
        case .phoneFallingBehind:
            detector.stallRate = 0.03
            detector.longestStallMS = 2_000
            return .init(lengthMS: Int.random(in: 3_000...12_000, using: &random), detector: detector)
        case .liveDetectorBlind:
            // Live misses it for a long time; the saved video shows it plainly.
            detector.blindRate = 0.2
            detector.longestBlindMS = 5_000
            return .init(lengthMS: Int.random(in: 4_000...10_000, using: &random), detector: detector, savedVideo: .cleanView)
        case .savedVideoUnreadable:
            detector.blindRate = 0.2
            detector.longestBlindMS = 5_000
            return .init(lengthMS: Int.random(in: 4_000...10_000, using: &random), detector: detector, savedVideo: .unreadable)
        case .ballGone:
            let from = Int.random(in: 100...800, using: &random), out = Int.random(in: 3_700...15_000, using: &random)
            return .init(lengthMS: from+out+Int.random(in: 100...800, using: &random), ballOut: [from...from+out], detector: detector)
        case .playerAndBallGone:
            let from = Int.random(in: 100...800, using: &random), out = Int.random(in: 3_700...15_000, using: &random)
            return .init(lengthMS: from+out+Int.random(in: 100...800, using: &random),
                         ballOut: [from...from+out], personOut: [from...from+out], detector: detector)
        case .playerGoneBallInView:
            let from = Int.random(in: 100...800, using: &random), out = Int.random(in: 3_700...15_000, using: &random)
            return .init(lengthMS: from+out+Int.random(in: 100...800, using: &random), personOut: [from...from+out], detector: detector)
        }
    }

    /// How long a ball kicked straight up stays above the top of the frame.
    static func timeOutOfFrameMS(height: Double, frameTop: Double) -> Int {
        guard height > frameTop else { return 0 }
        return Int(2*(2*(height-frameTop)/9.81).squareRoot()*1000)
    }
}
