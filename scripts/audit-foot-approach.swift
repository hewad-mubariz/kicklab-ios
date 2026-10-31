import Foundation
@main struct FootApproachAudit {
    static func main() throws {
        for path in CommandLine.arguments.dropFirst() {
            let e = try JSONDecoder().decode(FootContactEvidence.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            guard let g = e.compactGroundEvidence else { continue }
            func foot(_ s: GroundContactEvidence.Sample) -> FootContactRules.Sample {
                .init(timestampMs: s.timestampMs, ballX: s.ballX, ballY: s.ballY,
                      width: s.width, height: s.height, confidence: s.confidence, ankles: s.ankles, hips: s.hips)
            }
            let choices = (g.compactFootSamples ?? g.samples).filter {
                (40...134).contains(e.contact.timestampMs - $0.timestampMs)
            }.map { s -> [String: Any] in
                ["beforeMs": s.timestampMs, "confirms": FootContactRules.confirms(before: foot(s),
                    contact: e.contact, after: e.after, usesFourExposureWindow: true,
                    rejectsWeakBelowAnkle: e.rejectsWeakBelowAnkle == true)]
            }
            let result: [String: Any] = ["path": path, "existingFoot": e.confirms,
                "supportedToeLift": SupportedToeLift.confirms(e),
                "planted": g.confirmsPlantedFeet(corroboratingWeakAnkles: true),
                "belowFeet": g.confirmsBallBelowFeet, "deepFloor": g.confirmsDeepFloorContact,
                "ground": g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true),
                "resolvedFloor": MeasuredFootImpactRules.resolvedFloorTime(g) as Any? ?? NSNull(),
                "ankleTravels": FootContactRules.ankleTravels(e), "choices": choices]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
