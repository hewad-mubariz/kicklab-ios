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
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-motion-v3"]) == 3)
        #else
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-v1"]) == 2)
        #expect(StationaryCandidateGate.version(arguments: ["--stationary-gate-motion-v3"]) == 2)
        #endif
    }

    @Test func shortObservedMotionReleasesOnlyTheMovingStartingSpot() {
        let old = StationaryCandidateGate(version: 2), moving = StationaryCandidateGate(version: 3)
        let positions: [(CGFloat, CGFloat)] = [(100,500),(94,526.1),(82.3,496.9),(74.5,513.1)]
        for (index, point) in positions.enumerated() {
            let detections = [candidate(point.0,point.1,size:100), candidate(600,300,size:100)]
            #expect(old.eligible(detections,at:Double(index)*0.1).isEmpty)
            let result = moving.eligible(detections,at:Double(index)*0.1)
            #expect(result.count == (index == 3 ? 1 : 0))
            #expect(!result.contains { $0.hit.center.x == 600 })
        }
        #expect(moving.eligible([candidate(100,500,size:100),candidate(600,300,size:100)],at:0.4).count == 1)
    }

    @Test func stationaryJitterNeverAccumulatesIntoMotion() {
        let gate = StationaryCandidateGate(version: 3)
        for index in 0..<1000 {
            let offset = CGFloat(index % 3 - 1) * 4
            #expect(gate.eligible([candidate(100+offset,500-offset,size:100)],at:Double(index)*0.1).isEmpty)
        }
    }
}
