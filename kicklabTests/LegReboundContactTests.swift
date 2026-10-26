import Foundation
import Testing
@testable import kicklab

struct LegReboundContactTests {
    private final class Resources {}
    private struct Row: Decodable {
        struct View: Decodable {
            var timestampMs: Int
            var ball: [Double]
            var joints: [BodyJoint: [Double]]
            var landmarks: [BodyJoint: [Double]]
            var ankles: [BodySide: [Double]]
            var sample: FootPoseSample {
                .init(pose: .init(timestampMs: timestampMs, ball: .init(x:ball[0],y:ball[1]),
                    width:ball[2], height:ball[3], confidence:ball[4], imageAspect:ball[5],
                    joints:joints.mapValues { .init(x:$0[0],y:$0[1]) }),
                    ankles:ankles.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) },
                    landmarks:landmarks.mapValues { .init(x:$0[0],y:$0[1],confidence:$0[2]) })
            }
        }
        let id, contact: String
        let contactMs: Int
        var samples: [View]
    }
    private func rows() throws -> [Row] {
        let url = try #require(Bundle(for:Resources.self).url(forResource:"leg-rebound-device-contacts",withExtension:"json"))
        return try JSONDecoder().decode([Row].self,from:Data(contentsOf:url))
    }
    private func selected(_ row: Row) -> [FootPoseSample] {
        let stamps = row.samples.enumerated().map { ContactFrameWindow.Stamp(index:$0.offset,timestampMs:$0.element.timestampMs) }
        guard let center = stamps.first(where: { $0.timestampMs == row.contactMs }) else { return [] }
        let selected = ContactFrameWindow.reboundIndices(stamps,around:center)
        return row.samples.enumerated().filter { selected.contains($0.offset) }.map { $0.element.sample }
    }
    private func recovered(_ row: Row) -> Int? {
        let samples = selected(row)
        return ObservedLegContactRules.contactTime(samples,at:row.contactMs,usesTemporalEvidence:true,usesCadenceWindow:true)
            ?? RaisedKneeReboundRules.contactTime(samples,at:row.contactMs)
    }

    @Test func realSparseFootAndCroppedKneeImpactsRecoverAtObservedExposures() throws {
        let expected = ["user900-064":100,"user900-082":50,"user900-118":0,"user900-121":50,"user900-123":50]
        for row in try rows() {
            let time = recovered(row)
            #expect(time.map { $0-row.contactMs } == expected[row.id], "\(row.id)")
            if let time { #expect(row.samples.contains { $0.timestampMs == time }) }
        }
        // The remaining foot has no reliable impact leg. Hands being unclear
        // must not turn that missing evidence into an invented contact.
        let unresolved = try #require(try rows().first { $0.id == "user900-129" })
        #expect(recovered(unresolved) == nil)
    }

    @Test func imageSupportKeepsTheReviewedLegAndUncertainContactVerdicts() throws {
        for row in try rows() {
            let samples = selected(row)
            let current = ObservedLegContactRules.contactTime(samples, at: row.contactMs,
                usesTemporalEvidence: true, usesCadenceWindow: true,
                allowsNearSupportFoot: true, usesImageSupport: true)
                ?? RaisedKneeReboundRules.contactTime(samples, at: row.contactMs)
                ?? RaisedFootReboundRules.contactTime(samples, at: row.contactMs)
            #expect(current == recovered(row), "\(row.id)")
        }
    }

    @Test func bothFeetAndBothSidesOfAnkleUseTheSameReach() throws {
        for row in try rows().filter({ ["user900-064","user900-082"].contains($0.id) }) {
            let expected = try #require(recovered(row))
            var otherEdge = row
            // Reflect ball position about the measured kicking ankle. This
            // checks image-space inside/outside reach, not a new 3D foot label.
            otherEdge.samples = row.samples.map { view in
                var s = view
                if let ankle = s.landmarks[.leftAnkle] { s.ball[0] = 2*ankle[0]-s.ball[0] }
                return s
            }
            #expect(recovered(otherEdge) == expected)
            for original in [row,otherEdge] {
                var mirrored = original
                func opposite(_ joint: BodyJoint) -> BodyJoint {
                    BodyJoint(rawValue: joint.rawValue.replacingOccurrences(of:"left_",with:"swap_")
                        .replacingOccurrences(of:"right_",with:"left_").replacingOccurrences(of:"swap_",with:"right_"))!
                }
                func reflect(_ values: [Double]) -> [Double] { var v = values; v[0] = 1-v[0]; return v }
                mirrored.samples = original.samples.map { view in
                    var s = view; s.ball[0] = 1-s.ball[0]
                    s.landmarks = Dictionary(uniqueKeysWithValues:s.landmarks.map { (opposite($0.key),reflect($0.value)) })
                    s.joints = Dictionary(uniqueKeysWithValues:s.joints.map { (opposite($0.key),reflect($0.value)) })
                    s.ankles = Dictionary(uniqueKeysWithValues:s.ankles.map { ($0.key.opposite,reflect($0.value)) })
                    return s
                }
                #expect(recovered(mirrored) == expected)
            }
        }
    }

    @Test(arguments:["missingLegs","weakLegs","stationary","singlePoseSpike","stale","floor"])
    func uncertaintyAndFloorCannotBecomePositiveLegEvidence(change: String) throws {
        for original in try rows().filter({ ["user900-064","user900-082","user900-118","user900-121","user900-123"].contains($0.id) }) {
            var row = original
            let impactTime = try #require(recovered(row))
            let reference = try #require(row.samples.first { $0.timestampMs == impactTime })
            let before = try #require(row.samples.first)
            row.samples = row.samples.map { view in
                var s = view
                if change == "missingLegs" { s.landmarks = s.landmarks.filter { !$0.key.rawValue.contains("knee") && !$0.key.rawValue.contains("ankle") } }
                if change == "weakLegs" { s.landmarks = s.landmarks.mapValues { [$0[0],$0[1],0.29] } }
                if change == "stationary" { s.landmarks = reference.landmarks }
                if change == "singlePoseSpike", s.timestampMs != impactTime { s.landmarks = before.landmarks }
                if change == "stale" { s.timestampMs = row.contactMs+(s.timestampMs-row.contactMs)*3 }
                if change == "floor" { s.ball[1] = 0.99 }
                return s
            }
            #expect(recovered(row) == nil, "\(row.id), \(change)")
        }
    }

    @Test func approachWithoutObservedReleaseCannotCount() throws {
        for original in try rows().filter({ ["foot","knee"].contains($0.contact) }) {
            var row = original
            row.samples.removeAll { $0.timestampMs > row.contactMs }
            #expect(recovered(row) == nil)
        }
    }

    @Test func millisecondRoundingDoesNotEraseSparseImpactAndRelease() throws {
        var row = try #require(try rows().first { $0.id == "user900-064" })
        // A nominal 10 fps sequence can have a 101 ms step after quantizing
        // original capture timestamps to integer milliseconds.
        row.samples = row.samples.map { view in
            var s = view
            if s.timestampMs > row.contactMs { s.timestampMs += 1 }
            return s
        }
        #expect(recovered(row) == row.contactMs+101)
    }

    @Test(arguments:[10,15,20,30,60,120])
    func windowUsesOnlyArrivedFramesAndStaysBounded(fps: Int) {
        let stamps = (0...fps*2).map { ContactFrameWindow.Stamp(index:$0,timestampMs:Int((Double($0)*1000/Double(fps)).rounded())) }
        let center = stamps[fps]
        let selected = ContactFrameWindow.reboundIndices(stamps,around:center)
        let offsets = stamps.filter { selected.contains($0.index) }.map { $0.timestampMs-center.timestampMs }
        #expect(selected.count <= 9)
        #expect(offsets.contains { $0 <= -150 })
        #expect(offsets.contains { $0 >= 150 })
        #expect(offsets.allSatisfy { (-200...200).contains($0) })
        let arrived = Array(stamps.prefix(fps+2))
        #expect(ContactFrameWindow.reboundIndices(arrived,around:center).isSubset(of:Set(arrived.map(\.index))))
    }
}
