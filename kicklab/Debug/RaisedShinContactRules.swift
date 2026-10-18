#if DEBUG
import Foundation

/// Experimental positive contact evidence for a raised shin. Hidden hands never
/// supply evidence. Require a measured hip/knee/ankle and ball approach/release.
nonisolated enum RaisedShinContactRules {
    static func contactTime(_ input: [FootPoseSample], at time: Int) -> Int? {
        let samples = input.sorted { $0.pose.timestampMs < $1.pose.timestampMs }
        guard (3...9).contains(samples.count), Set(samples.map { $0.pose.timestampMs }).count == samples.count,
              samples.contains(where: { $0.pose.timestampMs == time }),
              samples.allSatisfy({ (-201...201).contains($0.pose.timestampMs-time) && $0.pose.confidence >= 0.5 }),
              TemporalContactEvidence.supportsBallTrack(samples.map(\.pose)) else { return nil }
        for contact in samples where (0...101).contains(contact.pose.timestampMs-time) {
            for side in BodySide.allCases {
                guard let b = geometry(contact,side: side) else { continue }
                let diameter = max(contact.pose.width*contact.pose.imageAspect,contact.pose.height)
                guard b.distance <= diameter/2+0.12*b.length else { continue }
                for before in samples where (40...201).contains(contact.pose.timestampMs-before.pose.timestampMs) {
                    for after in samples where (33...151).contains(after.pose.timestampMs-contact.pose.timestampMs)
                        && after.pose.timestampMs-before.pose.timestampMs <= 301 {
                        guard let a = geometry(before,side: side), let c = geometry(after,side: side),
                              TemporalContactEvidence.stableSize([before,contact,after].map(\.pose)),
                              max(a.length,b.length,c.length) <= 1.35*min(a.length,b.length,c.length),
                              distance(a.hip,b.hip) <= 0.5*diameter, distance(c.hip,b.hip) <= 0.5*diameter,
                              distance(a.knee,b.knee) <= diameter, distance(c.knee,b.knee) <= diameter,
                              distance(a.ankle,b.ankle) <= diameter, distance(c.ankle,b.ankle) <= diameter,
                              a.distance-b.distance >= 0.15*diameter,
                              c.distance-b.distance >= 0.10*diameter else { continue }
                        return contact.pose.timestampMs
                    }
                }
            }
        }
        return nil
    }
    private struct Geometry {
        let hip,knee,ankle: PosePoint
        let length,distance: Double
    }
    private static func geometry(_ sample: FootPoseSample,side: BodySide) -> Geometry? {
        let p = sample.pose, aspect = p.imageAspect
        guard aspect.isFinite, aspect > 0 else { return nil }
        func point(_ name: BodyJoint,minimum: Double) -> PosePoint? {
            guard let q = sample.landmarks[name], [q.x,q.y,q.confidence].allSatisfy(\.isFinite),
                  (0...1).contains(q.x), (0...1).contains(q.y), (minimum...1).contains(q.confidence) else { return nil }
            return .init(x: q.x*aspect,y: q.y)
        }
        guard let hip = point(side.hip,minimum: 0.3), let knee = point(side.knee,minimum: 0.4),
              let ankle = point(side.ankle,minimum: 0.4) else { return nil }
        let length = distance(knee,ankle), diameter = max(p.width*aspect,p.height)
        guard (0.08...0.5).contains(length), diameter <= 1.6*length,
              max(knee.y,ankle.y)+max(0.15*length,0.5*diameter) < hip.y,
              p.ball.y+diameter < hip.y else { return nil }
        let ball = PosePoint(x: p.ball.x*aspect,y: p.ball.y)
        let dx = ankle.x-knee.x, dy = ankle.y-knee.y
        let along = ((ball.x-knee.x)*dx+(ball.y-knee.y)*dy)/(length*length)
        guard (-0.15...1.15).contains(along) else { return nil }
        let nearest = PosePoint(x: knee.x+max(0,min(1,along))*dx,y: knee.y+max(0,min(1,along))*dy)
        guard ball.y <= nearest.y+0.1*diameter else { return nil }
        // Actual confident arms near this ball block the recovery, including
        // arms newly visible in the crop. Missing arms do not establish a veto.
        for handSide in BodySide.allCases {
            if let wrist = point(handSide.wrist,minimum: 0.5), let elbow = point(handSide.elbow,minimum: 0.5),
               distance(ball,wrist) <= diameter/2+0.4*distance(elbow,wrist) { return nil }
        }
        return .init(hip: hip,knee: knee,ankle: ankle,length: length,distance: distance(ball,nearest))
    }
    private static func distance(_ a: PosePoint,_ b: PosePoint) -> Double { hypot(a.x-b.x,a.y-b.y) }
}
#endif
