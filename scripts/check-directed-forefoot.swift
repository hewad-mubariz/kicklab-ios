import Foundation

@main struct DirectedForefootContracts {
    static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let original=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let e=try JSONDecoder().decode(FootContactEvidence.self,from:data)
        var checks=0
        func check(_ ok:Bool,_ label:String) throws {
            guard ok else { throw NSError(domain:label,code:checks) }; checks+=1
        }
        try check(!e.confirms,"Existing foot decision unchanged")
        try check(DirectedForefootContact.impact(e)==e.candidateTimestampMs,"Measured toe contact")
        try check(CounterConfig().confirmsDirectedForefoot != true,"Default foot experiment off")
        try check(CounterConfig().recoversObservedUnarmedTurn != true,"Default candidate experiment off")
        func altered(_ mutate:(inout [String:Any])->Void) throws -> FootContactEvidence {
            var v=original;mutate(&v)
            return try JSONDecoder().decode(FootContactEvidence.self,from:JSONSerialization.data(withJSONObject:v))
        }
        func samples(_ v:inout [String:Any],_ mutate:(inout [String:Any])->Void) {
            var g=v["compactGroundEvidence"] as! [String:Any]
            for key in ["samples","compactFootSamples"] {
                if var rows=g[key] as? [[String:Any]] {
                    for i in rows.indices { mutate(&rows[i]) };g[key]=rows
                }
            }
            v["compactGroundEvidence"]=g
        }
        func rejects(_ name:String,_ mutate:(inout [String:Any])->Void) throws {
            try check(DirectedForefootContact.impact(try altered(mutate))==nil,name)
        }
        try rejects("Missing measured ground window") { $0.removeValue(forKey:"compactGroundEvidence") }
        try rejects("Invisible ball") { samples(&$0) { $0["ballX"] = -0.1 } }
        try rejects("Weak ball detection") { samples(&$0) { $0["confidence"] = 0.3 } }
        try rejects("Ball below both ankles") { samples(&$0) { $0["ballY"] = ($0["ballY"] as! Double)+0.1 } }
        try rejects("No release") { samples(&$0) { if ($0["timestampMs"] as! Int)>54066 { $0["ballY"]=0.684 } } }
        try rejects("No foot lift") { samples(&$0) { s in
            var feet=s["ankles"] as! [String:[String:Double]]
            feet["right"]!["y"]=0.715; s["ankles"]=feet
        } }
        try rejects("Uncertain contacting ankle") { samples(&$0) { s in
            var feet=s["ankles"] as! [String:[String:Double]]
            feet["right"]!["confidence"]=0.3;s["ankles"]=feet
        } }
        try rejects("Body translation is not a foot swing") { samples(&$0) { s in
            let feet=s["ankles"] as! [String:[String:Double]]
            var hips=s["hips"] as! [String:[String:Double]]
            hips["right"]!["x"]=feet["right"]!["x"]!-0.1;s["hips"]=hips
        } }
        try rejects("Stationary foot") { samples(&$0) { s in
            var feet=s["ankles"] as! [String:[String:Double]]
            feet["right"]!["x"]=0.42;feet["right"]!["y"]=0.715;s["ankles"]=feet
        } }
        try rejects("Unstable opposite support") { samples(&$0) { s in
            if (s["timestampMs"] as! Int)==54033 {
                var feet=s["ankles"] as! [String:[String:Double]]
                feet["left"]!["x"]=0.2;s["ankles"]=feet
            }
        } }
        try rejects("Duplicate views") { v in
            var g=v["compactGroundEvidence"] as! [String:Any]
            let rows=g["compactFootSamples"] as! [[String:Any]]
            g["compactFootSamples"]=rows+rows;v["compactGroundEvidence"]=g
        }
        try rejects("Missing impact neighbor") { v in
            var g=v["compactGroundEvidence"] as! [String:Any]
            g["compactFootSamples"]=(g["compactFootSamples"] as! [[String:Any]]).filter { ($0["timestampMs"] as! Int) != 54066 }
            v["compactGroundEvidence"]=g
        }
        func shift(_ v:Any)->Any {
            if let a=v as? [Any] { return a.map(shift) }
            guard var d=v as? [String:Any] else { return v }
            for (k,x) in d {
                if ["timestampMs","contactMs","proposedContactMs"].contains(k),let n=x as? Int { d[k]=n+10000 }
                else { d[k]=shift(x) }
            };return d
        }
        let moved=try JSONDecoder().decode(FootContactEvidence.self,from:JSONSerialization.data(withJSONObject:shift(original)))
        try check(DirectedForefootContact.impact(moved)==e.candidateTimestampMs+10000,"No absolute-time dependency")
        print("PASS: \(checks) directed forefoot contracts")
    }
}
