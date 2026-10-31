import Foundation
@main struct SupportedToeContracts {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let original = try JSONSerialization.jsonObject(with: data) as! [String:Any]
        let evidence = try JSONDecoder().decode(FootContactEvidence.self, from: data)
        var count = 0
        func check(_ ok: Bool, _ reason: String) throws {
            guard ok else { throw NSError(domain: reason, code: count) }; count += 1
        }
        try check(!evidence.confirms, "Historical foot verdict stays unchanged")
        try check(SupportedToeLift.confirms(evidence), "Saved visible kick has supported toe lift")
        try check(CounterConfig().confirmsSupportedToeLift != true, "Default remains off")
        func rows(_ v: inout [String:Any], _ change: (inout [String:Any]) -> Void) {
            var g = v["compactGroundEvidence"] as! [String:Any]
            for key in ["samples","compactFootSamples"] {
                if var a = g[key] as? [[String:Any]] {
                    for i in a.indices { change(&a[i]) }; g[key] = a
                }
            }; v["compactGroundEvidence"] = g
        }
        func changed(_ mutation: (inout [String:Any]) -> Void) throws -> FootContactEvidence {
            var v = original; mutation(&v)
            return try JSONDecoder().decode(FootContactEvidence.self, from: JSONSerialization.data(withJSONObject: v))
        }
        func rejects(_ reason: String, _ mutation: (inout [String:Any]) -> Void) throws {
            try check(!SupportedToeLift.confirms(try changed(mutation)), reason)
        }
        let ms = evidence.candidateTimestampMs
        try rejects("Missing ground window") { $0.removeValue(forKey:"compactGroundEvidence") }
        try rejects("Invisible ball") { rows(&$0) { $0["ballX"] = -0.1 } }
        try rejects("Weak ball") { rows(&$0) { $0["confidence"] = 0.3 } }
        try rejects("Wrong impact identity") { var g=$0["compactGroundEvidence"] as! [String:Any];g["contactMs"]=ms+33;$0["compactGroundEvidence"]=g }
        try rejects("No pre-impact foot lift") { rows(&$0) { s in
            if (s["timestampMs"] as! Int)<ms { var a=s["ankles"] as! [String:[String:Double]];a["right"]!["y"]=0.70;s["ankles"]=a }
        } }
        try rejects("No continued foot lift at reversal") { rows(&$0) { s in
            if (25...50).contains((s["timestampMs"] as! Int)-ms) { var a=s["ankles"] as! [String:[String:Double]];a["right"]!["y"]=0.73;s["ankles"]=a }
        } }
        try rejects("Stationary foot") { rows(&$0) { s in
            var a=s["ankles"] as! [String:[String:Double]];a["right"]!["x"]=0.47;a["right"]!["y"]=0.72;s["ankles"]=a
        } }
        try rejects("Common foot translation is not a kick") { rows(&$0) { s in
            var a=s["ankles"] as! [String:[String:Double]];a["right"]!["y"]=a["left"]!["y"]!-0.02;s["ankles"]=a
        } }
        try rejects("Weak contacting ankle") { rows(&$0) { s in
            var a=s["ankles"] as! [String:[String:Double]];a["right"]!["confidence"]=0.3;s["ankles"]=a
        } }
        try rejects("Unstable supporting foot") { rows(&$0) { s in
            if (s["timestampMs"] as! Int)==ms { var a=s["ankles"] as! [String:[String:Double]];a["left"]!["x"]=0.2;s["ankles"]=a }
        } }
        try rejects("Ball entirely below feet") { rows(&$0) { s in
            var a=s["ankles"] as! [String:[String:Double]];for side in ["left","right"] { a[side]!["y"]! -= 0.15 };s["ankles"]=a
        } }
        try rejects("No ball release") { rows(&$0) { s in
            if (s["timestampMs"] as! Int)>ms+50 { s["ballY"]=evidence.contact.ballY }
        } }
        try rejects("Single release observation") { v in
            var g=v["compactGroundEvidence"] as! [String:Any]
            g["compactFootSamples"]=(g["compactFootSamples"] as! [[String:Any]]).filter { ($0["timestampMs"] as! Int)<ms+100 }
            v["compactGroundEvidence"]=g
        }
        try rejects("Duplicate samples") { v in
            var g=v["compactGroundEvidence"] as! [String:Any];let a=g["compactFootSamples"] as! [[String:Any]];g["compactFootSamples"]=a+a;v["compactGroundEvidence"]=g
        }
        try rejects("Missing immediate impact neighbor") { v in
            var g=v["compactGroundEvidence"] as! [String:Any]
            g["compactFootSamples"]=(g["compactFootSamples"] as! [[String:Any]]).filter { !(25...50).contains(($0["timestampMs"] as! Int)-ms) };v["compactGroundEvidence"]=g
        }
        func transform(_ value:Any, time:Int=0, position:Double=0, swap:Bool=false)->Any {
            if let a=value as? [Any] { return a.map { transform($0,time:time,position:position,swap:swap) } }
            guard var d=value as? [String:Any] else { return value }
            for (k,v) in d {
                if ["timestampMs","contactMs","proposedContactMs"].contains(k),let n=v as? Int { d[k]=n+time }
                else if ["x","y","ballX","ballY"].contains(k),let n=v as? Double { d[k]=n+position }
                else { d[k]=transform(v,time:time,position:position,swap:swap) }
            }
            if swap,let left=d["left"],let right=d["right"] { d["left"]=right;d["right"]=left }
            return d
        }
        for (name,value) in [("Time translation",transform(original,time:10000)),
                             ("Image translation",transform(original,position:0.01)),
                             ("Either foot",transform(original,swap:true))] {
            let e=try JSONDecoder().decode(FootContactEvidence.self,from:JSONSerialization.data(withJSONObject:value))
            try check(SupportedToeLift.confirms(e),name)
        }
        print("PASS: \(count) supported toe contracts")
    }
}
