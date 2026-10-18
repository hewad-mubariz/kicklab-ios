#if DEBUG
import CoreVideo
import CoreImage
import ImageIO
import Vision

/// Explicit replay-only inspection of low-confidence landmarks. These alternate
/// observations never participate in the live verdict or overwrite its cache.
nonisolated enum ContactPoseAudit {
    static func inspect(_ frame: ContactObservationStore.Frame, source: CVPixelBuffer) throws -> [String: Any] {
        var result: [String: Any] = ["frame":frame.index,"timestampMs":frame.timestampMs]
        let context = CIContext()
        var inputs: [(String, CVPixelBuffer, CGImagePropertyOrientation)] = [
            ("normal",frame.pixels,.up), ("mirrored",frame.pixels,.upMirrored), ("source",source,.up)]
        for edge in [768,1024] {
            var input = CIImage(cvPixelBuffer: source)
            let scale = min(1,Double(edge)/max(input.extent.width,input.extent.height))
            input = input.transformed(by: CGAffineTransform(scaleX:scale,y:scale))
            var buffer: CVPixelBuffer?
            if CVPixelBufferCreate(kCFAllocatorDefault,Int(input.extent.width),Int(input.extent.height),
                kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer) == kCVReturnSuccess,
               let buffer {
                context.render(input,to:buffer)
                inputs.append(("edge\(edge)",buffer,.up))
            }
        }
        for (name,pixels,orientation) in inputs {
            let request = VNDetectHumanBodyPoseRequest()
            try VisionComputePolicy.configure(request)
            let start = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cvPixelBuffer:pixels,orientation:orientation).perform([request])
            result[name+"Ms"] = (ProcessInfo.processInfo.systemUptime-start)*1000
            result[name] = try (request.results ?? []).map { pose in
                try pose.recognizedPoints(.all).reduce(into:[String:[Double]]()) { row,item in
                    let p = item.value
                    row[item.key.rawValue.rawValue] = [Double(p.location.x),1-Double(p.location.y),Double(p.confidence)]
                }
            }
        }
        // A selected-player crop is an audit only. Compare original source
        // detail with the existing bounded contact buffer before considering
        // any extra live inference or retaining larger images.
        if let player = frame.player, player.canMatchPose, let box = player.box {
            for (name, pixels) in [("selectedCropSource",source),("selectedCropBuffered",frame.pixels)] {
                let input = CIImage(cvPixelBuffer: pixels), size = input.extent.size
                let region = CGRect(x: box.x-box.width*0.6, y: box.y-box.height*0.6,
                                    width: box.width*1.2, height: box.height*1.2)
                    .intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
                let rect = CGRect(x: region.minX*size.width,y: (1-region.maxY)*size.height,
                                  width: region.width*size.width,height: region.height*size.height)
                    .integral.intersection(input.extent)
                guard !rect.isEmpty else { continue }
                let crop = input.cropped(to: rect).transformed(by:
                    CGAffineTransform(translationX: -rect.minX,y: -rect.minY))
                for degrees in [0,30,60,90] {
                    let variant = degrees == 0 ? name : name+"Clockwise\(degrees)"
                    let rotation = CGAffineTransform(rotationAngle: -Double(degrees) * .pi/180)
                    let rotated = crop.transformed(by: rotation)
                    let bounds = rotated.extent
                    let shift = CGAffineTransform(translationX: -bounds.minX,y: -bounds.minY)
                    let scale = 512/max(bounds.width,bounds.height)
                    let scaling = CGAffineTransform(scaleX: scale,y: scale)
                    let transform = rotation.concatenating(shift).concatenating(scaling)
                    let rendered = crop.transformed(by: transform)
                    let width = Int(rendered.extent.width), height = Int(rendered.extent.height)
                    var buffer: CVPixelBuffer?
                    guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,
                        kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer) == kCVReturnSuccess,
                          let buffer else { continue }
                    context.render(rendered,to: buffer)
                    let request = VNDetectHumanBodyPoseRequest()
                    try VisionComputePolicy.configure(request)
                    let start = ProcessInfo.processInfo.systemUptime
                    try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
                    result[variant+"Ms"] = (ProcessInfo.processInfo.systemUptime-start)*1000
                    result[variant+"Rect"] = [rect.minX/size.width,1-rect.maxY/size.height,
                                             rect.width/size.width,rect.height/size.height]
                    let inverse = transform.inverted()
                    result[variant] = try (request.results ?? []).map { pose in
                        try pose.recognizedPoints(.all).reduce(into:[String:[Double]]()) { row,item in
                            let p = item.value
                            let original = CGPoint(x: p.location.x*Double(width),y: p.location.y*Double(height)).applying(inverse)
                            row[item.key.rawValue.rawValue] = [
                                (rect.minX+original.x)/size.width,
                                1-(rect.minY+original.y)/size.height,Double(p.confidence)]
                        }
                    }
                }
            }
        }
        return result
    }
}
#endif
