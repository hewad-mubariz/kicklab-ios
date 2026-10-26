import CoreVideo
import Foundation

/// Reuses the contact buffer and its pose cache. A cheap single-pose screen
/// precedes a bounded temporal grip check; no new pixel buffers are retained.
nonisolated enum StreakHoldVerifier {
    static func evidence(in observations: ContactObservationStore, now: Int,
                         after lastTouchMs: Int) -> BallHandlingEvidence? {
        let frames = observations.frames.filter {
            $0.timestampMs > lastTouchMs && (0...450).contains(now-$0.timestampMs) && !$0.isContactRecheck
        }
        // Leave real release-side views available. At 15/20/30 fps, the nearest
        // view around 100 ms ago stays within the existing grip rule's window.
        guard let contact = frames.min(by: { abs(now-$0.timestampMs-100) < abs(now-$1.timestampMs-100) }),
              (67...150).contains(now-contact.timestampMs),
              contact.player?.canMatchPose != false,
              let pose = observations.pose(for: contact, recordErrors: false) else { return nil }
        func sample(_ frame: ContactObservationStore.Frame, _ pose: BodyPose) -> BallHandlingEvidence.Sample {
            let b = frame.ball
            return .init(timestampMs: frame.timestampMs, ball: .init(x: b.x, y: b.y),
                width: b.width, height: b.height, confidence: b.score,
                imageAspect: Double(CVPixelBufferGetWidth(frame.pixels))/Double(CVPixelBufferGetHeight(frame.pixels)),
                wrists: pose.wrists)
        }
        guard BallHandlingEvidence.hasGrip(sample(contact, pose)) else { return nil }
        // Sample by elapsed time, not frame count. At most six cached images
        // are inspected, independent of camera/analysis frame rate.
        var selected: [ContactObservationStore.Frame] = []
        for target in [-200,-133,-67,0,67,133] {
            guard let frame = frames.filter({
                $0.player?.id == contact.player?.id && $0.player?.canMatchPose != false
                    && (-200...150).contains($0.timestampMs-contact.timestampMs)
            }).min(by: { abs($0.timestampMs-contact.timestampMs-target) < abs($1.timestampMs-contact.timestampMs-target) }),
                  abs(frame.timestampMs-contact.timestampMs-target) <= 40,
                  !selected.contains(where: { $0.index == frame.index }) else { continue }
            selected.append(frame)
        }
        guard selected.count >= 4 else { return nil }
        let samples = selected.map { frame in
            sample(frame, frame.index == contact.index ? pose : observations.pose(for: frame, recordErrors: false) ?? BodyPose())
        }
        return .init(contactMs: contact.timestampMs, samples: samples, bridgesGripJitter: true)
    }
}
