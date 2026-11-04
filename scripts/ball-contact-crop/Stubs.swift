// Stand-ins for app services the model bridge and renderer reference. Model, geometry, masks and
// drawing use production sources. Like the other audits, this renders artwork skins only.
import Foundation
import CoreGraphics
import simd

nonisolated enum RFInputResolution: Int { case small = 288, detailed = 384 }
nonisolated enum BallDetector { static let personThreshold = 0.5 }
nonisolated struct Detection { let score, x, y, width, height: Double }
nonisolated struct FrameDetections {
    var ball: Detection?
    var person: Detection?
    var people: [Detection] = []
    var ballMask: BallMask? = nil
    var usesBallMasks = false
}
extension PersonBox {
    func iou(_ other: Self) -> Double {
        let a = CGRect(x: x-width/2, y: y-height/2, width: width, height: height)
        let b = CGRect(x: other.x-other.width/2, y: other.y-other.height/2, width: other.width, height: other.height)
        let overlap = a.intersection(b)
        return overlap.isNull ? 0 : overlap.width*overlap.height/(a.width*a.height+b.width*b.height-overlap.width*overlap.height)
    }
}

nonisolated final class LabSkinRenderer {
    static var shared: LabSkinRenderer? { nil }
    func image(skin: BallSkin, orientation: simd_quatf, size: Int) -> CGImage? { nil }
}
