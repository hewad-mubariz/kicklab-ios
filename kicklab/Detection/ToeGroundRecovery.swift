import Foundation

/// A second, independently selected pose may supply a resolved visible foot
/// proof. Keep the native floor samples and every floor flag intact. Unknown
/// or merely nearby toes never replace ground evidence.
nonisolated enum ToeGroundRecovery {
    static func augment(_ original: GroundContactEvidence,
                        with samples: [FootContactRules.Sample], imageAspect: Double) -> GroundContactEvidence? {
        guard imageAspect.isFinite, imageAspect > 0 else { return nil }
        var candidate = original
        candidate.compactFootSamples = samples.map {
            .init(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                  width: $0.width, height: $0.height, confidence: $0.confidence,
                  imageAspect: imageAspect, ankles: $0.ankles, hips: $0.hips)
        }
        candidate.checksVisibleForefoot = true
        candidate.checksVisibleToePulse = true
        candidate.observesForefootToes = true
        guard candidate.visibleFootProof != nil else { return nil }
        return candidate
    }
}
