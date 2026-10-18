import AVFoundation
import XCTest
@testable import kicklab

final class SelectiveEffectsTests: XCTestCase {
    private func frame(_ t:Double,_ x:Double = 0.5,_ score:Double = 0.9) -> RecordedFrame {
        RecordedFrame(time:t,x:x,y:0.5,width:0.1,height:0.1,score:score,smoothedX:x,smoothedY:0.5,
            vy:0,motion:.unknown,detected:true,person:nil,
            identity:RecordedFrameIdentity(index:Int(t*60),time:CMTime(seconds:t,preferredTimescale:60000),
                width:720,height:1280,coordinates:"capture-buffer; normalized upright detector coordinates"))
    }
    func testHealthyShortIntervalsAreRetainedAndLongGapsAreRepaired() {
        let healthy = (0...30).map { frame(Double($0)/30) }
        XCTAssertTrue(SelectiveEffectTrack.eligible(healthy))
        XCTAssertTrue(SelectiveEffectTrack.plan(frames:healthy,duration:1).spans.isEmpty)
        let gap = healthy.filter { $0.time < 0.4 || $0.time > 0.65 }
        let plan = SelectiveEffectTrack.plan(frames:gap,duration:1)
        XCTAssertTrue(plan.contains(0.5));XCTAssertFalse(plan.contains(0.1));XCTAssertFalse(plan.contains(0.9))
    }
    func testLowConfidenceAndIsolatedJumpAreRecheckedWithoutBridgingAbsence() {
        var frames = (0...30).map { frame(Double($0)/30) }
        frames[10] = frame(10.0/30,0.5,0.42)
        frames[22] = frame(22.0/30,0.8)
        let plan = SelectiveEffectTrack.plan(frames:frames,duration:1)
        XCTAssertTrue(plan.contains(10.0/30));XCTAssertTrue(plan.contains(22.0/30))
        let missing = SelectiveEffectTrack.plan(frames:[frame(0.2),frame(0.8)],duration:1)
        XCTAssertTrue(missing.contains(0));XCTAssertTrue(missing.contains(1));XCTAssertTrue(missing.contains(0.5))
    }
    func testMissingOrShiftedIdentityCannotReuseCapturePositions() {
        var f = frame(0.2);f.identity=nil;XCTAssertFalse(SelectiveEffectTrack.eligible([f]))
        f=frame(0.2);f.identity=frame(0.3).identity;XCTAssertFalse(SelectiveEffectTrack.eligible([f]))
    }
    func testInheritedHighScoreDoesNotHideTrackerDrift() {
        let frames = [frame(0,0.5,0.98),frame(0.033,0.5,0.98),frame(0.067,0.5,0.98),
                      frame(0.1,0.5,0.98),frame(0.133,0.6,0.97)]
        let plan = SelectiveEffectTrack.plan(frames:frames,duration:0.133)
        XCTAssertEqual(plan.rejectedTimes,Set([0.033,0.067,0.1]))
        let linear = [frame(0,0.5,0.98),frame(0.033,0.525,0.98),frame(0.067,0.55,0.98),
                      frame(0.1,0.575,0.98),frame(0.133,0.6,0.97)]
        XCTAssertTrue(SelectiveEffectTrack.plan(frames:linear,duration:0.133).rejectedTimes.isEmpty)
    }
    func testEmptyQueryRetriesAdjacentFramesButStopsOnSuccessOrBudget() {
        var q = SelectiveEffectTrack.QueryCursor([0.1])
        XCTAssertTrue(q.take(at:0.1,allowRetry:true))
        XCTAssertTrue(q.take(at:7.0/60,allowRetry:true))
        q.accepted()
        XCTAssertFalse(q.take(at:8.0/60,allowRetry:true))
        q = SelectiveEffectTrack.QueryCursor([0.1])
        XCTAssertTrue(q.take(at:0.1,allowRetry:true))
        XCTAssertTrue(q.take(at:7.0/60,allowRetry:true))
        XCTAssertTrue(q.take(at:8.0/60,allowRetry:true))
        XCTAssertFalse(q.take(at:9.0/60,allowRetry:true))
        q = SelectiveEffectTrack.QueryCursor([0.1])
        XCTAssertTrue(q.take(at:0.1,allowRetry:false))
        XCTAssertFalse(q.take(at:7.0/60,allowRetry:false))
    }
    func testShortGapAroundDirectionChangeGetsFreshInteriorObservations() {
        let kick = [frame(0,0.4,0.91),frame(0.05,0.5,0.92),
                    frame(0.15,0.5,0.93),frame(0.2,0.4,0.94)]
        let plan = SelectiveEffectTrack.plan(frames:kick,duration:0.2)
        XCTAssertTrue(plan.queries.contains { $0 > 0.05 && $0 < 0.10 })
        XCTAssertTrue(plan.queries.contains { $0 > 0.10 && $0 < 0.15 })
        XCTAssertTrue(plan.rejectedTimes.isEmpty)
        let linear = [frame(0,0.4,0.91),frame(0.05,0.45,0.92),
                      frame(0.15,0.55,0.93),frame(0.2,0.6,0.94)]
        XCTAssertTrue(SelectiveEffectTrack.plan(frames:linear,duration:0.2).queries.isEmpty)
    }
    @MainActor func testDenseRequestCannotReusePositionOnlySummary() async throws {
        let url = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"capture-mask-vfr",withExtension:"mov"))
        var summary = SessionSummary.make(touches:3,duration:1,bestCombo:3,personalBest:3,videoURL:url,
            touchesMarked:[RecordedTouch(index:0,time:0.2,x:0.5,y:0.5)],track:[frame(0.2)])
        summary.framesUseCompositionClock=true;summary.visualTrack=[frame(0.2)]
        summary.visualTrackIsPositionsOnly=true
        let preparation = SessionEffectsPreparation()
        let fire = try await preparation.prepare(summary,for:.init(style:.fire))
        XCTAssertTrue(fire.visualTrackIsPositionsOnly)
        let gold = try await preparation.prepare(fire,for:.init(style:.none,ballSkin:.gold))
        XCTAssertFalse(gold.visualTrackIsPositionsOnly);XCTAssertEqual(gold.touchesMarked,summary.touchesMarked)
    }
}
