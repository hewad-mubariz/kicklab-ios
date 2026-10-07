// Local still-frame stage audit; this does not measure temporal quality.
// Arguments: output directory, followed by already upright source-crop PNGs.
import AppKit
import CoreImage
import CoreVideo
import Foundation
import Vision

@main struct PersonBoundaryAudit {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Usage: review-person-boundary OUTPUT SOURCE.png ...") }
        let folder = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = CIContext(options: [.cacheIntermediates: false])
        var report: [[String: Any]] = []
        for path in args.dropFirst(2) {
            try autoreleasepool {
                let url = URL(fileURLWithPath: path)
                let source = CIImage(contentsOf: url)!
                let cg = context.createCGImage(source, from: source.extent)!
                let request = VNGenerateForegroundInstanceMaskRequest()
                let guide = VNGeneratePersonSegmentationRequest()
                guide.qualityLevel = .accurate
                guide.outputPixelFormat = kCVPixelFormatType_OneComponent8
                let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
                try handler.perform([request, guide])
                guard let observation = request.results?.first,
                      let guideBuffer = guide.results?.first?.pixelBuffer,
                      let instance = DetailedForegroundMaskProcessor.personInstance(observation.instanceMask, guide: guideBuffer)
                else { throw ForegroundMaskProcessor.Failure.missingMask }
                let raw = try DetailedForegroundMaskProcessor.alpha8(observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler))
                let clean = try DetailedForegroundMaskProcessor.bodyComponent(raw)
                let stem = url.deletingPathExtension().lastPathComponent
                var changed = 0, removedCoverage = 0.0
                CVPixelBufferLockBaseAddress(raw, .readOnly)
                CVPixelBufferLockBaseAddress(clean, .readOnly)
                let w = CVPixelBufferGetWidth(raw), h = CVPixelBufferGetHeight(raw)
                let r = CVPixelBufferGetBaseAddress(raw)!.assumingMemoryBound(to: UInt8.self)
                let c = CVPixelBufferGetBaseAddress(clean)!.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w {
                    let a = Int(r[y * CVPixelBufferGetBytesPerRow(raw) + x])
                    let b = Int(c[y * CVPixelBufferGetBytesPerRow(clean) + x])
                    if a != b { changed += 1; removedCoverage += Double(a-b)/255 }
                }}
                CVPixelBufferUnlockBaseAddress(clean, .readOnly)
                CVPixelBufferUnlockBaseAddress(raw, .readOnly)
                let row: [String: Any] = ["source": path, "width": w, "height": h,
                    "changedPixels": changed, "removedCoveragePixels": removedCoverage,
                    "repairTriggered": DetailedForegroundMaskProcessor.needsPersonRepair(clean, guide: guideBuffer)]
                report.append(row)
                print(row)
                let bg = CIImage(color: CIColor(red: 0.24, green: 0.07, blue: 0.34)).cropped(to: source.extent)
                for (name, buffer) in [("raw", raw), ("clean", clean), ("guide", guideBuffer)] {
                    let image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
                    let alpha = image.transformed(by: CGAffineTransform(scaleX: source.extent.width/image.extent.width, y: source.extent.height/image.extent.height))
                    let composite = source.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: alpha, kCIInputBackgroundImageKey: bg])
                    try context.writePNGRepresentation(of: composite, to: folder.appendingPathComponent(stem+"-"+name+".png"), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    // Untagged numeric mask for comparison; no gamma conversion.
                    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                    CVPixelBufferLockBaseAddress(buffer, .readOnly)
                    let data = Data(bytes: CVPixelBufferGetBaseAddress(buffer)!, count: CVPixelBufferGetBytesPerRow(buffer)*height)
                    CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                    let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
                    try NSBitmapImageRep(cgImage: mask).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(stem+"-"+name+"-mask.png"))
                }
            }
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("stage-audit.json"))
    }
}
