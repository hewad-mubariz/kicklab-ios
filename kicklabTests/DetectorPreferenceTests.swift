import XCTest
@testable import kicklab

@MainActor
final class DetectorPreferenceTests: XCTestCase {
    func testReusedInputPackingMatchesEveryByteAndHonorsPaddedRows() {
        let width=257,height=3,rowBytes=width*4+32
        var source=[UInt8](repeating:219,count:rowBytes*height)
        for y in 0..<height {for x in 0..<width {for c in 0..<4 {
            source[y*rowBytes+x*4+c]=UInt8((x+y*43+c*17)%256)
        }}}
        var output=[Float](repeating:-1,count:width*height*3)
        for bgr in [false,true] {
            source.withUnsafeBufferPointer { bytes in output.withUnsafeMutableBufferPointer { target in
                BallDetector.fillInput(bytes.baseAddress!,rowBytes:rowBytes,width:width,height:height,bgr:bgr,output:target.baseAddress!)
            }}
            for y in 0..<height {for x in 0..<width {for c in 0..<3 {
                let value=Float(source[y*rowBytes+x*4+(bgr ? c : 2-c)])
                let expected=bgr ? value : value/255.0
                XCTAssertEqual(output[c*width*height+y*width+x].bitPattern,expected.bitPattern)
            }}}
        }
    }

    func testAppAlwaysUsesMotionDespiteLegacyPreferencesAndLaunchFlags() throws {
        let name="KickLab.DetectorSelectionTests.\(UUID().uuidString)"
        let defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        XCTAssertEqual(BallDetector.configuredResourceName(arguments:[],defaults:defaults),"KickLabYOLO26MotionSegmentation")
        let launches: [[String]] = [[], ["--ssdlite"], ["--fasterrcnn"], ["--yolox"],
            ["--yolox-roi"], ["--yolo26-medium-retained"], ["--yolo26-medium-segmentation"],
            ["--select-segmentation-pilot"], ["--yolo26-motion-model-only"],
            ["--yolo26-motion-segmentation", "--ssdlite"]]
        for value in ["motion","motionModel","segmentation","medium","default","ssdlite","unknown"] {
            defaults.set(value,forKey:"experimentalBallModel")
            let reopened=try XCTUnwrap(UserDefaults(suiteName:name))
            for arguments in launches {
                XCTAssertEqual(BallDetector.configuredResourceName(arguments:arguments,defaults:reopened),
                    "KickLabYOLO26MotionSegmentation", "Legacy preference \(value), arguments \(arguments)")
            }
        }
    }
}
