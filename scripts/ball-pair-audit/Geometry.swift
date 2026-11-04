import AVFoundation
import AppKit
import CoreImage
import Foundation
import simd

enum PairGeometry {
    // --geometry SOURCE VISUAL.plist OUTPUT_DIRECTORY [short-edge] [stride]
    static func run(_ args: [String]) async throws {
        let source = URL(fileURLWithPath: args[2]), folder = URL(fileURLWithPath: args[4])
        let edge = args.count > 5 ? Int(args[5])! : 1080
        let stride = args.count > 6 ? Int(args[6])! : 6
        precondition(edge > 0 && stride > 0)
        let frames = try SavedAppearanceFrames.frames(URL(fileURLWithPath: args[3]))
        var track = BallEffectTrack(frames: frames)
        let spinURL = URL(fileURLWithPath:args[3]).deletingLastPathComponent().appendingPathComponent("spin.json")
        if let data = try? Data(contentsOf:spinURL), let saved = try JSONSerialization.jsonObject(with:data) as? [String:Any],
           let spinRows = saved["rows"] as? [[String:Any]] {
            let entries = spinRows.map { row -> BallSurfaceTimeline.Entry in
                let q = row["orientation"] as! [Double]
                return .init(time:row["time"] as! Double, orientation:simd_quatf(ix:Float(q[0]),iy:Float(q[1]),iz:Float(q[2]),r:Float(q[3])),
                    accepted:row["accepted"] as! Bool,visible:row["visible"] as! Bool)
            }
            track.surfaceMotion = BallSurfaceTimeline(entries:entries,elapsed:0,photographicExposure:saved["photographicExposure"] as? Double)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: source), video = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: edge)
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        let ci = CIContext(options: [.cacheIntermediates: false])
        var rows = [[String: Any]](), index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard index % stride == 0 else { continue }
            try autoreleasepool {
                let time = sample.presentationTimeStamp.seconds, pixels = CMSampleBufferGetImageBuffer(sample)!
                let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
                var row: [String: Any] = ["index":index,"time":time,"size":[size.width,size.height]]
                let fitted = track.replacementGuide(at: time).flatMap { BallReplacementFootprint.fit(pixels: pixels, sample: $0) }
                func outline(_ value: BallReplacementFootprint) -> [String: Any] {
                    ["center":[value.center.x,value.center.y], "radius":value.radius,
                     "radii":value.radii,"feather":value.feather]
                }
                row["fit"] = fitted.map(outline)
                row["radiusReference"] = track.radiusReference(at: time, size: size)
                let smear = track.smear(at: time, size: size)
                row["smear"] = [smear.dx,smear.dy]
                if let matte = track.replacementMatte(at: time, fitted: fitted, size: size, smear: .zero, photographicSmear: false),
                   let mask = track.mask(at: time) {
                    let body = matte.footprint
                    row["body"] = outline(body); row["reconstructsBody"] = matte.reconstructsBody
                    let radius = body.radius
                    let crop = CGRect(x: body.center.x-radius*1.55, y: body.center.y-radius*1.55,
                        width: radius*3.1, height:radius*3.1).integral.intersection(CGRect(origin: .zero, size: size))
                    let n = 192
                    var alpha = [UInt8](repeating:0,count:n*n), raw = alpha
                    var hole = 0.0, inside = 0.0
                    for y in 0..<n { for x in 0..<n {
                        let px = crop.minX+(Double(x)+0.5)/Double(n)*crop.width
                        let py = crop.minY+(Double(y)+0.5)/Double(n)*crop.height
                        let a = matte.coverage(x:px,y:py)
                        alpha[y*n+x] = UInt8(max(0,min(255,(a*255).rounded())))
                        raw[y*n+x] = UInt8(max(0,min(255,(mask.coverage(x:px/size.width,y:py/size.height)*255).rounded())))
                        if hypot(px-body.center.x,py-body.center.y) < radius*0.8 { inside += 1; hole += 1-a }
                    } }
                    row["interiorMissingFraction"] = hole/max(1,inside)
                    row["crop"] = [crop.minX,crop.minY,crop.width,crop.height]
                    func save(_ values: [UInt8], _ suffix: String) throws {
                        let provider = CGDataProvider(data:Data(values) as CFData)!
                        let image = CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:n,
                            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,
                            decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
                            .write(to:folder.appendingPathComponent(String(format:"%05d-%@.png",index,suffix)))
                    }
                    try save(alpha,"coverage"); try save(raw,"mask")
                    let image = CIImage(cvPixelBuffer:pixels)
                    let cg = ci.createCGImage(image,from:image.extent)!.cropping(to:crop)!
                    try NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])!
                        .write(to:folder.appendingPathComponent(String(format:"%05d-source.png",index)))
                    if index % 30 == 0, let guide = track.replacementGuide(at:time) {
                        let fullImage = ci.createCGImage(image,from:image.extent)!
                        for (name, motion) in [("current",smear),("no-blur",CGVector.zero)] {
                            guard let coverage = track.replacementMatte(at:time,fitted:fitted,size:size,smear:motion,
                                photographicSmear:track.surfaceMotion?.photographicExposure != nil) else { continue }
                            let replacement = BallMaterialRenderer.replacement(footprint:coverage.footprint,skin:.arctic,time:time,
                                coverage:{coverage.coverage(x:$0,y:$1)},coverageBounds:coverage.bounds,
                                orientation:track.surfaceMotion?.renderOrientation(at:time),smear:motion,
                                light:BallSurfaceTimeline.white(pixels:pixels,center:body.center,radius:body.radius),
                                background:BallReplacementBackground(pixels:pixels,matte:coverage))
                            guard let replacement else { throw NSError(domain:"PairAudit.MissingArtwork",code:1) }
                            let ctx = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,
                                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                            ctx.draw(fullImage,in:CGRect(origin:.zero,size:size));ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)
                            BallMaterialRenderer.draw(in:ctx,size:size,sourceSize:size,skin:.arctic,sample:guide,time:time,replacement:replacement)
                            try NSBitmapImageRep(cgImage:ctx.makeImage()!.cropping(to:crop)!).representation(using:.png,properties:[:])!
                                .write(to:folder.appendingPathComponent(String(format:"%05d-%@.png",index,name)))
                        }
                    }
                }
                rows.append(row)
            }
        }
        guard reader.status == .completed else { throw reader.error! }
        let report: [String: Any] = ["rows":rows,"shortEdge":edge,"stride":stride,
            "scope":"Current production fit/coverage with fresh raw masks before app crop/gap repair. Coverage images use zero smear. Current/no-blur artwork controls change only smear; both use the fresh spin timeline and per-frame white estimate, not the app's median white. Not an exact replay of the exported clip's retained track."]
        try JSONSerialization.data(withJSONObject: report, options:[.sortedKeys])
            .write(to:folder.appendingPathComponent("geometry.json"))
        print("Geometry complete: \(rows.count) frames, edge \(edge)")
    }
}
