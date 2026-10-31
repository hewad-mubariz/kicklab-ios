import Foundation

/// Run with the production Counting sources, no Vision or device required.
@main struct ShallowLateralContract {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let evidence = try JSONDecoder().decode(FootContactEvidence.self, from: data)
        precondition(ShallowLateralContactRules.confirms(evidence))
        precondition(!evidence.confirmsShallowLateralContact, "Historical evidence must retain its verdict")
        var optedIn = evidence
        optedIn.allowsShallowLateralContact = true
        precondition(optedIn.confirmsShallowLateralContact)
        func altered(_ change: (inout [String: Any]) -> Void) throws -> FootContactEvidence {
            var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            change(&object)
            return try JSONDecoder().decode(FootContactEvidence.self,
                from: JSONSerialization.data(withJSONObject: object))
        }
        var checks = 3
        func rejects(_ change: (inout [String: Any]) -> Void) throws {
            let candidate = try altered(change)
            precondition(!ShallowLateralContactRules.confirms(candidate))
            checks += 1
        }
        try rejects { $0.removeValue(forKey: "continuation") }
        try rejects { $0.removeValue(forKey: "compactGroundEvidence") }
        try rejects { $0["proposedContactMs"] = 9466 }
        try rejects { object in
            var ground = object["compactGroundEvidence"] as! [String: Any]
            ground["contactMs"] = 9466; object["compactGroundEvidence"] = ground
        }
        try rejects { object in
            let before = object["before"] as! [String: Any]
            for key in ["contact", "after", "continuation"] {
                var sample = object[key] as! [String: Any]
                sample["ankles"] = before["ankles"] // hip jitter cannot invent ankle motion
                object[key] = sample
            }
        }
        try rejects { object in
            for key in ["before", "contact", "after", "continuation"] {
                var sample = object[key] as! [String: Any]
                sample["ballY"] = 0.54 // sideways rolling/handling supplies no reversal
                object[key] = sample
            }
        }
        try rejects { object in
            var sample = object["contact"] as! [String: Any]
            sample["ballY"] = 0.59; object["contact"] = sample // below both ankles
        }
        try rejects { object in
            var sample = object["continuation"] as! [String: Any]
            sample["timestampMs"] = 9600; object["continuation"] = sample // duplicate view
        }
        for key in ["before", "contact", "after", "continuation"] {
            try rejects { object in
                var sample = object[key] as! [String: Any]
                var ankles = sample["ankles"] as! [String: Any]
                var ankle = ankles["left"] as! [String: Any]
                ankle["confidence"] = 0.2; ankles["left"] = ankle
                sample["ankles"] = ankles; object[key] = sample
            }
        }
        if CommandLine.arguments.count > 2 {
            let trace = try PropertyListDecoder().decode(CounterTrace.self,
                from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
            let ground = trace.decisions.compactMap(\.value.groundEvidence).first {
                $0.confirmsGroundContact(corroboratingWeakAnkles:true,cadenceAware:true)
            }!
            let offset = ground.contactMs-evidence.contact.timestampMs
            func shifted(_ value: Any) -> Any {
                if let a=value as? [Any] { return a.map(shifted) }
                guard var o=value as? [String:Any] else { return value }
                for (key,item) in o {
                    if ["timestampMs","contactMs","proposedContactMs"].contains(key),let ms=item as? Int {
                        o[key] = ms+offset
                    } else { o[key] = shifted(item) }
                }
                return o
            }
            var shiftedObject = shifted(try JSONSerialization.jsonObject(with:data)) as! [String:Any]
            let shiftedEvidence = try JSONDecoder().decode(FootContactEvidence.self,
                from:JSONSerialization.data(withJSONObject:shiftedObject))
            precondition(ShallowLateralContactRules.confirms(shiftedEvidence), "No clip timestamp dependency")
            shiftedObject["compactGroundEvidence"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(ground))
            let floorEvidence = try JSONDecoder().decode(FootContactEvidence.self,
                from:JSONSerialization.data(withJSONObject:shiftedObject))
            precondition(!ShallowLateralContactRules.confirms(floorEvidence), "Confirmed floor proof wins")
            checks += 2
        }
        print("PASS: \(checks) shallow-lateral evidence contracts")
    }
}
