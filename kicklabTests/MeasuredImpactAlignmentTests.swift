import Foundation
import Testing
@testable import kicklab
struct MeasuredImpactAlignmentTests {
    private final class Resources {}
    private func samples() throws -> [ContactPoseSample] {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"outdoor-late-impact-20261028",withExtension:"json"))
        return try JSONDecoder().decode([ContactPoseSample].self,from:Data(contentsOf:url))
    }
    @Test func measuredEarlierImpactKeepsItsOwnClearHandRequirement() throws {
        let s = try samples()
        #expect(ClearHandsContactRules.failure(s,at:17116) == .handsNearBall)
        #expect(MeasuredImpactAlignmentRules.contactTime(s,proposedMs:17116) == 17016)
        #expect(MeasuredImpactAlignmentRules.contactTime(s.filter { $0.timestampMs != 17016 },proposedMs:17116) == nil)
        #expect(MeasuredImpactAlignmentRules.contactTime(s.filter { $0.timestampMs <= 17016 },proposedMs:17116) == nil)
        #expect(MeasuredImpactAlignmentRules.contactTime(s,proposedMs:17216) == nil)
        let blocked=s.map { view in
            var joints=view.joints
            if view.timestampMs == 17016 { joints[.rightWrist]=view.ball }
            return ContactPoseSample(timestampMs:view.timestampMs,ball:view.ball,width:view.width,height:view.height,
                confidence:view.confidence,imageAspect:view.imageAspect,joints:joints)
        }
        #expect(MeasuredImpactAlignmentRules.contactTime(blocked,proposedMs:17116) == nil)
    }
}
