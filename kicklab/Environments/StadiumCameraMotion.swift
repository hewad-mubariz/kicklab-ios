import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision
import simd

/// A conservative image-registration estimate, not a recovered six-DoF camera.
/// Register a fixed background-only strip so a kick cannot turn the stadium.
nonisolated final class StadiumCameraMotion {
    let region: CGRect?
    private let context: CIContext
    private var previous: CVPixelBuffer?
    private var accumulated = SIMD2<Float>.zero
    private let aspect: Float
    private let tanHalfFOV: Float

    init(personCrop:CGRect,context:CIContext,camera:SceneCameraRig) {
        self.context=context;aspect=camera.aspect;tanHalfFOV=camera.tanHalfFOV
        region=Self.backgroundRegion(excluding:personCrop)
    }
    static func backgroundRegion(excluding p:CGRect)->CGRect? {
        [CGRect(x:0,y:0,width:1,height:p.minY),
         CGRect(x:0,y:p.maxY,width:1,height:1-p.maxY),
         CGRect(x:0,y:0,width:p.minX,height:1),
         CGRect(x:p.maxX,y:0,width:1-p.maxX,height:1)]
            .filter {$0.width>=0.12 && $0.height>=0.12}
            .max {$0.width*$0.height<$1.width*$1.height}
    }
    func update(_ source:CVPixelBuffer) throws -> SIMD2<Float> {
        guard let region else {return .zero}
        let width=CGFloat(CVPixelBufferGetWidth(source)),height=CGFloat(CVPixelBufferGetHeight(source))
        let rect=CGRect(x:region.minX*width,y:(1-region.maxY)*height,width:region.width*width,height:region.height*height)
        let image=CIImage(cvPixelBuffer:source).cropped(to:rect)
            .transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
        let scale=256/max(rect.width,rect.height)
        let w=max(32,Int(rect.width*scale)),h=max(32,Int(rect.height*scale))
        let current=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_32BGRA)
        context.render(image.transformed(by:CGAffineTransform(scaleX:CGFloat(w)/rect.width,y:CGFloat(h)/rect.height)),to:current)
        defer {previous=current}
        guard let previous else {return .zero}
        let request=VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer:current)
        do {try VNImageRequestHandler(cvPixelBuffer:previous).perform([request])}
        catch {return accumulated}
        guard let alignment=request.results?.first as? VNImageTranslationAlignmentObservation else {return accumulated}
        let t=alignment.alignmentTransform
        let imageShift=SIMD2(Float(-t.tx/CGFloat(w)*region.width),Float(t.ty/CGFloat(h)*region.height))
        accumulated=Self.integrate(accumulated,imageShift:imageShift,aspect:aspect,tanHalfFOV:tanHalfFOV)
        return accumulated
    }
    static func integrate(_ previous:SIMD2<Float>,imageShift:SIMD2<Float>,aspect:Float,tanHalfFOV:Float)->SIMD2<Float> {
        guard imageShift.x.isFinite,imageShift.y.isFinite,simd_length(imageShift)<0.045 else {return previous}
        // Content moving right means the camera looked left (positive yaw).
        let delta=SIMD2(imageShift.x*2*tanHalfFOV*aspect,imageShift.y*2*tanHalfFOV)
        return simd_clamp(previous+delta,SIMD2(repeating:-0.25),SIMD2(repeating:0.25))
    }
}

nonisolated struct StadiumSceneRecording: Codable, Sendable {
    struct Frame: Codable, Sendable {
        let time: Double
        let contact: VisibleFootContact?
        let pan: SIMD2<Float>
    }
    let camera: SceneCameraRig
    let frames: [Frame]
    var sourceRect: CGRect? = nil
    /// Version 2 stores refined alpha and linear-premultiplied, decontaminated
    /// foreground color encoded as SDR. Original background RGB is not cached.
    var matteVersion: Int? = nil
    var temporalRefinement: Bool? = nil
    var personRefinement: String? = nil
    var losslessAlpha: Bool? = nil
    func sample(at time:Double)->SceneCameraRig {
        var result=camera
        guard !frames.isEmpty else {return result}
        var lo=0,hi=frames.count
        while lo<hi {let mid=(lo+hi)/2;if frames[mid].time<time {lo=mid+1}else {hi=mid}}
        let i=min(frames.count-1,lo)
        let best=i>0 && abs(frames[i-1].time-time)<abs(frames[i].time-time) ? i-1:i
        result.contact=frames[best].contact;result.recordedPan=frames[best].pan
        result.movement=0
        return result
    }
}
