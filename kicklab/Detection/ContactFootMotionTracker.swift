import CoreVideo
import Foundation
import Vision

/// Candidate-only pixel evidence. Requests and buffers are released per pair;
/// failures return no evidence and never change the original pose/hand caches.
nonisolated enum ContactFootMotionTracker {
    typealias Observation = TrackedFootContactRules.Observation
    static func track(_ frames: [ContactObservationStore.Frame], plan: TrackedFootContactRules.Plan) throws -> [Observation] {
        let views = frames.filter { $0.timestampMs >= plan.seedMs }.sorted { $0.timestampMs < $1.timestampMs }
        guard let first = views.first, first.timestampMs == plan.seedMs, (4...7).contains(views.count) else { return [] }
        let aspect = Double(CVPixelBufferGetWidth(first.pixels))/Double(CVPixelBufferGetHeight(first.pixels))
        let diameter = max(first.ball.height,first.ball.width*aspect)
        let spacing = min(0.02,max(0.008,0.1*diameter))
        var points: [PosePoint] = []
        for y in -1...1 { for x in -1...1 {
            let p = PosePoint(x:plan.seed.x+Double(x)*spacing/aspect,y:plan.seed.y+Double(y)*spacing)
            guard (0...1).contains(p.x), (0...1).contains(p.y) else { return [] }
            points.append(p)
        } }
        var result: [Observation] = [.init(timestampMs:first.timestampMs,point:plan.seed,roundTripError:0,
            spread:spacing,retainedPoints:points.count)]
        for i in 1..<views.count {
            let a = views[i-1], b = views[i]
            guard (1...85).contains(b.timestampMs-a.timestampMs) else { return [] }
            let next: Observation? = try autoreleasepool {
                let forward = try flow(a.pixels,b.pixels), backward = try flow(b.pixels,a.pixels)
                var mapped: [PosePoint] = [], errors: [Double] = []
                for p in points {
                    guard let d = motion(forward,at:p) else { continue }
                    let q = PosePoint(x:p.x+d.x,y:p.y+d.y)
                    guard let back = motion(backward,at:q) else { continue }
                    let error = hypot((d.x+back.x)*aspect,d.y+back.y)
                    mapped.append(q); errors.append(error)
                }
                guard mapped.count >= 6 else { return nil }
                let center = PosePoint(x:median(mapped.map(\.x)),y:median(mapped.map(\.y)))
                let spread = median(mapped.map { hypot(($0.x-center.x)*aspect,$0.y-center.y) })
                points = mapped
                return .init(timestampMs:b.timestampMs,point:center,roundTripError:median(errors),
                             spread:spread,retainedPoints:errors.filter { $0 <= 0.08*diameter }.count)
            }
            guard let next else { return [] }
            result.append(next)
        }
        return result
    }
    private static func flow(_ a: CVPixelBuffer,_ b: CVPixelBuffer) throws -> CVPixelBuffer {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer:b,options:[:])
        request.computationAccuracy = .veryHigh
        try VisionComputePolicy.configure(request)
        try VNImageRequestHandler(cvPixelBuffer:a).perform([request])
        guard let result = request.results?.first else { throw Failure.missingFlow }
        return result.pixelBuffer
    }
    private enum Failure: Error { case missingFlow }
    private static func motion(_ flow: CVPixelBuffer,at point: PosePoint) -> PosePoint? {
        guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y),
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(flow,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow,.readOnly) }
        let w = CVPixelBufferGetWidth(flow), h = CVPixelBufferGetHeight(flow)
        let x = min(w-1,Int(point.x*Double(w))), y = min(h-1,Int(point.y*Double(h)))
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return nil }
        let row = base.advanced(by:y*CVPixelBufferGetBytesPerRow(flow)).assumingMemoryBound(to:Float.self)
        let dx = Double(row[2*x])/Double(w), dy = Double(row[2*x+1])/Double(h)
        guard dx.isFinite, dy.isFinite else { return nil }
        return .init(x:dx,y:dy)
    }
    private static func median(_ values: [Double]) -> Double { let s = values.sorted(); return s[s.count/2] }
}
