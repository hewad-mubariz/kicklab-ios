import Foundation

@main struct RecentFloorContracts {
    struct Fixture: Decodable {
        let previous, current: GroundContactEvidence
        let rejectedLegal: GroundContactEvidence?
    }
    static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let f=try JSONDecoder().decode(Fixture.self,from:data)
        var checks=0
        func check(_ ok:Bool,_ name:String) throws {
            guard ok else { throw NSError(domain:name,code:checks) };checks+=1
        }
        try check(MeasuredFootImpactRules.resolvedFloorTime(f.previous)==153773,"Independent measured floor")
        try check(MeasuredFootImpactRules.resolvedFloorTime(f.current)==nil,"Ordinary floor decision unchanged")
        try check(MeasuredFootImpactRules.reboundNearRecentFloor(f.current,previous:f.previous)==154206,"Saved downward-foot floor rebound")
        try check(CounterConfig().rejectsReboundNearRecentFloor != true,"Default off")
        if let rejectedLegal=f.rejectedLegal {
            try check(MeasuredFootImpactRules.resolvedFloorTime(rejectedLegal)==nil,
                      "Older planted-feet false rejection cannot seed the new floor reference")
        }
        func mutate(_ key:String,_ change:(inout [String:Any])->Void) throws -> Fixture {
            var o=try JSONSerialization.jsonObject(with:data) as! [String:Any]
            var g=o[key] as! [String:Any];change(&g);o[key]=g
            return try JSONDecoder().decode(Fixture.self,from:JSONSerialization.data(withJSONObject:o))
        }
        func rejects(_ key:String,_ name:String,_ change:(inout [String:Any])->Void) throws {
            let x=try mutate(key,change)
            try check(MeasuredFootImpactRules.reboundNearRecentFloor(x.current,previous:x.previous)==nil,name)
        }
        func shift(_ value:Any,_ offset:Int)->Any {
            if let a=value as? [Any] {return a.map {shift($0,offset)}}
            guard var o=value as? [String:Any] else{return value}
            for (key,item) in o {
                if ["contactMs","timestampMs"].contains(key),let ms=item as? Int{o[key]=ms+offset}
                else{o[key]=shift(item,offset)}
            }
            return o
        }
        try rejects("previous","Expired reference") { $0=shift($0,-700) as! [String:Any] }
        try rejects("previous","Future reference") { $0=shift($0,1000) as! [String:Any] }
        try rejects("previous","Unconfirmed reference") {
            $0["checksUnliftedFloorRebound"]=false;$0["checksCorroboratedFloorRebound"]=false
        }
        func samples(_ g:inout [String:Any],_ change:(inout [String:Any])->Void) {
            var a=g["samples"] as! [[String:Any]]
            for i in a.indices {change(&a[i])};g["samples"]=a
        }
        try rejects("current","Missing impact") { g in
            g["samples"]=(g["samples"] as! [[String:Any]]).filter { ($0["timestampMs"] as! Int) != 154206 }
        }
        try rejects("current","One-sided evidence") { g in
            g["samples"]=(g["samples"] as! [[String:Any]]).filter { ($0["timestampMs"] as! Int) <= 154240 }
        }
        try rejects("current","Uncertain nearest ankle") { g in
            samples(&g) { s in
                var a=s["ankles"] as! [String:Any],p=a["right"] as! [String:Any]
                p["confidence"]=0.2;a["right"]=p;s["ankles"]=a
            }
        }
        try rejects("current","Rising foot is not a descending foot") { g in
            samples(&g) { s in
                if (s["timestampMs"] as! Int)<154206 {
                    var a=s["ankles"] as! [String:Any],p=a["right"] as! [String:Any]
                    p["y"]=0.52;a["right"]=p;s["ankles"]=a
                }
            }
        }
        try rejects("current","Moved support does not share a floor reference") { g in
            samples(&g) { s in
                var a=s["ankles"] as! [String:Any],p=a["left"] as! [String:Any]
                p["x"]=(p["x"] as! Double)+0.1;a["left"]=p;s["ankles"]=a
            }
        }
        try rejects("previous","Different measured floor height") { g in
            samples(&g) { $0["ballY"]=($0["ballY"] as! Double)+0.03 }
        }
        try rejects("previous","Remote rebound cannot locate the local floor") { g in
            samples(&g) { $0["ballX"]=($0["ballX"] as! Double)-0.3 }
        }
        try rejects("previous","One floor exposure cannot locate the range") { g in
            g["samples"]=(g["samples"] as! [[String:Any]]).filter { ($0["timestampMs"] as! Int) != 153806 }
        }
        try rejects("current","No ball release") { g in
            samples(&g) { s in if (s["timestampMs"] as! Int)>154206 {s["ballY"]=0.52} }
        }
        var o=try JSONSerialization.jsonObject(with:data)
        o=shift(o,10000)
        let shifted=try JSONDecoder().decode(Fixture.self,from:JSONSerialization.data(withJSONObject:o))
        try check(MeasuredFootImpactRules.reboundNearRecentFloor(shifted.current,previous:shifted.previous)==164206,"No clip-time condition")
        if CommandLine.arguments.count > 2 {
            let rows=try JSONDecoder().decode([CounterDecision].self,
                from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
            let toe=rows.first { $0.timestampMs==159140 }!.groundEvidence!
            let floor=rows.first { $0.timestampMs==248418 }!.groundEvidence!
            try check(MeasuredFootImpactRules.briefToeLift(toe),"Existing measured toe lift")
            try check(MeasuredFootImpactRules.descendingFloorRebound(toe)==nil,"Existing toe stays legal")
            try check(!MeasuredFootImpactRules.briefToeLift(floor),"Existing floor stays distinct from toe")
            try check(MeasuredFootImpactRules.descendingFloorRebound(floor)==248385,"Existing deep floor proof unchanged")
            try check(MeasuredFootImpactRules.reboundNearRecentFloor(floor,previous:f.previous)==nil,
                      "New route cannot inherit an expired reference even for a deep floor shape")
            let sparse=GroundContactEvidence(contactMs:floor.contactMs,
                samples:floor.samples.filter { $0.timestampMs < 248385 || $0.timestampMs > 248451 })
            try check(MeasuredFootImpactRules.descendingFloorRebound(sparse)==nil,"No invented floor in missing views")
            let duplicate=GroundContactEvidence(contactMs:floor.contactMs,samples:floor.samples+floor.samples)
            try check(MeasuredFootImpactRules.descendingFloorRebound(duplicate)==nil,"Duplicate evidence is not confirmation")
        }
        print("PASS: \(checks) recent measured-floor contracts")
    }
}
