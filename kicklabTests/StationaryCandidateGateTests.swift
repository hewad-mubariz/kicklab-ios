import CoreGraphics
import Testing
@testable import kicklab

struct StationaryCandidateGateTests {
    private func candidate(_ x: CGFloat, _ y: CGFloat, size: CGFloat = 40) -> AsyncBallCandidate {
        .init(query: 0, hit: FollowHit(rect: CGRect(x: x-size/2, y: y-size/2, width: size, height: size), score: 0.9))
    }

    @Test func versionOneKeepsFirstFrameAnchorsForTheWholeTake() {
        let gate = StationaryCandidateGate(version: 1)
        #expect(gate.eligible([candidate(100, 500)]).isEmpty)
        #expect(gate.eligible([candidate(300, 200)]).count == 1)
        #expect(gate.eligible([candidate(300, 200)]).count == 1)
        // The ball returns to its first-frame spot after leaving: still rejected in V1.
        #expect(gate.eligible([candidate(105, 505)]).isEmpty)
    }

    @Test func versionTwoReleasesAnAnchorNothingOccupiesAndKeepsAnOccupiedOne() {
        let gate = StationaryCandidateGate(version: 2)
        // Reply 0: a juggled ball at the feet and a spare ball on a sofa.
        #expect(gate.eligible([candidate(100, 500), candidate(600, 300)]).isEmpty)
        // Replies 1 and 2: the juggled ball is airborne; the sofa ball stays.
        #expect(gate.eligible([candidate(120, 300), candidate(600, 300)]).map { $0.hit.center.y } == [300])
        #expect(gate.eligible([candidate(110, 350), candidate(601, 301)]).map { $0.hit.center.x } == [110])
        // Reply 3: the ball is back at the feet. Its anchor is gone; the sofa anchor is not.
        let back = gate.eligible([candidate(102, 498), candidate(600, 300)])
        #expect(back.map { $0.hit.center.x } == [102])
        // One missed reply does not release the sofa anchor.
        _ = gate.eligible([candidate(102, 498)])
        #expect(gate.eligible([candidate(600, 300), candidate(102, 498)]).map { $0.hit.center.x } == [102])
    }

    @Test func versionTwoIsDefaultAndLegacyOverrideIsDebugOnly() {
        #expect(StationaryCandidateGate.version(arguments: []) == 2)
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-v2"]) == 2)
        #if DEBUG
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-v1"]) == 1)
        #else
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-v1"]) == 2)
        #endif
    }
}
