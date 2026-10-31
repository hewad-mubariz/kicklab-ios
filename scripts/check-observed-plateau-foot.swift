import Foundation

@main struct PlateauFootContracts {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let foot = try JSONDecoder().decode(FootContactEvidence.self, from: data)
        let balls = try JSONDecoder().decode([BallObservation].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        let turn = ObservedFallAmplitude.turn(balls, contactFrame:139, through:4733)!
        var checks = 0
        func check(_ ok: Bool, _ name: String) throws {
            guard ok else { throw NSError(domain:name, code:checks) }
            checks += 1
        }
        try check(!foot.confirms, "Existing verdict unchanged")
        try check(!ShallowLateralContactRules.confirms(foot), "Ordinary lateral proof unchanged")
        try check(ShallowLateralContactRules.confirmsObservedPlateau(foot,turn:turn), "Saved sideways short kick")
        try check(CounterConfig().confirmsObservedPlateauFoot != true, "Default off")
        func rejects(_ name: String, _ change: (inout [String:Any]) -> Void) throws {
            var object = try JSONSerialization.jsonObject(with:data) as! [String:Any]
            change(&object)
            let changed = try JSONDecoder().decode(FootContactEvidence.self,
                from:JSONSerialization.data(withJSONObject:object))
            try check(!ShallowLateralContactRules.confirmsObservedPlateau(changed,turn:turn),name)
        }
        try rejects("No continuation") { $0.removeValue(forKey:"continuation") }
        try rejects("No floor evidence") { $0.removeValue(forKey:"compactGroundEvidence") }
        try rejects("Different proposed contact") { $0["proposedContactMs"] = 4600 }
        try rejects("Unrelated measured ball") { o in
            var s=o["contact"] as! [String:Any];s["ballX"] = 0.7;o["contact"] = s
        }
        try rejects("Stationary foot and hip jitter") { o in
            let before=o["before"] as! [String:Any]
            for key in ["contact","after","continuation"] {
                var s=o[key] as! [String:Any];s["ankles"] = before["ankles"];o[key] = s
            }
        }
        for key in ["before","contact","after","continuation"] {
            try rejects("Weak contacting ankle \(key)") { o in
                var s=o[key] as! [String:Any], ankles=s["ankles"] as! [String:Any]
                var a=ankles["left"] as! [String:Any];a["confidence"] = 0.2
                ankles["left"] = a;s["ankles"] = ankles;o[key] = s
            }
        }
        try rejects("Support foot does not establish clearance") { o in
            for key in ["before","contact","after","continuation"] {
                var s=o[key] as! [String:Any], ankles=s["ankles"] as! [String:Any]
                var a=ankles["right"] as! [String:Any];a["y"] = 0.56
                ankles["right"] = a;s["ankles"] = ankles;o[key] = s
            }
        }
        try rejects("Ball falls again instead of plateau") { o in
            var s=o["continuation"] as! [String:Any];s["ballY"] = 0.536;o["continuation"] = s
        }
        try rejects("Mismatched floor evidence") { o in
            var g=o["compactGroundEvidence"] as! [String:Any];g["contactMs"] = 4600;o["compactGroundEvidence"] = g
        }
        if CommandLine.arguments.count > 3 {
            let trace = try PropertyListDecoder().decode(CounterTrace.self,
                from: Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
            let ground = trace.decisions.compactMap(\.value.groundEvidence).first {
                $0.confirmsGroundContact(corroboratingWeakAnkles:true,cadenceAware:true)
            }!
            let offset = ground.contactMs-foot.contact.timestampMs
            func shifted(_ value: Any) -> Any {
                if let a=value as? [Any] { return a.map(shifted) }
                guard var o=value as? [String:Any] else { return value }
                for (key,item) in o {
                    if ["timestampMs","contactMs","proposedContactMs"].contains(key), let ms=item as? Int {
                        o[key] = ms+offset
                    } else { o[key] = shifted(item) }
                }
                return o
            }
            var object=shifted(try JSONSerialization.jsonObject(with:data)) as! [String:Any]
            let shiftedBalls=balls.map { var b=$0;b.timestampMs+=offset;return b }
            let shiftedTurn=ObservedFallAmplitude.turn(shiftedBalls,contactFrame:139,through:4733+offset)!
            func evidence() throws -> FootContactEvidence {
                try JSONDecoder().decode(FootContactEvidence.self,
                    from:JSONSerialization.data(withJSONObject:object))
            }
            try check(ShallowLateralContactRules.confirmsObservedPlateau(evidence(),turn:shiftedTurn),
                      "No clip-time condition")
            object["compactGroundEvidence"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ground))
            try check(!ShallowLateralContactRules.confirmsObservedPlateau(evidence(),turn:shiftedTurn),
                      "Saved positive floor evidence wins")
        }
        print("PASS: \(checks) observed plateau-foot contracts")
    }
}
