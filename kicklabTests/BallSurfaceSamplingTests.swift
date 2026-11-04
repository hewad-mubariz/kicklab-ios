import XCTest
@testable import kicklab

final class BallSurfaceSamplingTests: XCTestCase {
    // Frozen interpolation contract, including the fractional upper-edge clamp.
    private func reference(_ image: BallSurfaceMotion.Gray, _ px: Double, _ py: Double) -> Double {
        let x = max(0, min(Double(image.width - 1) - 0.001, px))
        let y = max(0, min(Double(image.width - 1) - 0.001, py))
        let ix = Int(x), iy = Int(y), fx = x - Double(ix), fy = y - Double(iy), w = image.width, a = image.values
        return (Double(a[iy*w+ix])*(1-fx)+Double(a[iy*w+ix+1])*fx)*(1-fy)
            + (Double(a[(iy+1)*w+ix])*(1-fx)+Double(a[(iy+1)*w+ix+1])*fx)*fy
    }
    private var fixture: BallSurfaceMotion.Gray {
        let pixels: [Float] = (0..<(128 * 128)).map { index in
            let value: Int = (index * 37 + (index / 128) * 19) % 256
            return Float(value) / Float(255)
        }
        return .init(width: 128, values: pixels)
    }
    func testPixelCentreFastPathPreservesBorderAndFractionalSamplesExactly() {
        let image = fixture
        for y in -1...128 { for x in -1...128 {
            let expected = reference(image, Double(x), Double(y))
            XCTAssertEqual(image.at(x, y), expected)
            XCTAssertEqual(image.at(Double(x), Double(y)), expected)
        } }
        for p in [(-1.2, 8.1), (0.5, 127.0), (126.75, 126.4), (127.0, 127.0)] {
            XCTAssertEqual(image.at(p.0, p.1), reference(image, p.0, p.1))
        }
    }
    func testOptimizedPyramidsAreBitIdenticalToHistoricalSampling() {
        var expected = [fixture]
        for _ in 0..<2 {
            let source = expected.last!, width = source.width / 2
            var pixels = [Float](repeating: 0, count: width * width)
            for y in 0..<width { for x in 0..<width {
                var sum = 0.0
                for j in -1...1 { for i in -1...1 {
                    sum += reference(source, Double(x*2+i), Double(y*2+j)) * Double((i == 0 ? 2 : 1) * (j == 0 ? 2 : 1))
                } }
                pixels[y*width+x] = Float(sum / 16)
            } }
            expected.append(.init(width: width, values: pixels))
        }
        XCTAssertEqual(fixture.pyramid().map(\.values), expected.map(\.values))
    }
}
