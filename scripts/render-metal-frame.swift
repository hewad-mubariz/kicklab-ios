// Compile with EffectFrame.swift + MetalEffectEngine.swift for the macOS render lab.
import Foundation
import AppKit
import Metal
import simd

@main struct RenderMetalFrame {
    static func main() throws {
        let args = CommandLine.arguments
        let resources = try MetalEffectEngine.Resources(libraryURL: URL(fileURLWithPath: args[1]))
        let engine = try MetalEffectEngine(resources: resources)
        let time = Double(args[4]) ?? 2
        guard let image = NSImage(contentsOfFile: args[2])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Image missing") }
        let w = image.width, h = image.height
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: Any]
        var frame: EffectFrame
        if let center = json["center"] as? [Double], let radius = json["radius"] as? Double {
            // Exact geometry from the Python study isolates shader/compositor
            // parity from differing detector-radius smoothing in each viewer.
            let trail = (json["trail"] as? [[Double]] ?? []).map {
                SIMD4<Float>(Float($0[0]),Float($0[1]),Float($0[2]),Float($0[3]))
            }
            frame = EffectFrame(size: CGSize(width:w,height:h), center: SIMD2(Float(center[0]),Float(center[1])),
                radius: Float(radius), time: time, intensity: Float(json["intensity"] as? Double ?? 0.85), trail: trail)
        } else {
            let rows = json["track"] as! [[String: Double]]
            let f = rows.min { abs($0["time"]! - time) < abs($1["time"]! - time) }!
            let radius = Float(min(f["width"]! * Double(w), f["height"]! * Double(h)) / 2)
            let trail = rows.filter { $0["time"]! <= time && $0["time"]! > time - 0.84 }.suffix(64).map {
                SIMD4<Float>(Float($0["x"]!*Double(w)), Float($0["y"]!*Double(h)),
                    Float(min($0["width"]!*Double(w), $0["height"]!*Double(h))/2), Float(time-$0["time"]!))
            }
            frame = EffectFrame(size: CGSize(width: w, height: h), center: SIMD2(Float(f["x"]!*Double(w)),Float(f["y"]!*Double(h))), radius: radius, time: time, intensity: 0.85, trail: trail)
        }
        if let previous = frame.trail.last(where: { $0.w > 0.07 && $0.w < 0.12 }) {
            frame.velocity = simd_clamp((frame.center - SIMD2(previous.x,previous.y)) / (max(frame.radius,1) * previous.w), SIMD2(repeating: -32), SIMD2(repeating:32))
        }
        if args.count > 6 { frame.style = Float(args[6]) ?? 1 }
        if frame.style == 3 || frame.style == 4 || frame.style == 6 || frame.style == 8 {
            let cue = frame.contactMotionCue
            frame.impact = cue.strength
            frame.impactAge = cue.age
        }
        if args.count > 7 { frame.environment = Float(args[7]) ?? 0 }
        let source = try engine.texture(width: w, height: h, storage: .shared)
        let result = try engine.texture(width: w, height: h, storage: .shared)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress!, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            source.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: buffer.baseAddress!, bytesPerRow: w*4)
        }
        let start = Date()
        try engine.render(frame, into: result, source: source)
        print("Rendered \(w)x\(h), ball \(frame.center), r \(frame.radius), impact \(frame.impact) at age \(frame.impactAge), GPU wall time \(Date().timeIntervalSince(start))s")
        pixels.withUnsafeMutableBytes { result.getBytes($0.baseAddress!, bytesPerRow: w*4, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0) }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let out = CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:info),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)!
        let rep = NSBitmapImageRep(cgImage: out)
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:args[5]))
    }
}
