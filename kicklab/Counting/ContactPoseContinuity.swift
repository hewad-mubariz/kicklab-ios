import Foundation

/// Corroborate an actually observed weak joint; never fill a missing landmark or
/// replace its position/confidence. Only eligibility rules consume this evidence.
nonisolated enum ContactPoseContinuity {
    static func corroborate(_ input: [FootPoseSample]) -> [FootPoseSample] {
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard Set(samples.map { $0.pose.timestampMs }).count == samples.count else { return input }
        return samples.enumerated().map { index, sample in
            guard index > 0, index+1 < samples.count else { return sample }
            let before = samples[index-1], after = samples[index+1]
            let duration = after.pose.timestampMs-before.pose.timestampMs
            guard duration > 0, duration <= 100 else { return sample }
            let views = [before,sample,after]
            guard views.allSatisfy({ p in
                [p.pose.width,p.pose.height,p.pose.imageAspect,p.pose.confidence].allSatisfy(\.isFinite)
                    && p.pose.width > 0 && p.pose.height > 0 && p.pose.imageAspect > 0 && p.pose.confidence >= 0.5
            }), views.map({ $0.pose.height }).max()! <= 1.35*views.map({ $0.pose.height }).min()!,
                views.map({ $0.pose.width }).max()! <= 1.35*views.map({ $0.pose.width }).min()! else { return sample }
            let fraction = Double(sample.pose.timestampMs-before.pose.timestampMs)/Double(duration)
            let diameter = max(sample.pose.width*sample.pose.imageAspect,sample.pose.height)
            var joints = sample.pose.joints
            var ankles = sample.corroboratedAnkles
            for side in BodySide.allCases {
                for joint in [side.wrist,side.knee,side.ankle] {
                    let anchor = joint == side.wrist ? side.shoulder : side.hip
                    guard let raw = sample.landmarks[joint], valid(raw), (0.1..<0.3).contains(raw.confidence),
                          let a = before.landmarks[joint], valid(a), a.confidence >= 0.4,
                          let c = after.landmarks[joint], valid(c), c.confidence >= 0.4,
                          let ah = before.pose.joints[anchor], valid(ah),
                          let h = sample.pose.joints[anchor], valid(h),
                          let ch = after.pose.joints[anchor], valid(ch) else { continue }
                    func distance(_ a: PosePoint, _ b: PosePoint) -> Double {
                        hypot((a.x-b.x)*sample.pose.imageAspect,a.y-b.y)
                    }
                    // A left/right identity swap or a jumping torso anchor is
                    // not continuity. Do not match a different limb by proximity.
                    guard max(distance(ah,h),distance(h,ch)) <= 0.25*diameter else { continue }
                    let expected = PosePoint(x:h.x+(a.x-ah.x)*(1-fraction)+(c.x-ch.x)*fraction,
                                             y:h.y+(a.y-ah.y)*(1-fraction)+(c.y-ch.y)*fraction)
                    guard distance(.init(x:raw.x,y:raw.y),expected) <= 0.2*diameter else { continue }
                    joints[joint] = .init(x:raw.x,y:raw.y)
                    if joint == side.ankle { ankles.insert(side) }
                }
            }
            let p = sample.pose
            return .init(pose:.init(timestampMs:p.timestampMs,ball:p.ball,width:p.width,height:p.height,
                confidence:p.confidence,imageAspect:p.imageAspect,joints:joints),ankles:sample.ankles,
                landmarks:sample.landmarks,corroboratedAnkles:ankles)
        }
    }
    private static func valid(_ p: PosePoint) -> Bool {
        p.x.isFinite && p.y.isFinite && (0...1).contains(p.x) && (0...1).contains(p.y)
    }
    private static func valid(_ p: PoseLandmark) -> Bool {
        valid(.init(x:p.x,y:p.y) as PosePoint) && p.confidence.isFinite && (0...1).contains(p.confidence)
    }
}
