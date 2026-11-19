import Foundation

/// Prototype-only admission for an auxiliary pose; it never counts a touch.
nonisolated enum ToePlayerAssociation {
    static func sameObservedPlayer(_ selections: [ActivePlayerSelection?]) -> Bool {
        guard selections.count == 3, let first = selections[0], let identity = first.id else { return false }
        return selections.allSatisfy {
            guard let s = $0, let box = s.box else { return false }
            return s.id == identity && s.state == .locked && s.observed && s.peopleCount > 0 && box.isUsable
        }
    }

    static func index(in poses: [BodyPose], selection: ActivePlayerSelection?) -> Int? {
        guard let selection, selection.state == .locked, selection.observed,
              let box = selection.box,
              let index = ActivePlayerPoseMatcher.index(in: poses, selection: selection) else { return nil }
        guard selection.peopleCount > 1 else { return index }
        // A small spectator inside a foreground box must not supply its feet.
        // Require a resolved torso with scale compatible with the selected box.
        let names: [BodyJoint] = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let points = names.compactMap { poses[index].landmarks[$0] }
        guard points.count == 4, points.allSatisfy({
            $0.x.isFinite && $0.y.isFinite && $0.confidence >= 0.5 &&
            abs($0.x-box.x) <= box.width*0.58 && $0.y >= box.y-box.height*0.58 && $0.y <= box.bottom
        }) else { return nil }
        let shoulders = (points[0].y+points[1].y)/2
        let hips = (points[2].y+points[3].y)/2
        guard abs(hips-shoulders) >= box.height*0.15,
              abs(points[0].x-points[1].x) >= box.width*0.12 else { return nil }
        return index
    }
}
