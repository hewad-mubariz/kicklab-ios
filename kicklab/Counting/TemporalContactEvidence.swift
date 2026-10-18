import Foundation

/// Bounded corroboration of measured evidence. This never fabricates a joint,
/// changes detector confidence, or supplies a touch without a contact rule.
nonisolated enum TemporalContactEvidence {
    static func corroborateWrists(_ input: [FootPoseSample]) -> [FootPoseSample] {
        let sorted = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (5...7).contains(sorted.count), Set(sorted.map { $0.pose.timestampMs }).count == sorted.count else { return input }
        var result = sorted
        for start in 0...(sorted.count-5) {
            for end in (start+5)...sorted.count {
                let window = corroborateWristWindow(Array(sorted[start..<end]))
                for (offset, sample) in window.enumerated() {
                    let index = start+offset, original = result[index], p = original.pose
                    let joints = p.joints.merging(sample.pose.joints) { existing,_ in existing }
                    result[index] = .init(pose:.init(timestampMs:p.timestampMs,ball:p.ball,width:p.width,height:p.height,
                        confidence:p.confidence,imageAspect:p.imageAspect,joints:joints),ankles:original.ankles,
                        landmarks:original.landmarks,corroboratedAnkles:original.corroboratedAnkles)
                }
            }
        }
        return result
    }

    private static func corroborateWristWindow(_ input: [FootPoseSample]) -> [FootPoseSample] {
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (5...7).contains(samples.count),
              Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              let first = samples.first, let last = samples.last,
              (100...230).contains(last.pose.timestampMs-first.pose.timestampMs),
              samples.allSatisfy({ validBall($0.pose) && $0.pose.confidence >= 0.5 }),
              stableSize(samples.map(\.pose)) else { return input }
        let diameter = samples.map { max($0.pose.height,$0.pose.width*$0.pose.imageAspect) }.min()!
        var supported: Set<BodySide> = []
        for side in BodySide.allCases {
            // Every observation must contain the same measured wrist and a
            // reliable elbow/shoulder. An absent or jumping wrist breaks the
            // track, even if a clearer hand appears later.
            var relative: [PosePoint] = []
            var confidence: [Double] = []
            for sample in samples {
                guard let wrist = point(sample,side.wrist,minimum:0.15),
                      let elbow = point(sample,side.elbow), let shoulder = point(sample,side.shoulder),
                      let measured = sample.landmarks[side.wrist] else { break }
                let upperArm = distance(shoulder,elbow), forearm = distance(elbow,wrist)
                guard upperArm > 0.02, (0.35...1.5).contains(forearm/upperArm) else { break }
                relative.append(.init(x:wrist.x-elbow.x,y:wrist.y-elbow.y))
                confidence.append(measured.confidence)
            }
            guard relative.count == samples.count,
                  confidence.filter({ $0 >= 0.3 }).count >= 2,
                  confidence.contains(where: { $0 >= 0.4 }) else { continue }
            let continuous = (1..<samples.count).allSatisfy { i in
                samples[i].pose.timestampMs-samples[i-1].pose.timestampMs <= 50
                    && distance(relative[i],relative[i-1]) <= 0.2*diameter
            }
            if continuous, relative.allSatisfy({ a in relative.allSatisfy { distance(a,$0) <= 0.5*diameter } }) {
                supported.insert(side)
            }
        }
        return samples.map { sample in
            var joints = sample.pose.joints
            for side in supported {
                if let wrist = sample.landmarks[side.wrist] {
                    joints[side.wrist] = .init(x:wrist.x,y:wrist.y)
                }
            }
            let p = sample.pose
            return .init(pose:.init(timestampMs:p.timestampMs,ball:p.ball,width:p.width,height:p.height,
                confidence:p.confidence,imageAspect:p.imageAspect,joints:joints),ankles:sample.ankles,
                landmarks:sample.landmarks,corroboratedAnkles:sample.corroboratedAnkles)
        }
    }

    /// A single marginal, horizontally clipped ball can be supported by two
    /// strong adjacent detections. Its measured box and score remain untouched.
    static func supportsBallTrack(_ samples: [ContactPoseSample]) -> Bool {
        guard samples.allSatisfy(validBall) else { return false }
        let weak = samples.filter { $0.confidence < 0.5 }
        if weak.isEmpty { return true }
        guard weak.count == 1, let contact = weak.first, contact.confidence >= 0.4,
              horizontalEdge(contact) != nil,
              let before = samples.filter({ $0.timestampMs < contact.timestampMs }).max(by: { $0.timestampMs < $1.timestampMs }),
              let after = samples.filter({ $0.timestampMs > contact.timestampMs }).min(by: { $0.timestampMs < $1.timestampMs }),
              before.confidence >= 0.75, after.confidence >= 0.75,
              contact.timestampMs-before.timestampMs <= 70, after.timestampMs-contact.timestampMs <= 70,
              after.timestampMs-before.timestampMs <= 100,
              stableSize([before,contact,after]) else { return false }
        let diameter = max(contact.height,contact.width*contact.imageAspect)
        let fraction = Double(contact.timestampMs-before.timestampMs)/Double(after.timestampMs-before.timestampMs)
        let expectedX = before.ball.x+(after.ball.x-before.ball.x)*fraction
        return abs(contact.ball.x-expectedX)*contact.imageAspect <= 0.2*diameter
            && distance(ball(before),ball(contact)) <= diameter
            && distance(ball(after),ball(contact)) <= diameter
    }

    static func stableSize(_ views: [ContactPoseSample]) -> Bool {
        guard !views.isEmpty, views.allSatisfy(validBall),
              views.map(\.height).max()! <= 1.35*views.map(\.height).min()! else { return false }
        if views.map(\.width).max()! <= 1.35*views.map(\.width).min()! { return true }
        // Clipping changes visible width, not the ball's vertical diameter.
        // Require the same image edge in every view; never excuse a central
        // box-size jump or a switch to a different ball across the image.
        guard let edge = horizontalEdge(views[0]) else { return false }
        return views.allSatisfy { horizontalEdge($0) == edge
            && (0.5...1.35).contains($0.width*$0.imageAspect/$0.height) }
    }

    static func stableSupport(_ views: [FootPoseSample], side: BodySide, diameter: Double) -> Bool {
        // A turned player may hide one hip. Use one consistently visible hip
        // in all three views, with stronger confidence, rather than inventing
        // the hidden half of a pelvis center.
        guard views.contains(where: { point($0,.leftHip) == nil || point($0,.rightHip) == nil }) else { return false }
        for hip in [BodyJoint.leftHip,.rightHip] {
            let offsets = views.compactMap { view -> PosePoint? in
                guard let ankle = point(view,side.ankle,minimum:0.5),
                      let anchor = point(view,hip,minimum:0.4) else { return nil }
                return .init(x:ankle.x-anchor.x,y:ankle.y-anchor.y)
            }
            if offsets.count == views.count,
               offsets.allSatisfy({ a in offsets.allSatisfy { distance(a,$0) <= 0.2*diameter } }) { return true }
        }
        return false
    }

    private static func horizontalEdge(_ p: ContactPoseSample) -> Int? {
        if p.ball.x-p.width/2 <= 0.01 { return -1 }
        if p.ball.x+p.width/2 >= 0.99 { return 1 }
        return nil
    }
    private static func validBall(_ p: ContactPoseSample) -> Bool {
        [p.ball.x,p.ball.y,p.width,p.height,p.confidence,p.imageAspect].allSatisfy(\.isFinite)
            && (0...1).contains(p.ball.x) && (0...1).contains(p.ball.y)
            && p.width > 0 && p.width <= 1 && p.height > 0 && p.height <= 1
            && (0...1).contains(p.confidence) && p.imageAspect > 0
    }
    private static func point(_ s: FootPoseSample, _ joint: BodyJoint, minimum: Double = 0.3) -> PosePoint? {
        guard let p = s.landmarks[joint], [p.x,p.y,p.confidence].allSatisfy(\.isFinite),
              (0...1).contains(p.x), (0...1).contains(p.y), (minimum...1).contains(p.confidence) else { return nil }
        return .init(x:p.x*s.pose.imageAspect,y:p.y)
    }
    private static func ball(_ p: ContactPoseSample) -> PosePoint { .init(x:p.ball.x*p.imageAspect,y:p.ball.y) }
    private static func distance(_ a: PosePoint, _ b: PosePoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
