import Foundation

/// Offline counter lab: evaluate saved counter traces with the production
/// counting sources on macOS. Numeric evidence only; no Vision, no detector.
///
///   counterlab ground  <trace> <frame>...        print saved ground evidence and the rule verdicts
///   counterlab hand    <trace> <frame>...        print saved handling (wrist) evidence and the grip verdict
///   counterlab list    <trace> [accepted|rejected] list every decision with its reason
///   counterlab replay  [--v18] [--v19] [--grip-v2] [--gap-gate] <trace>...   replay saved traces, optionally with new evidence flags
@main struct CounterLab {
    static func load(_ path: String) throws -> CounterTrace {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension == "json" {
            struct Archive: Decodable { let trace: CounterTrace }
            return try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url)).trace
        }
        return try PropertyListDecoder().decode(CounterTrace.self, from: Data(contentsOf: url))
    }
    static func f(_ v: Double?, _ digits: Int = 3) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "nil" }

    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print("usage: counterlab ground|hand|list|replay ..."); return }
        args.removeFirst()
        switch command {
        case "list": try list(args)
        case "ground": try ground(args)
        case "hand": try hand(args)
        case "replay": try replay(args)
        case "shared-history": try sharedHistory(args)
        case "shallow-lateral": try shallowLateral(args)
        case "shallow-lateral-ablation": try shallowLateralAblation(args)
        case "plateau-foot-shape": try plateauFootShape(args)
        case "recent-floor-screen": try recentFloor(args, enable: true)
        case "recent-floor-ablation": try recentFloor(args, enable: false)
        case "directed-foot-shape": try directedFootShape(args)
        case "directed-foot-screen": try lowRobustness(args, key:"confirmsDirectedForefoot", enable:true)
        case "supported-toe-screen": try lowRobustness(args, key:"confirmsSupportedToeLift", enable:true)
        case "supported-toe-ablation": try lowRobustness(args, key:"confirmsSupportedToeLift", enable:false)
        case "supported-toe-evidence": try supportedToeEvidence(args)
        case "directed-foot-ablation": try lowRobustness(args, key:"confirmsDirectedForefoot", enable:false)
        case "unarmed-turn-screen": try lowRobustness(args, key:"recoversObservedUnarmedTurn", enable:true)
        case "unarmed-turn-ablation": try lowRobustness(args, key:"recoversObservedUnarmedTurn", enable:false)
        case "low-robustness-screen": try lowRobustness(args, key:"confirmsDirectedForefoot", enable:true, secondKey:"recoversObservedUnarmedTurn")
        case "low-robustness-ablation": try lowRobustness(args, key:"confirmsDirectedForefoot", enable:false, secondKey:"recoversObservedUnarmedTurn")
        case "motion": try motion(args)
        case "ground-margin-screen": try groundMarginScreen(args)
        case "compact-window-ablation": try compactWindowAblation(args)
        case "observed-fall-screen": try observedFall(args, enable: true)
        case "observed-fall-ablation": try observedFall(args, enable: false)
        case "short-foot-screen": try observedFall(args, enable: true, shortRise: true, plateauFoot: true)
        case "short-foot-ablation": try observedFall(args, enable: false, shortRise: true, plateauFoot: true)
        case "short-rise-screen": try observedFall(args, enable: true, shortRise: true)
        case "short-rise-ablation": try observedFall(args, enable: false, shortRise: true)
        default: print("unknown command \(command)")
        }
    }

    static func lowRobustness(_ paths:[String], key:String, enable:Bool, secondKey:String? = nil) throws {
        for path in paths {
            let trace=try load(path)
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(trace)) as! [String:Any]
            var config=object["config"] as! [String:Any];config[key]=enable
            if let secondKey { config[secondKey]=enable };object["config"]=config
            let changed=try JSONDecoder().decode(CounterTrace.self,from:JSONSerialization.data(withJSONObject:object))
            let base=run(trace,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let result=run(changed,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let row:[String:Any] = ["path":path,"baseExact":base.touches == trace.touches,
                "baseMs":base.touches.map(\.timestampMs),"changedMs":result.touches.map(\.timestampMs),
                "newDecisions":result.decisions.filter { d in !base.decisions.contains(d) }.map { d in
                    ["ms":d.timestampMs,"outcome":d.rejection?.rawValue ?? "accepted"] },
                "removedDecisions":base.decisions.filter { d in !result.decisions.contains(d) }.map { d in
                    ["ms":d.timestampMs,"outcome":d.rejection?.rawValue ?? "accepted"] },
                "baseMissingCallbacks":base.missingCallbacks,"changedMissingCallbacks":result.missingCallbacks]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    static func supportedToeEvidence(_ paths: [String]) throws {
        for path in paths {
            let trace = try load(path)
            let hits = trace.decisions.compactMap { row -> [String:Any]? in
                guard let e = row.value.footEvidence, SupportedToeLift.confirms(e) else { return nil }
                return ["ms": row.value.timestampMs, "operation": row.operation,
                        "outcome": row.value.rejection?.rawValue ?? "accepted"]
            }
            print(String(data: try JSONSerialization.data(withJSONObject: ["path":path,"hits":hits],
                options: [.sortedKeys]), encoding: .utf8)!)
        }
    }

    static func directedFootShape(_ paths: [String]) throws {
        for path in paths {
            let trace = try load(path)
            let hits = trace.decisions.compactMap { row -> [String:Any]? in
                guard let e=row.value.footEvidence, let ms=DirectedForefootContact.impact(e) else { return nil }
                return ["ms":ms,"operation":row.operation,"outcome":row.value.rejection?.rawValue ?? "accepted"]
            }
            print(String(data:try JSONSerialization.data(withJSONObject:["path":path,"hits":hits],options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    static func observedFall(_ paths: [String], enable: Bool, shortRise: Bool = false, plateauFoot: Bool = false) throws {
        for path in paths {
            let trace = try load(path)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace)) as! [String: Any]
            var config = object["config"] as! [String: Any]
            config[plateauFoot ? "confirmsObservedPlateauFoot" : (shortRise ? "recoversObservedShortRise" : "usesObservedFallAmplitude")] = enable
            if plateauFoot && enable { config["recoversObservedShortRise"] = true }
            object["config"] = config
            let changed = try JSONDecoder().decode(CounterTrace.self,from:JSONSerialization.data(withJSONObject:object))
            let base = run(trace,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let result = run(changed,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let eligible = (enable ? result : base).decisions.filter {
                shortRise ? $0.observedImpulse != nil : ($0.observedFall ?? -.infinity) >= ($0.requiredFall ?? .infinity)
            }.map { d -> [String:Any] in
                var row: [String:Any] = ["ms":d.timestampMs,"fall":d.fall as Any,"observedFall":d.observedFall as Any,
                 "required":d.requiredFall as Any,"outcome":d.rejection?.rawValue ?? "accepted"]
                if shortRise { row["observedRise"] = d.observedRise; row["observedImpulse"] = d.observedImpulse }
                return row
            }
            let row: [String:Any] = ["path":path,"baseExact":base.touches == trace.touches,
                "baseMs":base.touches.map(\.timestampMs),"changedMs":result.touches.map(\.timestampMs),
                "eligible":eligible,"baseMissingCallbacks":base.missingCallbacks,"changedMissingCallbacks":result.missingCallbacks]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    static func recentFloor(_ paths: [String], enable: Bool) throws {
        for path in paths {
            let trace=try load(path)
            var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(trace)) as! [String:Any]
            var config=object["config"] as! [String:Any]
            config["rejectsReboundNearRecentFloor"]=enable;object["config"]=config
            let changed=try JSONDecoder().decode(CounterTrace.self,from:JSONSerialization.data(withJSONObject:object))
            let a=run(trace,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let b=run(changed,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let hits=(enable ? b : a).decisions.compactMap { d -> [String:Any]? in
                guard let prior=d.recentFloorReferenceMs else { return nil }
                return ["ms":d.timestampMs,"previousMs":prior,"outcome":d.rejection?.rawValue ?? "accepted"]
            }
            let row:[String:Any]=["path":path,"baseExact":a.touches==trace.touches,
                "baseMs":a.touches.map(\.timestampMs),"changedMs":b.touches.map(\.timestampMs),
                "baseMissingCallbacks":a.missingCallbacks,"changedMissingCallbacks":b.missingCallbacks,"hits":hits]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    static func compactWindowAblation(_ paths:[String]) throws {
        func disabled(_ value:Any) -> Any {
            if let a=value as? [Any] { return a.map(disabled) }
            guard var d=value as? [String:Any] else { return value }
            for (k,v) in d { d[k]=disabled(v) }
            for k in ["probesCompactReleaseWindow","requiresBelowAnkleMargin"] where d[k] != nil { d[k]=false }
            return d
        }
        for path in paths {
            let trace=try load(path)
            let changed=try JSONDecoder().decode(CounterTrace.self,from:JSONSerialization.data(withJSONObject:
                disabled(try JSONSerialization.jsonObject(with:JSONEncoder().encode(trace)))))
            let a=run(trace,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let b=run(changed,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let data:[String:Any]=["path":path,"enabledExact":a.touches==trace.touches,
                "enabledMs":a.touches.map(\.timestampMs),"disabledMs":b.touches.map(\.timestampMs),
                "enabledMissingCallbacks":a.missingCallbacks,"disabledMissingCallbacks":b.missingCallbacks]
            print(String(data:try JSONSerialization.data(withJSONObject:data,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    static func groundMarginScreen(_ paths: [String]) throws {
        for path in paths {
            let trace=try load(path)
            var changed: [[String:Any]]=[]
            for row in trace.decisions {
                let d=row.value
                guard let before=d.groundEvidence ?? d.footEvidence?.compactGroundEvidence else { continue }
                var after=before;after.requiresBelowAnkleMargin=true
                let a=before.confirmsGroundContact(corroboratingWeakAnkles:true,cadenceAware:true)
                let b=after.confirmsGroundContact(corroboratingWeakAnkles:true,cadenceAware:true)
                if a != b {
                    changed.append(["ms":d.timestampMs,"rejection":d.rejection?.rawValue ?? "accepted",
                        "groundBefore":a,"groundAfter":b,
                        "otherFloorProof":after.unliftedFloorReboundMs != nil || after.corroboratedFloorReboundMs != nil
                            || MeasuredFootImpactRules.descendingFloorRebound(after) != nil])
                }
            }
            print(String(data:try JSONSerialization.data(withJSONObject:["path":path,"changes":changed],
                options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    /// Remove only this opt-in proof from a completed experimental run. Both
    /// sides reuse the exact same inputs and already recorded downstream checks.
    static func shallowLateralAblation(_ paths: [String]) throws {
        func transform(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(transform) }
            guard var object = value as? [String: Any] else { return value }
            for (key,item) in object { object[key] = transform(item) }
            if object["allowsShallowLateralContact"] != nil { object["allowsShallowLateralContact"] = false }
            return object
        }
        for path in paths {
            let trace = try load(path)
            let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(trace))
            let disabled = try JSONDecoder().decode(CounterTrace.self,
                from:JSONSerialization.data(withJSONObject:transform(object)))
            let withProof = run(trace,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let withoutProof = run(disabled,v18:false,v19:false,grip:false,gapGate:false,wideGate:false)
            let enabledFrames = Set(withProof.touches.map(\.frameIndex))
            let disabledFrames = Set(withoutProof.touches.map(\.frameIndex))
            let row: [String:Any] = ["path":path,"enabledExact":withProof.touches == trace.touches,
                "enabledCount":withProof.touches.count,"disabledCount":withoutProof.touches.count,
                "addedByProofMs":withProof.touches.filter { !disabledFrames.contains($0.frameIndex) }.map(\.timestampMs),
                "lostByProofMs":withoutProof.touches.filter { !enabledFrames.contains($0.frameIndex) }.map(\.timestampMs)]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    /// Reconstruct the production trajectory from saved inputs, without asking
    /// for pose evidence or changing its sampling/smoothing parameters.
    static func motion(_ args: [String]) throws {
        let trace = try load(args[0])
        let counter = StreamingCounter(config: trace.config, countsTouches: false)
        var seen = Set<Int>()
        for operation in trace.operations {
            if operation.flush { counter.flush() }
            else if let i = operation.input {
                counter.push(frameIndex: i.frameIndex, timestampMs: i.timestampMs, ball: i.ball,
                    person: i.person, cameraOffsetY: i.cameraOffsetY, reliable: i.reliable,
                    sourceFrameIndex: i.sourceFrameIndex, player: i.player)
            }
            guard let p=counter.lastPoint, seen.insert(p.frameIndex).inserted else { continue }
            let row: [String:Any] = ["frame":p.frameIndex,"ms":p.timestampMs,"y":p.y,
                "vy":p.vy,"valid":p.valid,"motion":String(describing:p.motion)]
            print(String(data:try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    /// Evidence eligibility only. Later body/hand/hold callbacks may not exist
    /// for rejected candidates, so this deliberately does not claim new counts.
    static func shallowLateral(_ paths: [String]) throws {
        for path in paths {
            let trace = try load(path)
            var hits: [[String: Any]] = []
            for row in trace.decisions {
                let d = row.value
                guard let foot = d.footEvidence, ShallowLateralContactRules.confirms(foot) else { continue }
                hits.append(["timeMs":d.timestampMs, "operation":row.operation,
                    "rejection":d.rejection?.rawValue ?? "accepted",
                    "previousFootProof":foot.confirms])
            }
            let result: [String: Any] = ["path":path, "hits":hits,
                "savedTouches":trace.touches.count]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }

    /// Broader evidence audit only: test the foot shape even where no short
    /// candidate exists. This does NOT assert continuous observed ball support
    /// or enable a count; production also requires the measured-turn guards.
    static func plateauFootShape(_ paths: [String]) throws {
        for path in paths {
            let trace = try load(path)
            var checked = 0
            var hits: [[String:Any]] = []
            for row in trace.decisions {
                let d = row.value
                guard let e = d.footEvidence else { continue }
                checked += 1
                func ball(_ s: FootContactRules.Sample) -> BallObservation {
                    .init(frameIndex:0, timestampMs:s.timestampMs, x:s.ballX, y:s.ballY,
                          width:s.width, height:s.height, confidence:s.confidence)
                }
                let shape = ObservedFallAmplitude.Turn(approach:ball(e.before),contact:ball(e.contact),release:ball(e.after))
                if ShallowLateralContactRules.confirmsObservedPlateau(e,turn:shape) {
                    hits.append(["ms":d.timestampMs,"outcome":d.rejection?.rawValue ?? "accepted",
                                 "existingFootProof":e.confirms])
                }
            }
            print(String(data:try JSONSerialization.data(withJSONObject:
                ["path":path,"footEvidenceChecked":checked,"hits":hits,"shapeOnly":true],options:[.sortedKeys]),encoding:.utf8)!)
        }
    }

    /// Frozen-evidence screening only. Body/hand decisions are recorded verdicts;
    /// fresh phone replay is still required for changed inference/alignment paths.
    static func sharedHistory(_ paths: [String]) throws {
        func filter(_ samples: [[String: Any]], _ time: Int) -> [[String: Any]] {
            let stamps = samples.enumerated().map { ContactFrameWindow.Stamp(index: $0.offset,
                timestampMs: $0.element["timestampMs"] as! Int) }
            let selected = ContactFrameWindow.sharedHistoryIndices(stamps, contactMs: time)
            return samples.enumerated().filter { selected.contains($0.offset) }.map(\.element)
        }
        func transform(_ value: Any) -> Any {
            if let array = value as? [Any] { return array.map(transform) }
            guard var object = value as? [String: Any] else { return value }
            for (key, item) in object { object[key] = transform(item) }
            if let time = object["contactMs"] as? Int, let samples = object["samples"] as? [[String: Any]] {
                object["samples"] = filter(samples, (object["observedImpactMs"] as? Int) ?? time)
                if let compact = object["compactFootSamples"] as? [[String: Any]] {
                    // Later compact views are >= +117 ms: the history selection
                    // is identical to filtering the base views before appending them.
                    object["compactFootSamples"] = filter(compact, time)
                }
            }
            return object
        }
        for path in paths {
            let trace = try load(path)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(trace))
            let changed = try JSONDecoder().decode(CounterTrace.self,
                from: JSONSerialization.data(withJSONObject: transform(json)))
            let base = run(trace, v18: false, v19: false, grip: false, gapGate: false, wideGate: false)
            let after = run(changed, v18: false, v19: false, grip: false, gapGate: false, wideGate: false)
            let original = Set(base.touches.map(\.frameIndex)), updated = Set(after.touches.map(\.frameIndex))
            let lost = base.touches.filter { !updated.contains($0.frameIndex) }
            let added = after.touches.filter { !original.contains($0.frameIndex) }
            let groundChanges = zip(trace.decisions, changed.decisions).compactMap { a,b -> Int? in
                guard let x = a.value.groundEvidence, let y = b.value.groundEvidence else { return nil }
                return x.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)
                    != y.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true) ? a.value.timestampMs : nil
            }
            let holdChanges = zip(trace.decisions, changed.decisions).compactMap { a,b -> Int? in
                guard let x = a.value.handlingEvidence, let y = b.value.handlingEvidence else { return nil }
                return x.state != y.state ? a.value.timestampMs : nil
            }
            let evidenceChanges = zip(trace.decisions, changed.decisions).compactMap { a,b -> [String: Any]? in
                var row: [String: Any] = ["timeMs": a.value.timestampMs]
                if let x = a.value.groundEvidence, let y = b.value.groundEvidence {
                    let before = x.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)
                    let after = y.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)
                    if before != after { row["groundBefore"] = before; row["groundAfter"] = after }
                }
                if let x = a.value.handlingEvidence, let y = b.value.handlingEvidence, x.state != y.state {
                    row["holdingBefore"] = x.state.rawValue; row["holdingAfter"] = y.state.rawValue
                }
                return row.count > 1 ? row : nil
            }
            let result: [String: Any] = ["path": path, "baselineExact": base.touches == trace.touches,
                "before": base.touches.count, "after": after.touches.count,
                "lostMs": lost.map(\.timestampMs), "addedMs": added.map(\.timestampMs),
                "groundVerdictChangedMs": groundChanges, "holdingVerdictChangedMs": holdChanges,
                "evidenceChanges": evidenceChanges]
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
    }

    static func list(_ args: [String]) throws {
        let trace = try load(args[0])
        let filter = args.count > 1 ? args[1] : nil
        for row in trace.decisions {
            let d = row.value
            let accepted = d.rejection == nil
            if filter == "accepted" && !accepted { continue }
            if filter == "rejected" && accepted { continue }
            print("frame \(d.frameIndex) t=\(d.timestampMs)ms \(accepted ? "ACCEPTED" : String(describing: d.rejection!))"
                + " body=\(d.bodyContactAllowed.map(String.init) ?? "-") hand=\(d.handRejected.map(String.init) ?? "-")"
                + " foot=\(d.footConfirmed.map(String.init) ?? "-") planted=\(d.plantedFeetConfirmed.map(String.init) ?? "-")"
                + " handling=\(d.handlingEvidence?.state.rawValue ?? "-")")
        }
        print("\(trace.touches.count) touches, \(trace.decisions.count) decisions")
    }

    static func ground(_ args: [String]) throws {
        let trace = try load(args[0])
        let frames = args.dropFirst().compactMap { Int($0) }
        for row in trace.decisions where frames.contains(row.value.frameIndex) {
            let d = row.value
            print("=== frame \(d.frameIndex) t=\(d.timestampMs) \(d.rejection.map { String(describing: $0) } ?? "ACCEPTED")"
                + " body=\(String(describing: d.bodyContactAllowed)) hand=\(String(describing: d.handRejected))"
                + " foot=\(String(describing: d.footConfirmed)) planted=\(String(describing: d.plantedFeetConfirmed))")
            print(" floor line=\(f(d.ground)) observed ball bottom=\(f(d.observedBallBottom)) fall=\(f(d.fall)) rise=\(f(d.rise)) impulse=\(f(d.impulse))")
            guard let g = d.groundEvidence else { print(" (no ground evidence saved: the candidate never reached the floor checks)"); continue }
            print(" measured floor: unlifted=\(String(describing:g.unliftedFloorReboundMs)) corroborated=\(String(describing:g.corroboratedFloorReboundMs)) descending=\(String(describing:MeasuredFootImpactRules.descendingFloorRebound(g))) compact=\(String(describing:g.compactFootContactMs))")
            print(" saved flags: belowFeet=\(String(describing: g.checksBallBelowFeet)) lowCenter=\(String(describing: g.requiresLowBallCenter)) localSize=\(String(describing: g.usesLocalImpactSize)) positiveLow=\(String(describing: g.requiresPositiveLowContact)) gap=\(String(describing: g.toleratesApproachGap)) beside=\(String(describing: g.checksBallBesideFeet))")
            var v18 = g; v18.toleratesApproachGap = true; v18.checksBallBesideFeet = true
            print(" verdicts: ground=\(g.confirmsGroundContact(corroboratingWeakAnkles: true, cadenceAware: true)) planted=\(g.confirmsPlantedFeet(corroboratingWeakAnkles: true)) belowFeet=\(g.confirmsBallBelowFeet) | with V18 flags: belowFeet=\(v18.confirmsBallBelowFeet) besideFeet=\(v18.confirmsBallBesideFeet)")
            let s = g.samples.sorted { $0.timestampMs < $1.timestampMs }
            let scale = s.map(\.height).sorted()[s.count/2]
            print(" \(s.count) views, ball height \(f(scale, 4)) (all distances below are in ball heights)")
            for v in s {
                func j(_ p: PoseLandmark?) -> String { p.map { String(format: "(%.3f,%.3f c%.2f)", $0.x, $0.y, $0.confidence) } ?? "missing" }
                let la = v.ankles[.left], ra = v.ankles[.right]
                let lowest = max(la?.y ?? -1, ra?.y ?? -1)
                let strong = v.confidence >= 0.5 && [la, ra, v.hips[.left], v.hips[.right]].allSatisfy { ($0?.confidence ?? 0) >= 0.5 }
                print(String(format: "  %+5d ms ball(%.3f,%.3f) bottom=%.3f | ankleL %@ ankleR %@ | %@ | ball bottom vs lowest ankle %+.2f",
                    v.timestampMs-g.contactMs, v.ballX, v.ballY, v.ballY+v.height/2, j(la), j(ra), strong ? "confident" : "WEAK", ((v.ballY+v.height/2)-lowest)/scale))
            }
        }
    }

    static func hand(_ args: [String]) throws {
        let trace = try load(args[0])
        let frames = args.dropFirst().compactMap { Int($0) }
        for row in trace.decisions where frames.contains(row.value.frameIndex) {
            let d = row.value
            print("=== frame \(d.frameIndex) t=\(d.timestampMs) \(d.rejection.map { String(describing: $0) } ?? "ACCEPTED") body=\(String(describing: d.bodyContactAllowed)) handVeto=\(String(describing: d.handRejected))")
            guard let h = d.handlingEvidence else { print(" (no handling evidence saved: the candidate never reached the holding check)"); continue }
            var v2 = h; v2.bridgesGripJitter = true
            print(" holding verdict: saved=\(h.state.rawValue) | with V16 grip bridge: \(v2.state.rawValue) | observedImpact=\(String(describing: h.observedImpactMs))")
            let s = h.samples.sorted { $0.timestampMs < $1.timestampMs }
            print(" \(s.count) views (wrist offsets are from the ball center, in ball diameters; |d|<=1.15 is a grip wrist)")
            for v in s {
                let dia = max(v.width*v.imageAspect, v.height)
                func w(_ p: PoseLandmark?) -> String {
                    guard let p else { return "missing" }
                    let dx = (p.x-v.ball.x)*v.imageAspect/dia, dy = (p.y-v.ball.y)/dia
                    return String(format: "dx%+.2f dy%+.2f |d|%.2f c%.2f", dx, dy, hypot(dx, dy), p.confidence)
                }
                print(String(format: "  %+5d ms ball(%.3f,%.3f) h=%.3f | L %@ | R %@", v.timestampMs-h.contactMs, v.ball.x, v.ball.y, v.height, w(v.wrists[.left]), w(v.wrists[.right])))
            }
        }
    }

    static func replay(_ args: [String]) throws {
        let v18 = args.contains("--v18") || args.contains("--v19"), v19 = args.contains("--v19"), grip = args.contains("--grip-v2"), gapGate = args.contains("--gap-gate") || args.contains("--gap-gate-wide"), wideGate = args.contains("--gap-gate-wide")
        for path in args where !path.hasPrefix("--") {
            let trace = try load(path)
            let base = run(trace, v18: false, v19: false, grip: false, gapGate: false, wideGate: false)
            let after = run(trace, v18: v18, v19: v19, grip: grip, gapGate: gapGate, wideGate: wideGate)
            let lost = Set(base.touches.map(\.frameIndex)).subtracting(after.touches.map(\.frameIndex)).sorted()
            let added = Set(after.touches.map(\.frameIndex)).subtracting(base.touches.map(\.frameIndex)).sorted()
            let reasons = lost.map { fr in "\(fr):\(after.decisions.first { $0.frameIndex == fr }?.rejection.map { String(describing: $0) } ?? "?")" }
            print("\(URL(fileURLWithPath: path).lastPathComponent): saved=\(trace.touches.count) replay=\(base.touches.count) exact=\(base.touches == trace.touches) after=\(after.touches.count) lost=\(reasons) added=\(added)")
        }
    }

    /// Saved evidence keyed by (operation, frame): a changed verdict earlier in
    /// the clip must not shift which record a later candidate reads.
    static func run(_ trace: CounterTrace, v18: Bool, v19: Bool, grip: Bool, gapGate: Bool, wideGate: Bool) -> (touches: [Touch], decisions: [CounterDecision], missingCallbacks: [[String:Any]]) {
        var missingCallbacks: [[String:Any]]=[]
        func find<T>(_ rows: [CounterTrace.Decision], _ op: Int, _ frame: Int, _ kind: String, _ f: (CounterDecision) -> T) -> T? {
            guard let row=rows.first(where: { $0.operation == op && $0.value.frameIndex == frame }) else {
                missingCallbacks.append(["operation":op,"frame":frame,"kind":kind])
                return nil
            }
            return f(row.value)
        }
        var op = -1
        // The V17 gap gate from the trace inputs alone: every analysed input is
        // an original exposure here (no rechecked images in a compact-tier trace).
        let inputs = trace.operations.compactMap(\.input)
        // The verifier's "original timestamps" are the stored contact frames,
        // which exist only for inputs that carried a ball.
        let inputTimes = inputs.filter { $0.ball != nil }.map(\.timestampMs)
        let missingTimes = inputs.filter { $0.ball == nil }.map(\.timestampMs)
        let hand = trace.decisions.filter { $0.value.handRejected != nil }
        let foot = trace.decisions.filter { $0.value.footConfirmed != nil }
        let body = trace.decisions.filter { $0.value.bodyContactAllowed != nil }
        let ground = trace.decisions.filter { $0.value.plantedFeetConfirmed != nil }
        let handling = trace.decisions.filter { $0.value.handlingChecked == true }
        let counter = StreamingCounter(config: trace.config,
            rejectsHandContact: trace.usesHandVerifier ? { find(hand, op, $0, "hand") { $0.handRejected! } ?? false } : nil,
            recordTrace: true, traceLimit: max(1, trace.operations.count),
            footContactEvidence: trace.usesFootVerifier ? { find(foot, op, $0, "foot") { $0.footEvidence } ?? nil } : nil,
            allowsBodyContact: trace.usesBodyVerifier == true ? { find(body, op, $0, "body") { $0.bodyContactAllowed! } ?? false } : nil,
            groundPolicy: .corroboratedFeet,
            groundContactEvidence: trace.usesGroundVerifier == true ? { frame in
                find(ground, op, frame, "ground") { d -> GroundContactEvidence? in
                    guard var g = d.groundEvidence else { return nil }
                    if v18 { g.toleratesApproachGap = true; g.checksBallBesideFeet = true }
                    if v19 { g.toleratesPlantedApproachGap = true; g.requiresMovingAnkleForRescue = true; g.allowsStationaryHole = true; g.checksDeepFloorContact = true }
                    if gapGate {
                        let gap = wideGate
                            ? GroundContactEvidence.hasImpactTrackingGap(contactMs: g.contactMs, originalTimestampsMs: inputTimes,
                                missingBallTimestampsMs: missingTimes, approachMs: 134)
                            : GroundContactEvidence.hasImpactTrackingGap(contactMs: g.contactMs, originalTimestampsMs: inputTimes,
                                missingBallTimestampsMs: missingTimes)
                        g.requiresPositiveLowContact = gap ? true : nil
                    }
                    return g
                } ?? nil } : nil,
            handlingEvidence: trace.usesHandlingVerifier == true ? { frame in
                find(handling, op, frame, "handling") { d -> BallHandlingEvidence? in
                    guard var h = d.handlingEvidence else { return nil }
                    if grip { h.bridgesGripJitter = true }
                    return h
                } ?? nil } : nil)
        for (i, o) in trace.operations.enumerated() {
            op = i
            if o.flush { counter.flush() } else if let input = o.input {
                counter.push(frameIndex: input.frameIndex, timestampMs: input.timestampMs, ball: input.ball, person: input.person,
                    cameraOffsetY: input.cameraOffsetY, reliable: input.reliable, sourceFrameIndex: input.sourceFrameIndex, player: input.player)
            }
        }
        return (counter.touches, counter.traceSnapshot()?.decisions.map(\.value) ?? [], missingCallbacks)
    }
}
