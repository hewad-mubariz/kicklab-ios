// Render picker artwork with the shipping scene shader, without a foreground.
// Usage: render-environment-cards <metallib> <Assets.xcassets>
import CoreImage
import Foundation

@main struct RenderEnvironmentCards {
    static func main() throws {
        let renderer = try StadiumPreviewRenderer(library: CommandLine.arguments[1])
        let context = CIContext(mtlDevice: renderer.device)
        let empty = try ForegroundMaskProcessor.buffer(width: 8, height: 8, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(empty, [])
        memset(CVPixelBufferGetBaseAddress(empty)!, 0, CVPixelBufferGetBytesPerRow(empty) * 8)
        CVPixelBufferUnlockBaseAddress(empty, [])
        let output = try ForegroundMaskProcessor.buffer(width: 840, height: 600, format: kCVPixelFormatType_32BGRA)
        var camera = SceneCameraRig(aspect: 1.4, subjectHeight: 0.4, ground: SIMD2(0.5, 0.83))
        camera.movement = 0; camera.horizon = 0.61; camera.verticalFOV = 65 * .pi / 180
        for scene in PreviewEnvironment.allCases {
            camera.horizon = scene.shaderIndex >= 2 ? 0.53 : 0.61
            try renderer.render(source: empty, mask: empty, output: output, camera: camera, time: 0, scene: true, environment: scene)
            let folder = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent(scene.imageName + ".imageset")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: output), to: folder.appendingPathComponent(scene.imageName + ".png"),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let info: [String: Any] = ["images": [["filename": scene.imageName + ".png", "idiom": "universal"]], "info": ["author": "xcode", "version": 1]]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
        }
    }
}
