import Foundation
import Testing
@testable import kicklab

struct GroundHeightEvidenceTests {
    private final class Resources {}
    private func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func visibleToeFlickAboveTheAnklesIsNotAFloorBounce() throws {
        var evidence = try read("foot-flick-20261019-ground", as: GroundContactEvidence.self)
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true))
        evidence.requiresLowBallCenter = true
        evidence.usesLocalImpactSize = true
        evidence.requiresPositiveLowContact = true
        #expect(!evidence.needsPositiveFootContact)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true))
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        let saved = try JSONEncoder().encode(evidence)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: saved) == evidence)
    }

    @Test func missingFloorImpactIsUncertainUntilFootContactIsResolved() throws {
        for name in ["floor-gap-25-20261024", "floor-gap-26-20261024"] {
            var evidence = try read(name, as: GroundContactEvidence.self)
            #expect(!evidence.needsPositiveFootContact)
            #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
            evidence.requiresPositiveLowContact = true
            #expect(evidence.needsPositiveFootContact)
            // Requiring more proof must not invent a confirmed floor impact.
            #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
            #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        }
    }

    @Test func denseLowJugglingDoesNotTakeTheSparseImpactRoute() throws {
        // Visually labelled legal low-corpus contact, frame 129. An ankle-height
        // rule alone rejected it despite every impact observation being present.
        var evidence = try read("low-dense-impact-20261025", as: GroundContactEvidence.self)
        evidence.requiresPositiveLowContact = true
        #expect(evidence.needsPositiveFootContact)
        evidence.requiresPositiveLowContact = GroundContactEvidence.hasImpactTrackingGap(
            contactMs: evidence.contactMs, originalTimestampsMs: evidence.samples.map(\.timestampMs),
            missingBallTimestampsMs: [])
        #expect(!evidence.needsPositiveFootContact)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
    }

    @Test func reviewedFloorBouncesKeepTheirPositiveFloorEvidence() throws {
        for name in ["visible-ground-bounces-pose", "sparse-floor-bounces-pose"] {
            let rows = try read(name, as: [Int: GroundContactEvidence].self)
            for (frame, old) in rows where old.confirmsGroundContact(corroboratingWeakAnkles: true) {
                var current = old
                current.requiresLowBallCenter = true
                current.usesLocalImpactSize = true
                #expect(current.confirmsGroundContact(corroboratingWeakAnkles: true), "\(name) frame \(frame)")
            }
        }
    }

    @Test func savedFloorBounceUsesLocalSizeButStillRequiresApproachAndRelease() throws {
        var evidence = try read("floor-size-20261024", as: GroundContactEvidence.self)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        evidence.usesLocalImpactSize = true
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        let missingRelease = GroundContactEvidence(contactMs: evidence.contactMs,
            samples: evidence.samples.filter { $0.timestampMs <= evidence.contactMs },
            checksBallBelowFeet: true, requiresLowBallCenter: true, usesLocalImpactSize: true)
        #expect(!missingRelease.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
    }

    @Test func floorBouncesBesideTheFeetNeedAClearApproachAndRebound() throws {
        // Reviewed corpus false counts: normal_juggling_4 at 27.183 s and
        // juggling_second_ball_very_far at 4.083 s. Both reached the floor line
        // well outside the stance after dropping from above the ankles.
        for name in ["floor-beside-3260-20261025", "floor-beside-490-20261025"] {
            var evidence = try read(name, as: GroundContactEvidence.self)
            #expect(!evidence.confirmsBallBesideFeet, "\(name)")
            #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true), "\(name)")
            evidence.checksBallBesideFeet = true
            #expect(evidence.confirmsBallBesideFeet, "\(name)")
            let noRelease = GroundContactEvidence(contactMs: evidence.contactMs,
                samples: evidence.samples.filter { $0.timestampMs <= evidence.contactMs }, checksBallBesideFeet: true)
            #expect(!noRelease.confirmsBallBesideFeet, "\(name)")
            #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        }
        // Reviewed legal low-corpus contacts beside one foot: the ball never
        // rose above the ankles, so there is no approach from above.
        for name in ["floor-beside-low-388-20261025", "floor-beside-low-785-20261025"] {
            var evidence = try read(name, as: GroundContactEvidence.self)
            evidence.checksBallBesideFeet = true
            #expect(!evidence.confirmsBallBesideFeet, "\(name)")
        }
    }

    @Test func oneDroppedApproachExposureDoesNotHideAFloorBounceBetweenTheFeet() throws {
        // Live 25 October recording at 22.88 s: the ball hits the carpet
        // between planted feet; three approach exposures lacked a ball.
        var evidence = try read("floor-approach-gap-685-20261025", as: GroundContactEvidence.self)
        #expect(!evidence.confirmsBallBelowFeet)
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        evidence.toleratesApproachGap = true
        #expect(evidence.confirmsBallBelowFeet)
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
        // A hole wider than one dropped 30 Hz exposure still breaks the proof.
        let wider = GroundContactEvidence(contactMs: evidence.contactMs,
            samples: evidence.samples.filter { !(-110 ... -60).contains($0.timestampMs-evidence.contactMs) },
            checksBallBelowFeet: true, requiresLowBallCenter: true, usesLocalImpactSize: true, toleratesApproachGap: true)
        #expect(!wider.confirmsBallBelowFeet)
    }

    @Test func existingFloorProofWithShortReleaseKeepsItsVerdict() throws {
        var evidence = try read("floor-short-release-20261024", as: GroundContactEvidence.self)
        #expect(evidence.confirmsBallBelowFeet)
        evidence.usesLocalImpactSize = true
        #expect(evidence.confirmsBallBelowFeet)
    }
}

struct FloorRescueTests {
    private final class Resources {}
    private struct Pair: Decodable { let ground: GroundContactEvidence; let foot: FootContactEvidence }
    private func read<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try #require(Bundle(for: Resources.self).url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func plantedFeetProofToleratesOneDroppedApproachExposure() throws {
        // Live 25 October 22:12 recording, 35.81 s: drop, carpet bounce between
        // the feet, catch. One approach exposure is missing (133 ms gap).
        var evidence = try read("floor-planted-gap-1073-20261025", as: GroundContactEvidence.self)
        #expect(!evidence.confirmsPlantedFeet(corroboratingWeakAnkles: true))
        evidence.toleratesPlantedApproachGap = true
        #expect(evidence.confirmsPlantedFeet(corroboratingWeakAnkles: true))
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
    }

    @Test func confirmedFloorContactIsNotOverturnedByAnkleJitter() throws {
        // Same recording, 39.01 s: floor confirmed, yet the foot rule confirmed a
        // kick from 0.1 ball widths of ankle travel assembled with hip jitter.
        let bounce = try read("floor-rescue-jitter-1169-20261025", as: Pair.self)
        #expect(bounce.ground.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        #expect(bounce.foot.confirms)
        #expect(!FootContactRules.ankleTravels(bounce.foot))
        // 5.22 s: a real low touch rescued from a planted-feet verdict; the
        // ankle near the ball moved 0.59 ball widths into the contact.
        let kick = try read("floor-rescue-kick-156-20261025", as: Pair.self)
        #expect(kick.ground.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        #expect(kick.foot.confirms)
        #expect(FootContactRules.ankleTravels(kick.foot))
    }
}

