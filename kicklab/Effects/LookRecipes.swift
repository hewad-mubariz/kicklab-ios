import Foundation

/// One-tap ways to lay runs of looks across a clip, so nobody sets touches by hand.
nonisolated enum LookRecipe: String, CaseIterable, Identifiable, Sendable {
    case powerUp, finale, everyFive, remix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .powerUp: "Power-up"
        case .finale: "Finale"
        case .everyFive: "Every 5"
        case .remix: "Remix"
        }
    }

    var symbol: String {
        switch self {
        case .powerUp: "chart.line.uptrend.xyaxis"
        case .finale: "flag.checkered"
        case .everyFive: "repeat"
        case .remix: "shuffle"
        }
    }

    var caption: String {
        switch self {
        case .powerUp: "Levels up at 10, 25, 50 and 100 touches"
        case .finale: "Saves the big look for the last touches"
        case .everyFive: "A new look every 5 touches"
        case .remix: "A fresh mix; tap again to shuffle"
        }
    }
}

nonisolated enum LookRecipes {
    /// Each Power-up tier is louder than the one before.
    static let ladder: [TouchLook] = [
        TouchLook(ball: .volt, effect: .electric), TouchLook(ball: .lava, effect: .fire),
        TouchLook(ball: .gold, effect: .galaxy), TouchLook(ball: .chrome, effect: .rainbow),
        TouchLook(ball: .aurora, effect: .aura)
    ]
    static let rotation: [TouchLook] = [
        TouchLook(ball: .volt, effect: .neon), TouchLook(ball: .arctic, effect: .ice),
        TouchLook(ball: .crimson, effect: .flameRibbon)
    ]
    static let mix: [TouchLook] = [
        TouchLook(ball: .volt, effect: .electric), TouchLook(ball: .lava, effect: .fire),
        TouchLook(ball: .gold, effect: .galaxy), TouchLook(ball: .arctic, effect: .ice),
        TouchLook(ball: .chrome, effect: .neon), TouchLook(ball: .crimson, effect: .flameRibbon),
        TouchLook(ball: .aurora, effect: .aura), TouchLook(ball: .pearl, effect: .rainbow),
        TouchLook(ball: .matrix, effect: .glowTrail), TouchLook(ball: .stealth, effect: .blueFlame)
    ]
    static let finale = TouchLook(ball: .gold, effect: .fire)

    /// Older phones (iPhone 13 and earlier, SE): effects measured smooth on an iPhone 11, at most
    /// about 23 ms of GPU time per frame. Electric, Galaxy, Rainbow and Neon reach 31 to 46 ms there.
    static let lightLadder: [TouchLook] = [
        TouchLook(ball: .volt, effect: .glowTrail), TouchLook(ball: .lava, effect: .emberWake),
        TouchLook(ball: .gold, effect: .labFlame), TouchLook(ball: .crimson, effect: .fire),
        TouchLook(ball: .aurora, effect: .nature)
    ]
    static let lightRotation: [TouchLook] = [
        TouchLook(ball: .volt, effect: .emberWake), TouchLook(ball: .arctic, effect: .glowTrail),
        TouchLook(ball: .crimson, effect: .labFlame)
    ]
    static let lightMix: [TouchLook] = [
        TouchLook(ball: .volt, effect: .glowTrail), TouchLook(ball: .lava, effect: .fire),
        TouchLook(ball: .gold, effect: .labFlame), TouchLook(ball: .arctic, effect: .nature),
        TouchLook(ball: .chrome, effect: .heatPulse), TouchLook(ball: .crimson, effect: .emberWake),
        TouchLook(ball: .pearl, effect: .glowTrail), TouchLook(ball: .matrix, effect: .nature)
    ]

    /// Whether this phone should get the lighter recipes; the same split as the detector's.
    static var prefersLightEffects: Bool { RFDeviceProfile.current == .compact }

    static func ladder(lightweight: Bool) -> [TouchLook] { lightweight ? lightLadder : ladder }

    struct Result: Equatable, Sendable {
        /// Run starts (touch positions, never 0) to looks; the first run keeps the clip's own look.
        let changes: [Int: TouchLook]
        /// The change moment that suits the recipe.
        let moment: BallSwapEffect
    }

    static func make(_ recipe: LookRecipe, base: TouchLook, touchCount n: Int, seed: Int = 1,
                     lightweight: Bool = false) -> Result {
        let ladder = lightweight ? lightLadder : ladder
        let rotation = lightweight ? lightRotation : rotation
        let mix = lightweight ? lightMix : mix
        let moment: BallSwapEffect = switch recipe {
        case .powerUp: .burst
        case .finale: .lightning
        case .everyFive: .pop
        case .remix: .sparkle
        }
        guard n >= 2 else { return Result(changes: [:], moment: moment) }
        var changes: [Int: TouchLook] = [:]
        switch recipe {
        case .powerUp:
            // Milestones are touch numbers; the look changes on that touch. Short clips level up
            // at quarters instead, so every clip shows a few tiers.
            var marks = [10, 25, 50, 100, 150, 200].filter { $0 <= n - 2 }
            if marks.count < 2 { marks = Array(Set([n / 4, n / 2, 3 * n / 4].map { max(2, $0) })).sorted().filter { $0 <= n } }
            for (tier, mark) in marks.enumerated() {
                changes[mark - 1] = ladder[min(tier, ladder.count - 1)]
            }
        case .finale:
            let last = min(10, max(3, n / 5))
            changes[max(1, n - last)] = finale
        case .everyFive:
            let step = n >= 10 ? 5 : 2
            let cycle = rotation + [base]
            for (slot, index) in stride(from: step, to: n, by: step).enumerated() {
                changes[index] = cycle[slot % cycle.count]
            }
        case .remix:
            var random = SplitMix(seed: UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(n))
            let shortest = n >= 12 ? 3 : 1, longest = n >= 12 ? 6 : 2
            var index = shortest + Int(random.next() % UInt64(longest - shortest + 1))
            var previous = base
            while index < n {
                var look = mix[Int(random.next() % UInt64(mix.count))]
                if look == previous { look = mix[(mix.firstIndex(of: look)! + 1) % mix.count] }
                changes[index] = look
                previous = look
                index += shortest + Int(random.next() % UInt64(longest - shortest + 1))
            }
        }
        return Result(changes: changes, moment: moment)
    }

    /// A small deterministic generator: the same seed always gives the same Remix.
    struct SplitMix {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
