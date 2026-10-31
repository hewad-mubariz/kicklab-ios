import Foundation

@main struct PoseEmptyFallbackContracts {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool) throws {
            guard value else { throw NSError(domain: "PoseEmptyFallbackContract", code: checks) }
            checks += 1
        }
        let box = PersonBox(x: 0.5, y: 0.5, width: 0.4, height: 0.6)
        let player = ActivePlayerSelection(state: .locked, id: 1, box: box, observed: true, peopleCount: 1)
        func permits(_ enabled: Bool = true, revision2: Bool = true, count: Int = 0,
                     selection: ActivePlayerSelection? = player) -> Bool {
            PoseEmptyFallbackPolicy.permits(enabled: enabled, revision2: revision2, rawPoseCount: count, player: selection)
        }
        try check(!PoseEmptyFallbackPolicy.enabled(arguments: []))
        #if DEBUG
        try check(PoseEmptyFallbackPolicy.enabled(arguments: ["--pose-empty-legacy-fallback-v1"]))
        #else
        try check(!PoseEmptyFallbackPolicy.enabled(arguments: ["--pose-empty-legacy-fallback-v1"]))
        #endif
        try check(permits())
        try check(!permits(false))
        try check(!permits(revision2: false))
        try check(!permits(count: 1))
        try check(!permits(count: 2))
        try check(!permits(count: -1))
        try check(!permits(selection: nil))
        for state in [ActivePlayerSelection.State.searching, .ambiguous] {
            try check(!permits(selection: .init(state: state, id: 1, box: box, observed: true, peopleCount: 2)))
        }
        try check(!permits(selection: .init(state: .locked, id: nil, box: box, observed: true, peopleCount: 1)))
        try check(!permits(selection: .init(state: .locked, id: 1, box: nil, observed: true, peopleCount: 1)))
        // A second detector's result still has to match the measured player.
        try check(ActivePlayerPoseMatcher.index(in: [BodyPose()], selection: player) == nil)
        print("PASS: \(checks) empty-pose eligibility and unchanged player-matching contracts")
    }
}