struct AnkleTravelTests {
    private func sample(_ ms: Int, ankle: (Double, Double), ball: (Double, Double) = (0.5, 0.62)) -> FootContactRules.Sample {
        .init(timestampMs: ms, ballX: ball.0, ballY: ball.1, width: 0.14, height: 0.08, confidence: 0.9,
              ankles: [.left: .init(x: ankle.0, y: ankle.1, confidence: 0.8), .right: .init(x: 0.7, y: 0.66, confidence: 0.8)],
              hips: [.left: .init(x: 0.52, y: 0.45, confidence: 0.7), .right: .init(x: 0.62, y: 0.45, confidence: 0.7)])
    }
    @Test func gradualAlignedMotionAcrossBothHalvesCountsAsAnkleTravel() {
        // 0.12 + 0.12 ball widths forward, in the same direction.
        let gradual = FootContactEvidence(before: sample(0, ankle: (0.500, 0.66)), contact: sample(100, ankle: (0.517, 0.66)),
                                          after: sample(167, ankle: (0.534, 0.66)))
        #expect(FootContactRules.ankleTravels(gradual))
        // The same magnitudes reversing direction are jitter, not a kick.
        let jitter = FootContactEvidence(before: sample(0, ankle: (0.500, 0.66)), contact: sample(100, ankle: (0.517, 0.66)),
                                         after: sample(167, ankle: (0.500, 0.66)))
        #expect(!FootContactRules.ankleTravels(jitter))
        // One decisive half is enough.
        let flick = FootContactEvidence(before: sample(0, ankle: (0.500, 0.66)), contact: sample(100, ankle: (0.530, 0.66)),
                                        after: sample(167, ankle: (0.531, 0.66)))
        #expect(FootContactRules.ankleTravels(flick))
    }
}

