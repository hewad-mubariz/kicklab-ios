import AVFoundation
import CoreGraphics
import Vision

nonisolated struct StadiumSceneCalibration {
    let crop: CGRect
    let camera: SceneCameraRig

    static func make(asset: AVAsset, start: Double = 0, duration: Double, size: CGSize,
                     maximumFrameRate: Double = 60,
                     onProgress: @Sendable (Double) async -> Void = { _ in }) async throws -> Self {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ForegroundMaskProcessor.Failure.invalidFrame
        }
        // Inspect every prepared timestamp. Sparse stills miss the widest part
        // of a kick and turn a soft segmentation error into a hard crop edge.
        let fullDuration = try await asset.load(.duration)
        let composition = try await EffectVideoGeometry.composition(track: track, duration: fullDuration, shortEdge: 720)
        let fps = try await track.load(.nominalFrameRate)
        composition.frameDuration = CMTime(seconds: 1 / min(maximumFrameRate,Double(fps > 0 ? fps : 30)), preferredTimescale: 60_000)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition; output.alwaysCopiesSampleData = false
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000), duration: CMTime(seconds: duration, preferredTimescale: 60_000))
        guard reader.startReading() else { throw reader.error ?? ForegroundMaskProcessor.Failure.invalidFrame }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        var region = CGRect.null, people: [CGRect] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
              guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw ForegroundMaskProcessor.Failure.invalidFrame }
              try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
              if let raw = request.results?.first?.pixelBuffer {
                // Distant spectators must not widen the action crop or move
                // the camera ground estimate away from the dominant player.
                let mask = try DetailedForegroundMaskProcessor.bodyComponent(raw)
                CVPixelBufferLockBaseAddress(mask, .readOnly)
                let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), row = CVPixelBufferGetBytesPerRow(mask)
                let bytes = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
                var minX = w, maxX = 0, minY = h, maxY = 0
                for y in 0..<h {
                    var xs: [Int] = []
                    // Include visible soft motion coverage in the envelope.
                    for x in 0..<w where bytes[y*row+x] > 32 { xs.append(x) }
                    if xs.count >= max(3,w/150) {
                        minX = min(minX,xs.first!); maxX = max(maxX,xs.last!)
                        minY = min(minY,y); maxY = max(maxY,y)
                    }
                }
                CVPixelBufferUnlockBaseAddress(mask, .readOnly)
                if maxX > minX, maxY > minY {
                    let bounds = CGRect(x: Double(minX)/Double(w), y: Double(minY)/Double(h),
                        width: Double(maxX-minX+1)/Double(w), height: Double(maxY-minY+1)/Double(h))
                    people.append(bounds); region = region.union(bounds)
                }
              }
            }
            await onProgress(min(1, (CMSampleBufferGetPresentationTimeStamp(sample).seconds-start)/max(0.001,duration)))
        }
        guard reader.status == .completed else { throw reader.error ?? ForegroundMaskProcessor.Failure.invalidFrame }
        guard !people.isEmpty else {
            throw StadiumPreviewRenderer.Failure.unavailable("We couldn’t find a player in this clip. Try a video with your full body visible.")
        }
        // Even the guide can underestimate blurred extremities. Keep padding
        // around the complete sequence's envelope, not just the initial pose.
        let crop = region.insetBy(dx: -max(0.025,region.width*0.15), dy: -max(0.02,region.height*0.10))
            .intersection(CGRect(x:0,y:0,width:1,height:1))
        let floors = people.map(\.maxY).sorted(), heights = people.map(\.height).sorted(), centers = people.map(\.midX).sorted()
        var rig = SceneCameraRig(aspect:Float(size.width/size.height), subjectHeight:Float(heights[heights.count/2]),
            ground:SIMD2(Float(centers[centers.count/2]),Float(floors[min(floors.count-1,Int(Double(floors.count)*0.8))])))
        rig.stadiumFraming=true
        return Self(crop:crop,camera:rig)
    }
}
