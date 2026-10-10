//
//  BallPlausibility.swift
//  kicklab
//
//  Reject detections that cannot be the ball we have been watching.
//
//  Measured from a real run that miscounted: a large stationary object in the
//  room scored 0.05-0.13 as a ball, 21 times, always at x 0.29 y 0.13, with a box
//  0.53 of frame width against the real ball's 0.29. Whenever the real ball's
//  detection flickered - and scores swing from 0.98 to 0.05 between frames - the
//  model's best guess jumped to that phantom. The apparent motion of that jump is
//  enormous, and the counter read it as a touch. Every cluster of phantom frames
//  in that run was followed within half a second by a counted touch.
//
//  Two signals separate it from the real ball, and neither is confidence alone:
//
//    * SIZE. The ball does not double between frames. The lab gates undersized
//      boxes for the same reason, but only undersized: it measured that OVERsized
//      boxes are real balls smeared by motion blur, at ~1.0 confidence. This
//      phantom is oversized AND weak, which is a different signature, so size is
//      gated in both directions but only against low-confidence boxes.
//
//    * TELEPORTATION. A ball in flight moves a bounded distance per frame. A
//      weak detection that appears half a frame away from the last confident one
//      is a different object.
//
//  A confident detection is never rejected. Motion blur, a bounced ball and a
//  genuinely fast flight all look extreme, and discarding those would lose
//  exactly the frames a touch happens on.
//

import Foundation

nonisolated struct BallPlausibility {
    /// Above this, a detection is trusted whatever its size or position.
    ///
    ///0.25, not 0.45. The first version used 0.45 and cost 13 touches of 33 on a
    /// real run: average ball confidence on that footage was 0.33, so most
    /// genuine frames fell below the line and were then judged on size and
    /// position - and rejected. The phantom this gate exists for never exceeded
    /// 0.134, so 0.25 still clears it with room to spare.
    var trustedScore = 0.25

    /// Allowed size range, as a fraction of the running median width.
    ///
    /// Wide on purpose. The ball genuinely changes size as the player moves
    /// toward and away from the camera, and motion blur stretches the box. The
    /// phantom was 1.8x the median AND weak, which this still catches; a real
    /// ball at 1.5x is not worth losing.
    var minSizeRatio = 0.35
    var maxSizeRatio = 2.4

    /// Furthest a ball may appear to travel in one frame, in frame widths.
    ///
    /// A kicked ball crosses a lot of frame quickly - measured at ~0.095 per
    /// frame on real footage - and those fast frames are exactly the ones a touch
    /// sits on. The phantom jumped ~0.15 from a standing start, so this only has
    /// to be loose enough not to punish real flight.
    var maxJumpPerFrame = 0.25

    /// Detections needed before the median means anything.
    var warmup = 20

    private var widths: [Double] = []
    private var lastAccepted: (x: Double, y: Double, frame: Int)?
    private(set) var rejectedSize = 0
    private(set) var rejectedJump = 0

    var referenceWidth: Double? {
        guard widths.count >= warmup else { return nil }
        let sorted = widths.sorted()
        return sorted[sorted.count / 2]
    }

    /// Returns the detection if it is plausibly the ball, otherwise nil.
    mutating func accept(_ d: Detection, frame: Int) -> Detection? {
        if d.score >= trustedScore {
            remember(d, frame: frame)
            return d
        }

        if let reference = referenceWidth {
            let ratio = d.width / max(reference, 1e-6)
            if ratio < minSizeRatio || ratio > maxSizeRatio {
                rejectedSize += 1
                return nil
            }
        }

        if let last = lastAccepted {
            let gap = max(1, frame - last.frame)
            let distance = hypot(d.x - last.x, d.y - last.y)
            if distance > maxJumpPerFrame * Double(gap) {
                rejectedJump += 1
                return nil
            }
        }

        remember(d, frame: frame)
        return d
    }

    /// Learn only from detections good enough to define what the ball looks like.
    private mutating func remember(_ d: Detection, frame: Int) {
        lastAccepted = (d.x, d.y, frame)
        guard d.score >= trustedScore else { return }
        widths.append(d.width)
        if widths.count > 300 { widths.removeFirst(widths.count - 300) }
    }

    mutating func reset() {
        widths.removeAll()
        lastAccepted = nil
        rejectedSize = 0
        rejectedJump = 0
    }
}