struct RecheckTierTests {
    @Test func compactProfileKeepsOnlyTheBaseRecheckUnlessForced() {
        #expect(RFContactRecheckTier.select(resolution: .compact, arguments: []) == .compact)
        #expect(RFContactRecheckTier.select(resolution: .detailed, arguments: []) == .full)
        #expect(RFContactRecheckTier.select(resolution: .compact, arguments: ["--recheck-tier-full"]) == .full)
        #expect(RFContactRecheckTier.select(resolution: .detailed, arguments: ["--recheck-tier-compact"]) == .compact)
    }
}

struct StationaryHoleTests {
    private final class Resources {}
    @Test func detectionHoleInTheApproachIsBridgedOnlyWhileBothFeetStayPlanted() throws {
        // iPhone 11 warm replay of the 25 October recording, 32.18 s: a carpet
        // bounce under both ankles with a 167 ms detection hole before impact.
        let url = try #require(Bundle(for: Resources.self).url(forResource: "floor-stationary-hole-964-20261026", withExtension: "json"))
        var evidence = try JSONDecoder().decode(GroundContactEvidence.self, from: Data(contentsOf: url))
        #expect(!evidence.confirmsBallBelowFeet)
        evidence.allowsStationaryHole = true
        #expect(evidence.confirmsBallBelowFeet)
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        // Move one ankle by half a ball height during the hole: no longer planted, no bridge.
        let moved = GroundContactEvidence(contactMs: evidence.contactMs, samples: evidence.samples.map { s in
            guard s.timestampMs < evidence.contactMs-150, var left = s.ankles[.left] else { return s }
            left = .init(x: left.x, y: left.y-0.5*s.height, confidence: left.confidence)
            return .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY, width: s.width, height: s.height,
                         confidence: s.confidence, imageAspect: s.imageAspect, ankles: [.left: left, .right: s.ankles[.right]!], hips: s.hips)
        }, checksBallBelowFeet: true, requiresLowBallCenter: true, usesLocalImpactSize: true, toleratesApproachGap: true, allowsStationaryHole: true)
        #expect(!moved.confirmsBallBelowFeet)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
    }
}

struct DeepFloorContactTests {
    private final class Resources {}
    @Test func oneExposureFloorTouchUnderPlantedFeetIsAFloorContact() throws {
        // iPhone 11 cold replay of the 25 October recording, 29.87 s: a drop
        // bounces between planted feet and is visible under both ankles for a
        // single 30 fps exposure, so the two-view below-feet proof cannot fire.
        let url = try #require(Bundle(for: Resources.self).url(forResource: "floor-deep-895-20261026", withExtension: "json"))
        var evidence = try JSONDecoder().decode(GroundContactEvidence.self, from: Data(contentsOf: url))
        #expect(!evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        evidence.checksDeepFloorContact = true
        #expect(evidence.confirmsDeepFloorContact)
        #expect(evidence.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true))
        // An ankle that moves 0.3 ball heights through the impact window could have
        // touched the ball: the proof must not claim the floor.
        let moving = GroundContactEvidence(contactMs: evidence.contactMs, samples: evidence.samples.map { s in
            guard s.timestampMs >= evidence.contactMs, var right = s.ankles[.right] else { return s }
            right = .init(x: right.x, y: right.y-0.3*s.height, confidence: right.confidence)
            return .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY, width: s.width, height: s.height,
                         confidence: s.confidence, imageAspect: s.imageAspect, ankles: [.left: s.ankles[.left]!, .right: right], hips: s.hips)
        }, checksDeepFloorContact: true)
        #expect(!moving.confirmsDeepFloorContact)
        // A ball resting only 0.3 ball heights under the ankle line is not deep enough.
        let shallow = GroundContactEvidence(contactMs: evidence.contactMs, samples: evidence.samples.map { s in
            guard s.timestampMs == evidence.contactMs else { return s }
            return .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY-0.35*s.height, width: s.width, height: s.height,
                         confidence: s.confidence, imageAspect: s.imageAspect, ankles: s.ankles, hips: s.hips)
        }, checksDeepFloorContact: true)
        #expect(!shallow.confirmsDeepFloorContact)
        #expect(try JSONDecoder().decode(GroundContactEvidence.self, from: JSONEncoder().encode(evidence)) == evidence)
    }
}
