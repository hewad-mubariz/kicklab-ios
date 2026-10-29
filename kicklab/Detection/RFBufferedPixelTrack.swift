import CoreImage
import CoreVideo
import Vision

/// Native image tracker, independently qualified on iOS. Vision is not the
/// desktop OpenCV LK implementation. Geometry, texture correlation and detector
/// age/motion guards all have to pass before its output can be shown.
nonisolated final class RFBufferedPixelTrack {
    var softConfidenceEnabled = false
    var detectorAgeSeconds = Double.infinity
    private(set) var diagnosticSoftConfidenceUsed = false
    private(set) var diagnosticFailure: String?
    private(set) var diagnosticConfidence: Float?
    private(set) var diagnosticScale: Double?
    private(set) var diagnosticCorrelation: Float?
    private(set) var diagnosticRect: CGRect?
    private var request: VNTrackObjectRequest?
    private var handler = VNSequenceRequestHandler()
    private var last: FollowHit?
    private var patch: [Float]?
    private let context = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly, .workingColorSpace: NSNull(), .cacheIntermediates: false])
    private var pixels: CVPixelBuffer?
    private func perform(_ request: VNTrackObjectRequest, image: CIImage) throws {
        let width=Int(image.extent.width), height=Int(image.extent.height)
        if pixels == nil || CVPixelBufferGetWidth(pixels!) != width || CVPixelBufferGetHeight(pixels!) != height {
            pixels=nil
            CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&pixels)
        }
        guard let pixels else { throw NSError(domain:"BallPixelTrack",code:1) }
        // Reuse an owned buffer instead of generating a new Vision CIImage
        // conversion surface for every high-frame-rate video sample.
        context.render(image,to:pixels)
        try handler.perform([request],on:pixels)
    }
    func reset() { request=nil; last=nil; patch=nil; handler=VNSequenceRequestHandler() }
    private func texture(_ image: CIImage, _ rect: CGRect, _ size: CGSize) -> [Float]? {
        let x=rect.minX/size.width*image.extent.width, y=(1-rect.maxY/size.height)*image.extent.height
        let r=CGRect(x:x,y:y,width:rect.width/size.width*image.extent.width,height:rect.height/size.height*image.extent.height)
        guard r.width > 0, r.height > 0 else { return nil }
        let patch=image.cropped(to:r).transformed(by:CGAffineTransform(translationX:-r.minX,y:-r.minY))
            .samplingLinear().transformed(by:CGAffineTransform(scaleX:16/r.width,y:16/r.height))
        var bytes=[UInt8](repeating:0,count:16*16*4)
        context.render(patch,toBitmap:&bytes,rowBytes:16*4,bounds:CGRect(x:0,y:0,width:16,height:16),format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB())
        return (0..<256).map { i -> Float in
            let red: Float = 0.299 * Float(bytes[4*i])
            let green: Float = 0.587 * Float(bytes[4*i+1])
            let blue: Float = 0.114 * Float(bytes[4*i+2])
            return (red + green) + blue
        }
    }
    func seed(_ hit: FollowHit, image: CIImage, size: CGSize) {
        // Return the previous Vision tracker to its pool before a detector
        // observation starts another sequence (Vision's documented lifecycle).
        if let request {
            request.isLastFrame=true
            try? perform(request,image:image)
        }
        reset()
        let r=hit.rect
        request=VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox:
            CGRect(x:r.minX/size.width,y:1-r.maxY/size.height,width:r.width/size.width,height:r.height/size.height)))
        // Revision 2 reached >500 MiB on the small airborne-ball replay.
        // Keep revision 1 for this opt-in mobile experiment; revision 2 remains
        // available only as an explicit developer comparison.
        request?.revision = ProcessInfo.processInfo.arguments.contains("--follow-vision-revision2")
            ? VNTrackObjectRequestRevision2 : VNTrackObjectRequestRevision1
        request?.trackingLevel = .accurate
        // Feed the seed frame so the next update really compares two frames.
        if let request {
            do {
                try VisionComputePolicy.configure(request)
                try perform(request,image:image)
            } catch { reset(); return }
        }
        last=hit; patch=texture(image,r,size)
    }
    func update(_ image: CIImage, size: CGSize) -> FollowHit? {
        diagnosticSoftConfidenceUsed=false; diagnosticFailure=nil; diagnosticConfidence=nil; diagnosticScale=nil; diagnosticCorrelation=nil; diagnosticRect=nil
        guard let request, let last, let old=patch else { diagnosticFailure="not_seeded"; return nil }
        do { try perform(request,image:image) } catch { reset(); diagnosticFailure="vision_error"; return nil }
        guard let result=request.results?.first as? VNDetectedObjectObservation else { reset(); diagnosticFailure="no_vision_result"; return nil }
        diagnosticConfidence=result.confidence
        guard result.confidence >= (softConfidenceEnabled ? 0.4 : 0.5) else { reset(); diagnosticFailure="low_vision_confidence"; return nil }
        let r=result.boundingBox
        let rect=CGRect(x:r.minX*size.width,y:(1-r.maxY)*size.height,width:r.width*size.width,height:r.height*size.height)
        diagnosticRect=rect
        let scale=max(rect.width,rect.height)/last.diameter
        diagnosticScale=scale
        guard (0.8...1.2).contains(scale) else { reset(); diagnosticFailure="scale"; return nil }
        guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= size.width, rect.maxY <= size.height else { reset(); diagnosticFailure="bounds"; return nil }
        guard let next=texture(image,rect,size) else { reset(); diagnosticFailure="texture_unavailable"; return nil }
        let a=old.reduce(0,+)/256, b=next.reduce(0,+)/256
        var aa: Float=0, bb: Float=0, ab: Float=0
        for i in 0..<256 { let x=old[i]-a,y=next[i]-b; aa+=x*x; bb+=y*y; ab+=x*y }
        guard aa/256 >= 9, bb/256 >= 9 else { reset(); diagnosticFailure="low_texture"; return nil }
        diagnosticCorrelation=ab/sqrt(aa*bb)
        guard ab/sqrt(aa*bb) >= 0.45 else { reset(); diagnosticFailure="texture_correlation"; return nil }
        guard GuardedTrackingConfidence.allows(result.confidence, correlation: ab/sqrt(aa*bb), detectorAge: detectorAgeSeconds, enabled: softConfidenceEnabled) else {
            reset(); diagnosticFailure="soft_confidence_evidence_insufficient"; return nil
        }
        diagnosticSoftConfidenceUsed=result.confidence < 0.5
        request.inputObservation=result
        let hit=FollowHit(rect:rect,score:last.score)
        self.last=hit; patch=next; return hit
    }
}
