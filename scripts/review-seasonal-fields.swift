// Usage: review-seasonal-fields <metallib> <output-folder> [--animate]
import CoreImage
import Foundation

@main struct ReviewSeasonalFields {
    static func main() throws {
        let renderer = try StadiumPreviewRenderer(library: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let context = CIContext(mtlDevice: renderer.device)
        let empty = try ForegroundMaskProcessor.buffer(width: 8, height: 8, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(empty, [])
        memset(CVPixelBufferGetBaseAddress(empty)!, 0, CVPixelBufferGetBytesPerRow(empty) * 8)
        CVPixelBufferUnlockBaseAddress(empty, [])
        for environment in [PreviewEnvironment.snowField, .beachField] {
            let out = root.appendingPathComponent(environment.rawValue)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            func render(name: String, width: Int, height: Int, yaw: Float = 0, time: Double = 0) throws {
                let output = try ForegroundMaskProcessor.buffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
                var camera = SceneCameraRig(aspect: Float(width)/Float(height), subjectHeight: 0.4, ground: SIMD2(0.5,0.83))
                camera.movement = 0; camera.horizon = name == "portrait" ? 0.48:0.53
                camera.verticalFOV = 65 * .pi/180; camera.look.x = yaw
                try renderer.render(source: empty, mask: empty, output: output, camera: camera, time: time, scene: true, environment: environment)
                try context.writePNGRepresentation(of: CIImage(cvPixelBuffer: output), to: out.appendingPathComponent(name+".png"),
                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            }
            let start = Date()
            try render(name: "field", width: 1536, height: 1024)
            try render(name: "side", width: 1536, height: 1024, yaw: .pi/2)
            try render(name: "reverse", width: 1536, height: 1024, yaw: .pi)
            try render(name: "portrait", width: 720, height: 1280)
            try render(name: "card", width: 840, height: 600)
            if CommandLine.arguments.contains("--animate") {
                try FileManager.default.createDirectory(at: out.appendingPathComponent("frames"), withIntermediateDirectories: true)
                for frame in 0..<60 { try render(name: String(format: "frames/%03d", frame), width: 960, height: 640, time: Double(frame)/30) }
            }
            print("\(environment.title): reviewed in \(Date().timeIntervalSince(start)) seconds")
        }
    }
}
