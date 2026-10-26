import Foundation
import Testing
@testable import kicklab

struct ContactEvidenceReplayTests {
    private final class Resources {}
    // Reviewed source SHA-256 6a771df2a60ac140a21ea8840fd50208216db358d13917a7150a38cf0c623c63.
    // Actual device evidence: preserve all 31 reviewed kicks while removing the
    // two floor reversals. This does not annotate other possible missed touches.
    @Test func repairedImpactWindowsRemoveFloorCountsWithoutLosingReviewedKicks() throws {
        var traces: [CounterTrace] = []
        for arm in ["before", "after"] {
            let url = try #require(Bundle(for: Resources.self).url(forResource: "impact-window-v17-\(arm)", withExtension: "plist"))
            let trace = try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: url))
            #expect(trace.complete)
            #expect(try trace.replay() == trace.touches)
            traces.append(trace)
        }
        let before = Set(traces[0].touches.map(\.frameIndex))
        let after = Set(traces[1].touches.map(\.frameIndex))
        #expect(before.count == 33 && after.count == 31)
        #expect(before.subtracting(after) == Set([800, 842]))
        #expect(after.subtracting(before).isEmpty)
        let decisions = traces[1].decisions.map(\.value)
        #expect(decisions.first { $0.frameIndex == 800 }?.rejection == .groundBounce)
        #expect(decisions.first { $0.frameIndex == 842 }?.rejection == .unresolvedLowContact)
        for frame in [187, 204, 241, 292, 307, 1218, 1234] {
            #expect(after.contains(frame))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(traces[0].operations) == encoder.encode(traces[1].operations))
    }

    // Reviewed source SHA-256 536dc21ae695775e23ba35c38d5a035b0e82bebe386b6bbb5142d74a9731a912.
    // These share every trajectory input. The final sideways contact has no
    // candidate in those frozen inputs and remains outside this evidence test.
    @Test func sameTotalCanHaveDifferentAccuracy() throws {
        var traces: [CounterTrace] = []
        for arm in ["before", "after"] {
            let url = try #require(Bundle(for: Resources.self).url(forResource: "contact-evidence-v16-\(arm)", withExtension: "plist"))
            let trace = try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: url))
            #expect(try trace.replay() == trace.touches)
            #expect(trace.touches.count == 18)
            traces.append(trace)
            if arm == "after" {
                let accepted = Set(trace.touches.map(\.frameIndex))
                #expect(!accepted.contains(623) && !accepted.contains(700))
                #expect(accepted.contains(683) && accepted.contains(916))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(traces[0].operations) == encoder.encode(traces[1].operations))
    }
}
