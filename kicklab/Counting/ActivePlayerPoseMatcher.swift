import Foundation

/// Match observed torso/head anchors to the selected detector box. Never splice
/// joints from different people or synthesize missing knees/ankles.
nonisolated enum ActivePlayerPoseMatcher {
    static func index(in poses: [BodyPose], selection: ActivePlayerSelection?) -> Int? {
        guard let selection else { return poses.count == 1 ? 0 : nil } // historical replay
        guard selection.canMatchPose, let box = selection.box else { return nil }
        let ranked = poses.indices.map { ($0, score(poses[$0], box: box)) }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= 0.55,
              ranked.count == 1 || best.1-ranked[1].1 >= 0.15 else { return nil }
        return best.0
    }

    static func score(_ pose: BodyPose, box: PersonBox) -> Double {
        let anchors: [BodyJoint] = [.nose,.leftShoulder,.rightShoulder,.leftHip,.rightHip]
        let points = anchors.compactMap { pose.joints[$0] }
        guard points.count >= 2 else { return 0 }
        let inside = points.filter {
            abs($0.x-box.x) <= box.width*0.58 && $0.y >= box.y-box.height*0.58 && $0.y <= box.bottom
        }
        guard inside.count >= 2 else { return 0 }
        let coverage = Double(inside.count)/Double(points.count)
        let centerX = points.map(\.x).reduce(0,+)/Double(points.count)
        // Head/torso usually occupy the upper part of the person's measured box.
        // Do not assume a standing pose: seated players can have short boxes.
        return coverage*0.80 + max(0,1-abs(centerX-box.x)/box.width)*0.20
    }
}
