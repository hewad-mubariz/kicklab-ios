import Foundation

/// Forensic evidence ablation, not a replay or a new counting rule. Only the
/// contact ball box is swapped; the saved poses, timing and proof flags remain.
@main struct FootBoxSwapAudit {
    struct Row: Decodable {
        let name: String
        let evidence: FootContactEvidence
    }
    static func main() throws {
        let rows = try JSONDecoder().decode([Row].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for row in rows {
            let e = row.evidence
            let distances = e.contact.ankles.mapValues { ankle in
                hypot((e.contact.ballX-ankle.x)/e.contact.width,
                      (e.contact.ballY-ankle.y)/e.contact.height)
            }
            let result: [String: Any] = ["name": row.name,
                "footConfirms": e.confirms,
                "ordinaryFootConfirms": FootContactRules.confirms(before: e.before,
                    contact: e.contact, after: e.after,
                    usesFourExposureWindow: e.usesFourExposureWindow == true,
                    rejectsWeakBelowAnkle: e.rejectsWeakBelowAnkle == true),
                "contactAnkleDistance": Dictionary(uniqueKeysWithValues:
                    distances.map { ($0.key.rawValue, $0.value) })]
            print(String(data: try JSONSerialization.data(withJSONObject: result,
                options: [.sortedKeys]), encoding: .utf8)!)
        }
    }
}
