import Foundation

/// Conservative evidence for a low foot contact when the body-box floor is
/// ambiguous. Three real ball observations must approach and leave the same
/// ankle. Relative coordinates remove body/camera translation; size stability,
/// timing and joint confidence are checked here. Unknown evidence cannot rescue a touch.
nonisolated enum FootContactRules {
    struct Sample: Codable, Equatable, Sendable {
        let timestampMs: Int
        let ballX, ballY, width, height, confidence: Double
        let ankles: [String: Point]
        var hips: [String: Point] = [:]
    }
    struct Point: Codable, Equatable, Sendable { let x, y: Double; var confidence: Double = 1 }
    static func confirms(before: Sample, contact: Sample, after: Sample) -> Bool {
        let samples = [before, contact, after]
        let beforeMS = contact.timestampMs - before.timestampMs
        let afterMS = after.timestampMs - contact.timestampMs
        guard (40...130).contains(beforeMS), (40...130).contains(afterMS),
              samples.allSatisfy({ s in
                  [s.ballX,s.ballY,s.width,s.height,s.confidence].allSatisfy(\.isFinite)
                      && s.width > 0 && s.height > 0 && s.confidence >= 0.5
              }) else { return false }
        let heights = samples.map(\.height), widths = samples.map(\.width)
        guard heights.max()! <= heights.min()! * 1.35,
              widths.max()! <= widths.min()! * 1.35 else { return false }
        for side in ["left", "right"] {
            guard let a = before.ankles[side], let b = contact.ankles[side], let c = after.ankles[side],
                  [a.x,a.y,a.confidence,b.x,b.y,b.confidence,c.x,c.y,c.confidence].allSatisfy(\.isFinite),
                  min(a.confidence, min(b.confidence,c.confidence)) >= 0.3 else { continue }
            guard let beforeHip = before.hips[side], let contactHip = contact.hips[side],
                  [beforeHip.x,beforeHip.y,beforeHip.confidence,contactHip.x,contactHip.y,contactHip.confidence].allSatisfy(\.isFinite),
                  min(beforeHip.confidence,contactHip.confidence) >= 0.3 else { continue }
            // A ball bouncing beside stationary feet has an approach/release arc
            // too. Require resolved foot motion relative to the same hip, so
            // camera translation or a whole-body shift cannot supply the kick.
            let footDX = ((b.x-contactHip.x)-(a.x-beforeHip.x)) / contact.width
            let footDY = ((b.y-contactHip.y)-(a.y-beforeHip.y)) / contact.height
            let incomingFootTravel = hypot(footDX,footDY)
            if incomingFootTravel < max(0.15,0.007/contact.height) {
                // A small kick can develop gradually through the impact. The
                // incoming half alone can be below the motion floor even when
                // the full contact window contains resolved foot travel.
                // Require confident joints and aligned movement on BOTH halves;
                // stationary feet, whole-body shifts and reversing pose jitter
                // must not supply the missing evidence.
                guard let afterHip = after.hips[side],
                      [afterHip.x,afterHip.y,afterHip.confidence].allSatisfy(\.isFinite),
                      [a.confidence,b.confidence,c.confidence,beforeHip.confidence,
                       contactHip.confidence,afterHip.confidence].allSatisfy({ $0 >= 0.5 }) else { continue }
                let releaseDX = ((c.x-afterHip.x)-(b.x-contactHip.x)) / contact.width
                let releaseDY = ((c.y-afterHip.y)-(b.y-contactHip.y)) / contact.height
                let outgoingFootTravel = hypot(releaseDX,releaseDY)
                let halfFloor = max(0.05,0.0035/contact.height)
                guard incomingFootTravel >= halfFloor, outgoingFootTravel >= halfFloor,
                      hypot(footDX+releaseDX,footDY+releaseDY) >= max(0.20,0.010/contact.height),
                      footDX*releaseDX+footDY*releaseDY >= 0.5*incomingFootTravel*outgoingFootTravel else { continue }
            }
            let dx = (contact.ballX - b.x) / contact.width
            let dy = (contact.ballY - b.y) / contact.height
            guard hypot(dx,dy) <= 0.75 else { continue }
            // A rolling ball passing alongside a moving foot is not an impact.
            // Require a resolved approach AND separation in ball diameters.
            let incoming = ((contact.ballY-b.y) - (before.ballY-a.y)) / contact.height
            let outgoing = ((contact.ballY-b.y) - (after.ballY-c.y)) / contact.height
            if incoming >= max(0.35,0.007/contact.height) && outgoing >= max(0.12,0.007/contact.height) { return true }
        }
        return false
    }
}

nonisolated struct FootContactEvidence: Codable, Equatable, Sendable {
    let before, contact, after: FootContactRules.Sample
    var confirms: Bool { FootContactRules.confirms(before: before, contact: contact, after: after) }
}
