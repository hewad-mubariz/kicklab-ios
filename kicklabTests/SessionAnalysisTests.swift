import AVFoundation
import simd
import XCTest
@testable import kicklab

final class SessionAnalysisTests: XCTestCase {
    private actor Calls {
        var count = 0
        func increment() { count += 1 }
    }
    private func frame() -> RecordedFrame {
        var f = RecordedFrame(time:0.016, x:0.4,y:0.6,width:0.1,height:0.07,score:0.93,
            smoothedX:0.42,smoothedY:0.58,vy:-0.2,motion:.rising,detected:true,
            person:PersonBox(x:0.5,y:0.4,width:0.6,height:0.9),
            ballMask:BallMask(rect:CGRect(x:0.35,y:0.565,width:0.1,height:0.07),width:2,height:2,alpha:[0,255,128,0]),
            usesBallMasks:true)
        f.identity = RecordedFrameIdentity(index:1,time:CMTime(value:1001,timescale:60000),width:720,height:1280,coordinates:"composition-720-sdr-v1")
        return f
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:url) }
        return url
    }

    func testNormalRelaunchSharesModelSelectionButChangedAnalysisSettingsInvalidate() throws {
        let name="BallPreparation.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        let clean=SessionAnalysisStore.pipelineOptions(arguments:[],defaults:defaults)
        XCTAssertEqual(clean,SessionAnalysisStore.pipelineOptions(arguments:["--yolo26-motion-model-only"],defaults:defaults))
        XCTAssertEqual(clean,SessionAnalysisStore.pipelineOptions(arguments:["--ssdlite"],defaults:defaults),
            "Retired model flags cannot switch the app or create a different model cache")
        let retiredSSDLiteOptions = clean.replacingOccurrences(of: "KickLabYOLO26MotionSegmentation", with: "KickLabDetector")
        XCTAssertNotEqual(clean,retiredSSDLiteOptions,"Old SSDLite inference retains its separate model identity")
        defaults.set("motionModel",forKey:"experimentalBallModel")
        let normal=SessionAnalysisStore.pipelineOptions(arguments:[],defaults:defaults)
        XCTAssertEqual(clean,normal)
        XCTAssertEqual(normal,SessionAnalysisStore.pipelineOptions(arguments:["--yolo26-motion-model-only"],defaults:defaults))
        for value in ["segmentation","medium","default","unknown"] {
            defaults.set(value,forKey:"experimentalBallModel")
            XCTAssertEqual(normal,SessionAnalysisStore.pipelineOptions(arguments:[],defaults:defaults))
        }
        for flag in ["--disable-marginal-retry","--disable-ball-confirmation","--juggling-no-hand-check","--yolo26-motion-segmentation"] {
            XCTAssertNotEqual(normal,SessionAnalysisStore.pipelineOptions(arguments:[flag],defaults:defaults))
        }
        defaults.set("motion",forKey:"experimentalBallModel")
        XCTAssertNotEqual(SessionAnalysisStore.pipelineOptions(arguments:[],defaults:defaults),
            SessionAnalysisStore.pipelineOptions(arguments:["--yolo26-motion-model-only"],defaults:defaults))
    }

    func testLongSessionAboveOldMaskLimitSurvivesRelaunchWithoutReanalysis() async throws {
        let folder=try temporary(), store=SessionAnalysisStore(folder:folder)
        var f=frame()
        let alpha=(0..<(128*128)).map { i -> UInt8 in
            let x=i%128, y=i/128
            return x*x+y*y < 10000 ? 255 : 0
        }
        f.ballMask=BallMask(rect:CGRect(x:0.2,y:0.3,width:0.2,height:0.2),width:128,height:128,alpha:alpha)
        let frames=Array(repeating:f,count:2200) // 34.4 MiB of exact alpha bytes.
        XCTAssertGreaterThan(frames.count*alpha.count,32*1024*1024)
        _ = try await store.prepare(key:"long") { _ in frames }
        let disk=try Data(contentsOf:folder.appendingPathComponent("long.plist"))
        XCTAssertLessThan(disk.count,4*1024*1024)
        let reopened=SessionAnalysisStore(folder:folder)
        let loaded=try await reopened.prepare(key:"long") { _ in
            XCTFail("A completed long recording repeated its model pass"); return []
        }
        XCTAssertEqual(loaded.count,frames.count)
        for item in loaded { XCTAssertEqual(item.ballMask?.alpha,alpha); XCTAssertEqual(item.identity,f.identity) }
        let hits=await reopened.diskHits
        XCTAssertEqual(hits,1)
    }

    func testLosslessMaskStorageReadsLegacyAndRejectsOversizedRuns() throws {
        let encoder=PropertyListEncoder();encoder.outputFormat = .binary
        var f=frame()
        let alpha=(0..<(128*128)).map { UInt8(($0/17)%256) }
        f.ballMask=BallMask(rect:CGRect(x:0.3,y:0.4,width:0.1,height:0.1),width:128,height:128,alpha:alpha)
        let encoded=try encoder.encode(StoredFrame(f))
        let roundTrip=try PropertyListDecoder().decode(StoredFrame.self,from:encoded)
        XCTAssertTrue(roundTrip.isValid)
        XCTAssertEqual(roundTrip.frame.ballMask?.alpha,alpha)
        var legacy=try XCTUnwrap(PropertyListSerialization.propertyList(from:encoded,format:nil) as? [String:Any])
        legacy.removeValue(forKey:"packedAlpha");legacy["alpha"]=Data(alpha)
        let oldData=try PropertyListSerialization.data(fromPropertyList:legacy,format:.binary,options:0)
        XCTAssertEqual(try PropertyListDecoder().decode(StoredFrame.self,from:oldData).frame.ballMask?.alpha,alpha)
        legacy.removeValue(forKey:"alpha");legacy["packedAlpha"]=Data([255,255,255])
        let corrupt=try PropertyListSerialization.data(fromPropertyList:legacy,format:.binary,options:0)
        XCTAssertFalse(try PropertyListDecoder().decode(StoredFrame.self,from:corrupt).isValid)
    }

    func testVisualTrajectoryMatchesCountingTrajectoryWithoutContactChecks() {
        var checks=0
        let full=StreamingCounter(rejectsHandContact:{ _ in checks += 1; return false })
        let visual=StreamingCounter(rejectsHandContact:{ _ in XCTFail("Visual preparation checked hands");return false },
            footContactEvidence:{ _ in XCTFail("Visual preparation requested a pose");return nil },countsTouches:false)
        for i in 0..<240 {
            let y=0.4+0.16*sin(Double(i)*0.12)
            let ball=BallObservation(frameIndex:i,timestampMs:i*17,x:0.5,y:y,width:0.08,height:0.05,confidence:0.95)
            let person=PersonBox(x:0.5,y:0.45,width:0.7,height:0.9)
            full.push(frameIndex:i,timestampMs:i*17,ball:ball,person:person)
            visual.push(frameIndex:i,timestampMs:i*17,ball:ball,person:person)
            XCTAssertEqual(full.lastPoint?.x,visual.lastPoint?.x)
            XCTAssertEqual(full.lastPoint?.y,visual.lastPoint?.y)
            XCTAssertEqual(full.lastPoint?.vy,visual.lastPoint?.vy)
        }
        full.flush();visual.flush()
        XCTAssertGreaterThan(checks,0)
        XCTAssertGreaterThan(full.count,0)
        XCTAssertEqual(visual.count,0)
        XCTAssertTrue(visual.touches.isEmpty)
    }

    func testConcurrentConsumersAndRelaunchReuseExactMasksAndIdentity() async throws {
        let root = try temporary(), store = SessionAnalysisStore(folder:root), calls = Calls(), expected = [frame()]
        let work: SessionAnalysisStore.Work = { progress in
            await calls.increment(); progress(0.5)
            try await Task.sleep(for:.milliseconds(100))
            return expected
        }
        async let preview = store.prepare(key:"shared",work:work)
        async let export = store.prepare(key:"shared",work:work)
        let (a,b) = try await (preview,export)
        let n = await calls.count
        XCTAssertEqual(n,1)
        XCTAssertEqual(try SessionAnalysisStore.frameData(a),try SessionAnalysisStore.frameData(b))
        let reopened = SessionAnalysisStore(folder:root)
        let c = try await reopened.prepare(key:"shared") { _ in XCTFail("Completed analysis reran after reopening");return [] }
        XCTAssertEqual(c[0].identity,expected[0].identity)
        XCTAssertEqual(c[0].ballMask?.alpha,expected[0].ballMask?.alpha)
        XCTAssertEqual(c[0].vy,expected[0].vy)
        XCTAssertEqual(c[0].person?.height,expected[0].person?.height)
        let hits = await reopened.diskHits
        XCTAssertEqual(hits,1)
    }

    func testCancelledConsumerDoesNotCancelAnotherConsumer() async throws {
        let store = SessionAnalysisStore(folder:try temporary()), expected = [frame()], calls = Calls()
        let first = Task { try await store.prepare(key:"shared") { _ in
            await calls.increment();try await Task.sleep(for:.milliseconds(150));return expected
        } }
        while await calls.count == 0 { await Task.yield() }
        let second = Task { try await store.prepare(key:"shared") { _ in XCTFail("Duplicated work");return [] } }
        try await Task.sleep(for:.milliseconds(30))
        first.cancel()
        let result = try await second.value
        XCTAssertEqual(result[0].ballMask?.alpha,expected[0].ballMask?.alpha)
        do { _ = try await first.value;XCTFail("Cancelled caller received ready data") } catch is CancellationError { }
    }

    func testCancellationNeverCommitsAnIncompleteArtifact() async throws {
        let root = try temporary(), store = SessionAnalysisStore(folder:root), calls = Calls()
        let task = Task { try await store.prepare(key:"cancelled") { _ in
            await calls.increment();try await Task.sleep(for:.seconds(20));return []
        } }
        while await calls.count == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value;XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("cancelled.plist").path))
    }

    func testChangedContentAndPipelineCannotReuseAnOldResult() async throws {
        let root = try temporary(), source = root.appendingPathComponent("clip.mov")
        try Data([1,2,3]).write(to:source)
        let before = try SessionAnalysisStore.sourceDigest(source)
        try Data([1,2,4]).write(to:source)
        let after = try SessionAnalysisStore.sourceDigest(source)
        XCTAssertNotEqual(before,after)
        XCTAssertNotEqual(SessionAnalysisStore.digest(Data((before+"pipeline-v1").utf8)),
                          SessionAnalysisStore.digest(Data((before+"pipeline-v2").utf8)))
        let store = SessionAnalysisStore(folder:root), expected = [frame()], calls = Calls()
        _ = try await store.prepare(key:before) { _ in await calls.increment();return expected }
        _ = try await store.prepare(key:after) { _ in await calls.increment();return expected }
        let n = await calls.count;XCTAssertEqual(n,2)
    }

    func testCancelledWorkerCannotPublishEvenIfItReturnsLate() async throws {
        let root = try temporary(), store = SessionAnalysisStore(folder:root), calls = Calls(), expected = [frame()]
        let task = Task { try await store.prepare(key:"cancelled") { _ in
            await calls.increment()
            // A native operation may finish despite its caller being cancelled.
            try? await Task.sleep(for:.seconds(10))
            return expected
        } }
        while await calls.count == 0 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value;XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("cancelled.plist").path))
        _ = try await store.prepare(key:"cancelled") { _ in await calls.increment();return expected }
        let n = await calls.count;XCTAssertEqual(n,2)
    }

    func testDifferentVideosCannotStartCompetingWholeVideoPasses() async throws {
        let store = SessionAnalysisStore(folder:try temporary()), calls = Calls(), expected = [frame()]
        let first = Task { try await store.prepare(key:"one") { _ in
            await calls.increment();try await Task.sleep(for:.milliseconds(100));return expected
        } }
        while await calls.count == 0 { await Task.yield() }
        do {
            _ = try await store.prepare(key:"two") { _ in XCTFail("Competing detector pass");return [] }
            XCTFail("Expected bounded-work response")
        } catch SessionAnalysisStore.PreparationError.busy { }
        _ = try await first.value
    }

    func testCorruptCacheRecomputesInsteadOfPresentingReady() async throws {
        let root = try temporary();try Data("broken".utf8).write(to:root.appendingPathComponent("clip.plist"))
        let store = SessionAnalysisStore(folder:root), expected = [frame()]
        let result = try await store.prepare(key:"clip") { _ in expected }
        XCTAssertEqual(result.count,1)
        let n = await store.computations;XCTAssertEqual(n,1)
    }

    func testSavedFrameIdentityPreservesFractionalCadenceWithoutChangingCounterTime() throws {
        let f = frame(), encoded = try SessionAnalysisStore.frameData([f])
        let saved = try PropertyListDecoder().decode([StoredFrame].self,from:encoded)
        XCTAssertTrue(saved[0].isValid)
        XCTAssertEqual(saved[0].frame.time,0.016)
        XCTAssertEqual(saved[0].frame.identity?.seconds,1001.0/60000)
        XCTAssertNotEqual(saved[0].frame.time,saved[0].frame.identity?.seconds)
    }

    func testOffscreenTailCannotDisableEarlierMeasuredSpin() {
        let base = BallSurfaceTimeline.initial
        let visible = (0..<40).map { i in BallSurfaceTimeline.Entry(time:Double(i)/60,
            orientation:simd_quatf(angle:Float(i)*0.02,axis:SIMD3(1,0,0))*base,accepted:i>0) }
        let tail = (40..<400).map { i in BallSurfaceTimeline.Entry(time:Double(i)/60,
            orientation:visible.last!.orientation,accepted:false,visible:false) }
        let a = BallSurfaceTimeline(entries:visible,elapsed:0), b = BallSurfaceTimeline(entries:visible+tail,elapsed:0)
        XCTAssertTrue(a.usesSourceRotation);XCTAssertTrue(b.usesSourceRotation)
        XCTAssertEqual(a.status(at:0.3),.measured);XCTAssertEqual(b.status(at:0.3),.measured)
        XCTAssertEqual(a.renderOrientation(at:0.3)?.vector,b.renderOrientation(at:0.3)?.vector)
        XCTAssertEqual(b.status(at:3),.notVisible)
    }

    func testUnknownSpinIsHeldAndDistinctFromObservedLittleMotion() {
        let base = BallSurfaceTimeline.initial
        let unknown = BallSurfaceTimeline(entries:(0..<30).map { .init(time:Double($0)/60,orientation:base,accepted:false) },elapsed:0)
        let still = BallSurfaceTimeline(entries:(0..<30).map { .init(time:Double($0)/60,orientation:base,accepted:$0>0) },elapsed:0)
        XCTAssertEqual(unknown.status(at:0.2),.uncertain)
        XCTAssertEqual(still.status(at:0.2),.littleMotion)
        XCTAssertEqual(unknown.renderOrientation(at:0.2)?.vector,base.vector)
        XCTAssertEqual(unknown.renderOrientation(at:0.4)?.vector,base.vector)
        XCTAssertFalse(unknown.usesSourceRotation)
    }

    @MainActor
    func testCompositionPreparationReusesExistingAnalysisAndPreservesStats() async throws {
        let source = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"capture-mask-vfr",withExtension:"mov"))
        let marks = [RecordedTouch(index:1,time:0.4,x:0.5,y:0.6)]
        var summary = SessionSummary.make(touches:7,duration:2,bestCombo:7,personalBest:7,
            videoURL:source,touchesMarked:marks,track:[frame()])
        summary.needsVisualPreparation = true;summary.framesUseCompositionClock = true
        let model = SessionEffectsPreparation()
        let ready = try await model.prepare(summary)
        let again = try await model.prepare(summary)
        XCTAssertFalse(ready.needsVisualPreparation)
        XCTAssertEqual(ready.touches,7);XCTAssertEqual(ready.touchesMarked,marks)
        XCTAssertEqual(ready.track[0].identity,summary.track[0].identity)
        XCTAssertEqual(ready.renderTrack[0].ballMask?.alpha,summary.track[0].ballMask?.alpha)
        XCTAssertEqual(again.renderTrack[0].score,summary.track[0].score)
        XCTAssertEqual(model.progress,1)
    }
}
