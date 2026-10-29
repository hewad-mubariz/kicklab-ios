import Foundation
import Testing
@testable import kicklab

struct AdjacentFootContactTests {
    private final class Resources {}
    private func fixtures() throws -> [FootContactEvidence] {
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-adjacent-measured-foot-20261028", withExtension: "json"))
        return try JSONDecoder().decode([FootContactEvidence].self, from: Data(contentsOf: url))
    }
    @Test func actualAdjacentImagesRecoverBothMeasuredFootContacts() throws {
        for var evidence in try fixtures() {
            #expect(!evidence.confirms)
            evidence.allowsAdjacentFootContact = true
            #expect(evidence.adjacentFootContactMs == evidence.contact.timestampMs + (evidence.contact.timestampMs == 10816 ? 34 : 33))
            #expect(evidence.confirms)
        }
    }
    @Test func recoveryStillNeedsApproachReleaseAndAnActualNearbyImpact() throws {
        for var evidence in try fixtures() {
            evidence.allowsAdjacentFootContact = true
            let ground = try #require(evidence.compactGroundEvidence)
            let samples = (ground.compactFootSamples ?? ground.samples).map {
                FootContactRules.Sample(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                    width: $0.width, height: $0.height, confidence: $0.confidence, ankles: $0.ankles, hips: $0.hips)
            }
            let impact = try #require(evidence.adjacentFootContactMs)
            #expect(AdjacentFootContactRules.contactTime(samples.filter { $0.timestampMs <= impact }, at: ground.contactMs) == nil)
            #expect(AdjacentFootContactRules.contactTime(samples.filter { $0.timestampMs >= impact }, at: ground.contactMs) == nil)
            #expect(AdjacentFootContactRules.contactTime(samples, at: ground.contactMs-100) == nil)
            #expect(AdjacentFootContactRules.contactTime(samples+samples, at: ground.contactMs) == nil)
        }
    }
    @Test func aStationaryFootCannotSupplyTheRecovery() throws {
        for evidence in try fixtures() {
            let ground = try #require(evidence.compactGroundEvidence)
            let samples = (ground.compactFootSamples ?? ground.samples).map {
                FootContactRules.Sample(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                    width: $0.width, height: $0.height, confidence: $0.confidence,
                    ankles: evidence.contact.ankles, hips: evidence.contact.hips)
            }
            #expect(AdjacentFootContactRules.contactTime(samples, at: ground.contactMs) == nil)
        }
    }
    @Test func fourExposuresUseTheirRealTimeWithoutChangingTheOldRule() throws {
        let evidence = try #require(try fixtures().first)
        let ground = try #require(evidence.compactGroundEvidence)
        let samples = try #require(ground.compactFootSamples)
        func sample(_ time: Int) throws -> FootContactRules.Sample {
            let s = try #require(samples.first { $0.timestampMs == time })
            return .init(timestampMs: time, ballX: s.ballX, ballY: s.ballY, width: s.width,
                height: s.height, confidence: s.confidence, ankles: s.ankles, hips: s.hips)
        }
        let before = try sample(10183), contact = try sample(10316), after = try sample(10416)
        #expect(!FootContactRules.confirms(before: before, contact: contact, after: after))
        #expect(FootContactRules.confirms(before: before, contact: contact, after: after, usesFourExposureWindow: true))
        #expect(!AdjacentFootEvidencePolicy.enabled(arguments: []))
    }

    @Test func aMissingProposalKeepsTheActualImageTimestamp() throws {
        let source = try #require(try fixtures().last)
        let ground = try #require(source.compactGroundEvidence)
        let samples = (ground.compactFootSamples ?? ground.samples).filter { $0.timestampMs != 10816 }.map {
            FootContactRules.Sample(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                width: $0.width, height: $0.height, confidence: $0.confidence, ankles: $0.ankles, hips: $0.hips)
        }
        let evidence = try #require(AdjacentFootContactRules.measuredEvidence(samples, proposedMs: 10816))
        #expect(evidence.candidateTimestampMs == 10816)
        #expect(evidence.contact.timestampMs == 10850)
        #expect(evidence.confirms)
        #expect(samples.contains(evidence.contact))
        #expect(AdjacentFootContactRules.measuredEvidence(samples, proposedMs: 12000) == nil)
    }
    @Test func adjacentSearchRejectsFourVisuallyConfirmedGroundBounces() throws {
        struct Negative: Decodable {
            let name: String
            let proposedMs: Int
            let samples: [FootContactRules.Sample]
        }
        let url = try #require(Bundle(for: Resources.self).url(forResource: "outdoor-adjacent-ground-negatives-20261028", withExtension: "json"))
        let rows = try JSONDecoder().decode([Negative].self, from: Data(contentsOf: url))
        #expect(rows.count == 4)
        for row in rows {
            #expect(AdjacentFootContactRules.measuredEvidence(row.samples, proposedMs: row.proposedMs) == nil,
                "Moving feet must not rescue the ground bounce in \(row.name)")
        }
    }

    @Test func elevatedSearchPreservesMeasuredMinuteRecoveries() throws {
        for source in try fixtures() {
            let ground = try #require(source.compactGroundEvidence)
            let samples = (ground.compactFootSamples ?? ground.samples).map {
                FootContactRules.Sample(timestampMs: $0.timestampMs, ballX: $0.ballX, ballY: $0.ballY,
                    width: $0.width, height: $0.height, confidence: $0.confidence, ankles: $0.ankles, hips: $0.hips)
            }
            let evidence = try #require(AdjacentFootContactRules.measuredEvidence(samples, proposedMs: source.contact.timestampMs))
            #expect(evidence.confirms)
        }
    }

}
