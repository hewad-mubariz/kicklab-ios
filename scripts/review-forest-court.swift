// Render shipping Forest Court geometry at landscape and portrait sizes.
// Usage: review-forest-court <metallib> <output-folder> [time-seconds]
import CoreImage
import Foundation

@main struct ReviewForestCourt {
    static func main() throws {
        let renderer = try StadiumPreviewRenderer(library: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        let time = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 0 : 0
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let context = CIContext(mtlDevice: renderer.device)
        let empty = try ForegroundMaskProcessor.buffer(width: 8, height: 8, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(empty, [])
        memset(CVPixelBufferGetBaseAddress(empty)!, 0, CVPixelBufferGetBytesPerRow(empty) * 8)
        CVPixelBufferUnlockBaseAddress(empty, [])
        for (name, width, height, yaw) in [("court",1536,1024,Float(0)),("side",1536,1024,Float.pi/2),
            ("reverse",1536,1024,Float.pi),("portrait",720,1280,Float(0)),("card",840,600,Float(0))] {
            let output = try ForegroundMaskProcessor.buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
            var camera = SceneCameraRig(aspect: Float(width)/Float(height), subjectHeight: 0.4, ground: SIMD2(0.5,0.83))
            camera.movement = 0; camera.horizon = name == "portrait" ? 0.48:0.53
            camera.verticalFOV = 65 * .pi/180; camera.look.x = yaw
            let start = Date()
            try renderer.render(source: empty, mask: empty, output: output, camera: camera, time: time, scene: true, environment: .forestCourt)
            print("\(name): \(Date().timeIntervalSince(start)*1000) ms, including submission and warmup")
            try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: output), to: out.appendingPathComponent(name+".png"),
                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
    }
}
