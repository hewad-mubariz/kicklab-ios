import Foundation
import XCTest
@testable import kicklab

final class RFInputNormalizationTests: XCTestCase {
    func testPlanMatchesTrainingTransformBitForBitAcrossSizesAndPadding() {
        for (width, height, padding) in [(1, 1, 12), (2, 2, 4), (17, 31, 36),
                                          (720, 1280, 16), (1919, 1079, 36)] {
            let rowBytes = width * 4 + padding
            var bytes = [UInt8](repeating: 0, count: rowBytes * height)
            for edge in [288, 384] {
                let plan = RFNormalizationPlan(width: width, height: height, rowBytes: rowBytes, edge: edge)
                var expected = [Float](repeating: 0, count: 3 * edge * edge), actual = expected
                // Reusing a plan must read each new frame, including alpha and
                // padding changes, without retaining pixels from the last one.
                for frame in 0..<2 {
                    for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 37 &+ frame &* 113) }
                    bytes.withUnsafeBufferPointer { source in
                        expected.withUnsafeMutableBufferPointer { reference in
                            RFInputNormalization.normalizeBGRA(source.baseAddress!, width: width, height: height,
                                rowBytes: rowBytes, into: reference.baseAddress!, edge: edge)
                        }
                        actual.withUnsafeMutableBufferPointer { result in
                            plan.apply(source.baseAddress!, into: result.baseAddress!)
                        }
                    }
                    let matches = zip(expected, actual).allSatisfy { $0.bitPattern == $1.bitPattern }
                    XCTAssertTrue(matches, "\(width)x\(height), stride \(rowBytes), edge \(edge), frame \(frame)")
                }
            }
        }
    }
}
