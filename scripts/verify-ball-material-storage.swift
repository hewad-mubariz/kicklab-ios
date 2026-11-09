// Build with BallMaterialStorage, BallCollectionMaterial, BallSkin and BallSkinSphereRenderer.
// Run separately with KICKLAB_BALL_MATERIALS_DIR set to the original and packed directories.
// Compare `frames` in the resulting JSON: all image bytes must match, not just look similar.
import AppKit
import CryptoKit
import Foundation
import simd

// This CLI exercises the fourteen artwork skins, not the separate Effects Lab renderer.
nonisolated final class LabSkinRenderer {
    static var shared: LabSkinRenderer? { nil }
    func image(skin: BallSkin, orientation: simd_quatf, size: Int) -> CGImage? { nil }
}

@main enum VerifyBallMaterialStorage {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              ProcessInfo.processInfo.environment["KICKLAB_BALL_MATERIALS_DIR"] != nil else {
            fatalError("Usage: KICKLAB_BALL_MATERIALS_DIR=<dir> verify-ball-material-storage <new-report-directory>")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let skins = BallSkin.allCases.filter { $0 != .original && !$0.isLabSkin }
        var timings: [String: [Double]] = [:], hashes: [String: String] = [:], frames: [String: String] = [:]
        for skin in skins {
            for iteration in 0..<11 {
                let start = ProcessInfo.processInfo.systemUptime
                guard let artwork = BallCollectionMaterial.artwork(skin: skin, width: 1024, height: 512, panelSites: []) else {
                    fatalError("Missing artwork: \(skin)")
                }
                let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if iteration > 0 { timings[skin.rawValue, default: []].append(ms) }
                else { hashes[skin.rawValue] = hash(Data(artwork.rgba + artwork.normals)) }
            }
            for preview in [false, true] { for index in 0..<4 {
                let pose = simd_quatf(angle: Float(index) * .pi / 2, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.3)))
                guard let image = BallSkinSphereRenderer.uncachedImageForReview(skin: skin, time: 1.7,
                    orientation: pose, preview: preview) else { fatalError("Missing render: \(skin)") }
                let name = "\(skin.rawValue)-\(preview ? 144 : 256)-\(index)"
                frames[name] = hash(image.dataProvider!.data! as Data)
                if !preview && index == 0 {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                        .write(to: output.appendingPathComponent(name + ".png"))
                }
            } }
        }
        let report: [String: Any] = ["decoded": hashes, "frames": frames, "loadMilliseconds": timings,
                                    "retainedArtworkBytes": BallSkinSphereRenderer.decodedArtworkBytes]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("\(skins.count) materials, \(frames.count) frames, \(BallSkinSphereRenderer.decodedArtworkBytes) retained bytes")
    }
}
