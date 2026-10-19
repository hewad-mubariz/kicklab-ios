import Testing
@testable import kicklab

struct ContactRecheckPolicyTests {
    @Test func aFourExposureImpactGapCanBeMeasuredWithoutExtendingTheDeadline() {
        let policy = ContactRecheckPolicy()
        // Original 22.31s foot contact: the last tracked ball preceded it by
        // 133ms; the next independently observed ball arrived 34ms afterward.
        #expect(policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.139, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.751, due: 100, lastSource: 21.8, lastWall: 99.5))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.473, now: 100.4, due: 100, lastSource: 22.2, lastWall: 100.3))
        #expect(!policy.permits(source: 22.306, before: 22.173, after: 22.340,
            arrived: 22.32, now: 100.4, due: 100, lastSource: 21.8, lastWall: 99.5))
    }
}
