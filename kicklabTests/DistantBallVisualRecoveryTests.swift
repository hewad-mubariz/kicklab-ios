import AVFoundation
import XCTest
@testable import kicklab

@MainActor
final class DistantBallVisualRecoveryTests: XCTestCase {
    private func frame(_ time:Double, recovered:Bool=false) -> RecordedFrame {
        RecordedFrame(time:time,x:0.5,y:0.5,width:0.025,height:0.014,score:0.8,
            smoothedX:0.5,smoothedY:0.5,vy:0,motion:.unknown,detected:true,person:nil,
            ballMask:BallMask(rect:CGRect(x:0.4875,y:0.493,width:0.025,height:0.014),
                width:10,height:10,alpha:Array(repeating:255,count:50)+Array(repeating:0,count:50)),
            usesBallMasks:true,isVisualRecovery:recovered)
    }
    private func archive(_ originals:[RecordedFrame], _ additions:[RecordedFrame]) -> StoredInference {
        StoredInference(frames:originals.map(StoredFrame.init),touches:[[1,0.02,0.5,0.5]],count:1,
            detections:originals.count,rejected:0,framesRead:100,duration:1,peak:0.8,model:"test",elapsed:0,
            visualRecoveries:additions.isEmpty ? nil : additions.map(StoredFrame.init))
    }

    func testRecoverySurvivesStorageWithoutEnteringCountedTrackOrStatistics() throws {
        let original=[frame(0),frame(0.04)], recovered=frame(0.02,recovered:true)
        let value=archive(original,[recovered])
        let encoder=PropertyListEncoder(); encoder.outputFormat = .binary
        let loaded=try PropertyListDecoder().decode(StoredInference.self,from:encoder.encode(value))
        XCTAssertTrue(loaded.isValid)
        XCTAssertEqual(loaded.frames.map(\.frame.time),[0,0.04])
        XCTAssertEqual(loaded.visualRecoveries?.map(\.frame.time),[0.02])
        XCTAssertEqual(loaded.visualRecoveries?.first?.frame.ballMask?.alpha,recovered.ballMask?.alpha)
        XCTAssertTrue(loaded.visualRecoveries?.first?.frame.isVisualRecovery == true)
        let summary=SessionSummary.make(touches:loaded.count,duration:1,bestCombo:1,personalBest:1,
            videoURL:URL(fileURLWithPath:"/test.mov"),touchesMarked:loaded.recordedTouches,track:loaded.frames.map(\.frame))
        var prepared=summary; prepared.visualTrack=(original+[recovered]).sorted{$0.time<$1.time}
        XCTAssertEqual(prepared.track.map(\.time),summary.track.map(\.time))
        XCTAssertEqual(prepared.touchesMarked,summary.touchesMarked)
        XCTAssertEqual(prepared.avgHeightMeters,summary.avgHeightMeters)
        XCTAssertEqual(prepared.renderTrack.count,3)
        let track=BallEffectTrack(frames:prepared.renderTrack,touchTimes:prepared.touchesMarked.map(\.time))
        XCTAssertEqual(track.samples.count,3,"Fresh visual detections extend trajectory, unlike repaired mattes")
        XCTAssertNotNil(track.mask(at:0.02))
        XCTAssertEqual(track.latestTouch(at:0.5),0.02)
    }

    func testLegacyArchivesDecodeAndMisclassifiedRecoveryCannotMasqueradeAsCounting() throws {
        let value=archive([frame(0)],[]),encoder=PropertyListEncoder()
        let data=try encoder.encode(value)
        let decoded=try PropertyListDecoder().decode(StoredInference.self,from:data)
        XCTAssertTrue(decoded.isValid);XCTAssertNil(decoded.visualRecoveries)
        XCTAssertFalse(decoded.frames[0].frame.isVisualRecovery)
        XCTAssertFalse(archive([frame(0,recovered:true)],[]).isValid)
        XCTAssertFalse(archive([frame(0)],[frame(0.02)]).isValid)
        var contradictory=frame(0.02,recovered:true);contradictory.isVisualMaskRepair=true
        XCTAssertFalse(StoredFrame(contradictory).isValid)
    }

    func testGapRepairNeitherReplacesFreshRecoveryNorUsesItAsAnAnchor() {
        let originals=[frame(0),frame(0.05)]
        XCTAssertEqual(BallMaskGapRefiner.requests(frames:originals,frameDuration:1.0/60).count,2)
        let withRecovery=originals+[frame(1.0/60,recovered:true)]
        let requests=BallMaskGapRefiner.requests(frames:withRecovery,frameDuration:1.0/60)
        XCTAssertEqual(requests.count,1)
        XCTAssertEqual(requests[0].time,2.0/60,accuracy:0.000001)
        XCTAssertFalse(requests[0].before.isVisualRecovery)
        XCTAssertFalse(requests[0].after.isVisualRecovery)
    }

    func testFeatureModesHaveSeparateCacheProvenanceAndDisableWins() {
        XCTAssertNotEqual(DistantBallVisualRecovery.signature(arguments:[]),
            DistantBallVisualRecovery.signature(arguments:["--distant-ball-recovery"]))
        XCTAssertEqual(DistantBallVisualRecovery.signature(arguments:["--distant-ball-recovery","--disable-distant-ball-recovery"]),"")
    }

    func testFreshRecoveryRemainsVisibleAtRoundedSegmentEndpointOnly() {
        let recovered=BallEffectTrack(frames:[frame(1,recovered:true)])
        XCTAssertNotNil(recovered.mask(at:1.0009))
        XCTAssertNotNil(recovered.replacementGuide(at:1.0009))
        XCTAssertNil(recovered.replacementGuide(at:1.0011))
        XCTAssertNil(recovered.replacementGuide(at:1.03))
        let original=BallEffectTrack(frames:[frame(1)])
        XCTAssertNil(original.replacementGuide(at:1.0009),"Preserve original-track sampling")
    }

    func testSustainedPolicyRequiresFreshEvidenceAndNeverExceedsOneAddedCall() {
        let policy=DistantBallRecoveryPolicy(),size=CGSize(width:720,height:1280)
        let ball=Detection(score:0.8,x:0.5,y:0.5,width:0.025,height:0.014)
        let mask=frame(0).ballMask!
        for t in [0.0,0.02] {_=policy.request(time:t,size:size,direct:ball,baselineCalls:1,sceneCut:false,kind:"detector")}
        XCTAssertNil(policy.request(time:0.03,size:size,direct:nil,baselineCalls:2,sceneCut:false,kind:"detector"))
        var count=0
        for t in stride(from:0.04,through:1.2,by:0.02) {
            if let q=policy.request(time:t,size:size,direct:nil,baselineCalls:1,sceneCut:false,kind:"detector") {
                XCTAssertTrue(policy.accept(FrameDetections(ball:ball,person:nil,ballMask:mask,usesBallMasks:true),request:q,time:t));count += 1
            }
        }
        XCTAssertGreaterThan(count,50)
        XCTAssertGreaterThan(policy.checkpoint ?? 0,0.9)
        XCTAssertNil(policy.request(time:1.22,size:size,direct:nil,baselineCalls:1,sceneCut:true,kind:"detector"))
    }
}
