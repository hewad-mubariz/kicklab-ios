#if DEBUG
import XCTest
@testable import kicklab

@MainActor final class WallSetupReuseTests: XCTestCase {
    private let size=CGSize(width:1280,height:720)
    private let corners=WallMappingFixture.corners

    private func prepared() -> WallTargetsModel {
        let defaults=UserDefaults(suiteName:"WallReuse.\(UUID())")!
        let model=WallTargetsModel(defaults:defaults)
        XCTAssertTrue(model.setCorners(corners))
        model.validateMappingForTest()
        XCTAssertTrue(model.finishReference([0.04]))
        model.rememberSetup(frameSize:size)
        XCTAssertTrue(model.hasReusableSetup)
        return model
    }
    func testRematchRetainsMeasurementButCannotScoreUntilFreshAlignment() {
        let model=prepared()
        model.finishSession();model.recordingState = .saved
        XCTAssertTrue(model.beginGameSetup(reusingSetup:true))
        XCTAssertEqual(model.wallReference?.diameters,[0.04])
        XCTAssertFalse(model.startPlay())
        model.applyAlignment(.init(status:.ready,corners:corners,revision:1))
        XCTAssertTrue(model.startPlay())
        XCTAssertTrue(model.hits.isEmpty)
    }
    func testAllWallGamesShareTheMeasuredSurfaceWithoutSharingScores() {
        let model=prepared()
        let anchor=model.reusableSetup
        for game in WallGame.allCases {
            model.showGameIntro()
            XCTAssertTrue(model.selectGame(game,preservingSetup:true))
            XCTAssertTrue(model.hasReusableSetup)
            XCTAssertEqual(model.reusableSetup,anchor)
            XCTAssertTrue(model.hits.isEmpty)
            XCTAssertTrue(model.beginGameSetup(reusingSetup:true))
            XCTAssertFalse(model.startPlay())
            model.applyAlignment(.init(status:.ready,corners:corners,revision:1))
            XCTAssertTrue(model.startPlay())
            model.finishSession()
        }
    }
    func testAnchorRejectsTranslationZoomFramingAndCumulativeDrift() {
        let setup=WallSetupReuse(corners:corners,frameSize:size)
        XCTAssertTrue(setup.accepts(corners:corners,frameSize:size))
        XCTAssertTrue(setup.accepts(corners:corners.map { CGPoint(x:$0.x+1/size.width,y:$0.y) },frameSize:size))
        XCTAssertFalse(setup.accepts(corners:corners.map { CGPoint(x:$0.x+4/size.width,y:$0.y) },frameSize:size))
        XCTAssertFalse(setup.accepts(corners:corners.map { CGPoint(x:0.5+($0.x-0.5)*1.04,y:0.5+($0.y-0.5)*1.04) },frameSize:size))
        XCTAssertFalse(setup.accepts(corners:corners,frameSize:CGSize(width:1920,height:1080)))
        XCTAssertFalse(setup.accepts(corners:[],frameSize:size))
        // Repeated 1-pixel observations cannot gradually move the hold anchor.
        for offset in [0,1,2,4,8] {
            XCTAssertEqual(setup.accepts(corners:corners.map { CGPoint(x:$0.x+Double(offset)/size.width,y:$0.y) },frameSize:size),offset<3)
        }
    }
    func testInvalidationAndNewCameraNeverRestoreReferenceFromPreferences() {
        let model=prepared()
        model.invalidateCalibration()
        XCTAssertFalse(model.hasReusableSetup)
        XCTAssertNil(model.reusableSetup)
        XCTAssertTrue(model.beginGameSetup(reusingSetup:true))
        XCTAssertNil(model.wallReference)
        XCTAssertFalse(model.startPlay())
        let defaults=UserDefaults(suiteName:"WallReuse.Restart.\(UUID())")!
        let first=WallTargetsModel(defaults:defaults)
        first.setCorners(corners);first.validateMappingForTest();first.finishReference([0.04]);first.rememberSetup(frameSize:size)
        let reopened=WallTargetsModel(defaults:defaults)
        XCTAssertFalse(reopened.hasReusableSetup)
        XCTAssertNil(reopened.wallReference)
    }
    func testChangedGeometryAndFailedMappingCannotBeReused() {
        let model=prepared()
        model.applyAlignment(.init(status:.referenceRequired,corners:corners,revision:2))
        XCTAssertFalse(model.hasReusableSetup)
        XCTAssertNil(model.reusableSetup)
        model.setCorners(corners);model.finishReference([0.04]);model.rememberSetup(frameSize:size)
        XCTAssertFalse(model.hasReusableSetup)
    }

    func testOpeningFramingGuideDoesNotCertifyOrDiscardExistingBallHold() {
        let model=prepared()
        let setup=model.reusableSetup
        model.arcadeSetupGuidePresented=true
        XCTAssertFalse(model.beginGameSetup(reusingSetup:true))
        model.applyAlignment(.init(status:.ready,corners:corners,revision:1))
        XCTAssertFalse(model.startPlay())
        XCTAssertEqual(model.reusableSetup,setup)
        model.arcadeSetupGuidePresented=false
        XCTAssertTrue(model.beginGameSetup(reusingSetup:true))
        XCTAssertFalse(model.startPlay(),"Closing the preview cannot skip fresh alignment")
        model.applyAlignment(.init(status:.ready,corners:corners,revision:1))
        XCTAssertTrue(model.startPlay())
    }

    func testDisplayChangeImmediatelyPausesAndInvalidatesButRepeatedNotificationDoesNot() {
        let model=prepared()
        model.setProjectorConnected(false)
        XCTAssertTrue(model.hasReusableSetup)
        model.applyAlignment(.init(status:.ready,corners:corners,revision:1))
        XCTAssertTrue(model.startPlay())
        model.setProjectorConnected(true)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasReusableSetup)
        XCTAssertNil(model.wallReference)
        XCTAssertFalse(model.startPlay())
        model.setCorners(corners);model.validateMappingForTest();model.finishReference([0.04]);model.rememberSetup(frameSize:size)
        model.setProjectorConnected(true)
        XCTAssertTrue(model.hasReusableSetup)
        model.setProjectorConnected(false)
        XCTAssertFalse(model.hasReusableSetup)
        XCTAssertFalse(model.startPlay())
    }
}
#endif
