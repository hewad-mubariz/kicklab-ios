#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import Vision

/// Experimental, lazy selected-player augmentation. A recovered whole pose is
/// used only for positive shin evidence, never to replace hand/ground observations.
nonisolated final class SelectedPlayerPoseRecovery {
    private let context = CIContext(options: [.useSoftwareRenderer: VideoWorkExecution.cpuOnly])
    private let request = VNDetectHumanBodyPoseRequest()
    private var attempted: Set<Int> = []
    private var cache: [Int: BodyPose] = [:]
    private(set) var requests = 0
    private(set) var recovered = 0
    private(set) var milliseconds = 0.0
    private var available = true
    init() {
        do { try VisionComputePolicy.configure(request) }
        catch { available = false }
    }
    func reset() { attempted.removeAll(); cache.removeAll(); requests = 0; recovered = 0; milliseconds = 0; context.clearCaches() }
    func retain(_ indices: Set<Int>) {
        attempted.formIntersection(indices); cache = cache.filter { indices.contains($0.key) }
    }

    static func direction(baseline: BodyPose, player: ActivePlayerSelection?, aspect: Double) -> Double? {
        guard let player, player.canMatchPose, player.state == .locked, player.observed, let box = player.box,
              aspect.isFinite, aspect > 0, box.isUsable,
              box.width*aspect >= 1.15*box.height,
              let nose = baseline.joints[.nose], baseline.joints[.leftShoulder] != nil,
              baseline.joints[.rightShoulder] != nil,
              abs(nose.x-box.x) >= 0.18*box.width else { return nil }
        return nose.x < box.x ? 1 : -1
    }
    static func legScore(_ pose: BodyPose) -> Double {
        BodySide.allCases.map { side in
            let chain = [side.hip,side.knee,side.ankle].compactMap { pose.landmarks[$0] }
            guard chain.count == 3, chain.allSatisfy({ $0.confidence >= 0.3 }) else { return 0.0 }
            return chain.map(\.confidence).reduce(0,+)
        }.max() ?? 0
    }
    static func matches(_ pose: BodyPose, baseline: BodyPose, box: PersonBox, aspect: Double) -> Bool {
        [BodyJoint.nose,.leftShoulder,.rightShoulder].allSatisfy { name in
            guard let a = pose.joints[name], let b = baseline.joints[name] else { return false }
            return hypot((a.x-b.x)*aspect,a.y-b.y) <= 0.18*box.height
        }
    }
    static func index(in poses: [BodyPose],baseline: BodyPose,player: ActivePlayerSelection?,aspect: Double) -> Int? {
        guard let box = player?.box else { return nil }
        // Crop overlap is not a new identity decision. Match all three observed
        // head/shoulder anchors from this same exposure before ranking boxes.
        // Multiple matching observations still fail the normal ambiguity margin.
        let eligible = poses.indices.filter { matches(poses[$0],baseline: baseline,box: box,aspect: aspect) }
        guard let selected = ActivePlayerPoseMatcher.index(in: eligible.map { poses[$0] },selection: player) else { return nil }
        return eligible[selected]
    }
    func pose(for frame: ContactObservationStore.Frame, baseline: BodyPose) -> BodyPose? {
        guard available else { return nil }
        if attempted.contains(frame.index) { return cache[frame.index] }
        attempted.insert(frame.index)
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixels),height: CVPixelBufferGetHeight(frame.pixels))
        let aspect = size.width/size.height
        guard let direction = Self.direction(baseline: baseline,player: frame.player,aspect: aspect),
              let box = frame.player?.box else { return nil }
        let start = ProcessInfo.processInfo.systemUptime
        defer { milliseconds += (ProcessInfo.processInfo.systemUptime-start)*1000 }
        let input = CIImage(cvPixelBuffer: frame.pixels)
        let normalized = CGRect(x: box.x-box.width*0.6,y: box.y-box.height*0.6,
                                width: box.width*1.2,height: box.height*1.2)
            .intersection(CGRect(x: 0,y: 0,width: 1,height: 1))
        let rect = CGRect(x: normalized.minX*size.width,y: (1-normalized.maxY)*size.height,
                          width: normalized.width*size.width,height: normalized.height*size.height)
            .integral.intersection(input.extent)
        guard !rect.isEmpty else { return nil }
        let crop = input.cropped(to: rect).transformed(by: .init(translationX: -rect.minX,y: -rect.minY))
        // Fixed bounded search; choose one whole observation, never combine
        // legs/hips from different rotations or borrow another person's limbs.
        for degrees in [60.0,30.0] {
            let rotation = CGAffineTransform(rotationAngle: -direction*degrees * .pi/180)
            let bounds = crop.transformed(by: rotation).extent
            let scale = 512/max(bounds.width,bounds.height)
            let transform = rotation.concatenating(.init(translationX: -bounds.minX,y: -bounds.minY))
                .concatenating(.init(scaleX: scale,y: scale))
            let rendered = crop.transformed(by: transform)
            let width = Int(rendered.extent.width), height = Int(rendered.extent.height)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer) == kCVReturnSuccess,
                  let buffer else { continue }
            context.render(rendered,to: buffer)
            do {
                requests += 1
                try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
                let inverse = transform.inverted()
                let poses = try (request.results ?? []).prefix(8).map { observation -> BodyPose in
                    let points = try observation.recognizedPoints(.all)
                    let names: [(BodyJoint,VNHumanBodyPoseObservation.JointName)] = [
                        (.nose,.nose),(.leftShoulder,.leftShoulder),(.rightShoulder,.rightShoulder),
                        (.leftHip,.leftHip),(.rightHip,.rightHip),(.leftKnee,.leftKnee),(.rightKnee,.rightKnee),
                        (.leftAnkle,.leftAnkle),(.rightAnkle,.rightAnkle),(.leftElbow,.leftElbow),
                        (.rightElbow,.rightElbow),(.leftWrist,.leftWrist),(.rightWrist,.rightWrist)]
                    var result = BodyPose()
                    for (name,joint) in names {
                        guard let p = points[joint], p.confidence > 0 else { continue }
                        let q = CGPoint(x: p.location.x*Double(width),y: p.location.y*Double(height)).applying(inverse)
                        let x = (rect.minX+q.x)/size.width, y = 1-(rect.minY+q.y)/size.height
                        guard (0...1).contains(x), (0...1).contains(y) else { continue }
                        let landmark = PoseLandmark(x: x,y: y,confidence: Double(p.confidence))
                        result.landmarks[name] = landmark
                        if p.confidence >= 0.3 { result.joints[name] = .init(x: x,y: y) }
                        for side in BodySide.allCases {
                            if name == side.ankle { result.ankles[side] = landmark }
                            if name == side.hip { result.hips[side] = landmark }
                            if name == side.wrist { result.wrists[side] = landmark }
                        }
                    }
                    return result
                }
                guard let index = Self.index(in: poses,baseline: baseline,player: frame.player,aspect: aspect),
                      Self.legScore(poses[index]) > 0 else { continue }
                cache[frame.index] = poses[index]; recovered += 1
                return poses[index]
            } catch { continue } // An optional recovery cannot invalidate normal evidence.
        }
        return nil
    }
}
#endif
