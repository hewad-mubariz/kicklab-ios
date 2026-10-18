//
//  BallPlausibility.swift
//  kicklab
//
//  Reject detections that cannot be the ball we have been watching.
//
//  The legacy policy below was measured with the earlier detector. RF-DETR uses
//  a separate, elapsed-time association policy; its scores cannot reuse the
//  legacy trust threshold. Neither policy synthesizes a ball observation.
//
//  Legacy evidence: a large stationary object in the
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
    enum Policy: Sendable {
        case legacy
        case rfDetrAssociationV1

        static func forResource(_ resource: String) -> Self {
            RFSmallModel(rawValue: resource) != nil ? .rfDetrAssociationV1 : .legacy
        }
    }

    let policy: Policy

    init(policy: Policy = .legacy) { self.policy = policy }

    private struct TimedDetection {
        let detection: Detection
        let timestampMs: Int
    }
    private var recent: TimedDetection?
    private var preceding: TimedDetection?
    private var hasStrongAnchor = false

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
    mutating func accept(_ d: Detection, frame: Int, timestampMs: Int) -> Detection? {
        if policy == .rfDetrAssociationV1 { return associate(d, timestampMs: timestampMs) }
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

    /// A rejected box must not leave its segmentation mask attached to a frame.
    mutating func filter(_ found: FrameDetections, frame: Int, timestampMs: Int) -> FrameDetections {
        var result = found
        if let ball = found.ball {
            result.ball = accept(ball, frame: frame, timestampMs: timestampMs)
            if result.ball == nil { result.ballMask = nil }
        }
        return result
    }

    /// RF-DETR scores are not calibrated like the legacy detector's scores.
    /// Keep its 0.40 detection threshold; only weak, spatially disconnected
    /// observations are withheld from an established trajectory. No predicted
    /// position is emitted as evidence and rejected objects cannot move the anchor.
    private mutating func associate(_ d: Detection, timestampMs: Int) -> Detection? {
        let strongScore = 0.70
        if let recent, timestampMs <= recent.timestampMs || timestampMs - recent.timestampMs > 350 {
            self.recent = nil
            preceding = nil
            hasStrongAnchor = false
        }

        if let recent, hasStrongAnchor, d.score < strongScore {
            let elapsed = Double(timestampMs - recent.timestampMs) / 1000
            let last = recent.detection
            var speedX = 0.0, speedY = 0.0
            if let preceding {
                let gap = recent.timestampMs - preceding.timestampMs
                if (8...150).contains(gap) {
                    let seconds = Double(gap) / 1000
                    speedX = abs(last.x - preceding.detection.x) / seconds
                    speedY = abs(last.y - preceding.detection.y) / seconds
                }
            }
            // Allow 1.5 previous ball diameters of localization/contact motion,
            // recent speed in either direction (including a kick reversal), and
            // half a frame per second of extra motion uncertainty. Use elapsed
            // time, never analysed-frame count; the candidate cannot enlarge its
            // own allowance by returning an oversized box.
            let allowanceX = 1.5 * last.width + (speedX + 0.5) * elapsed
            let allowanceY = 1.5 * last.height + (speedY + 0.5) * elapsed
            if abs(d.x - last.x) > allowanceX || abs(d.y - last.y) > allowanceY {
                rejectedJump += 1
                return nil
            }
        }

        // Weak startup detections alone must not lock out a real ball entering
        // the frame. A long gap also starts a new association, not a permanent veto.
        hasStrongAnchor = hasStrongAnchor || d.score >= strongScore
        preceding = recent
        recent = TimedDetection(detection: d, timestampMs: timestampMs)
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
        recent = nil
        preceding = nil
        hasStrongAnchor = false
    }
}
