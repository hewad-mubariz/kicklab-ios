import Foundation

@main struct CompactWindowContracts {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, line: UInt = #line) throws {
            if !value { throw NSError(domain: "Compact window contract line \(line)", code: 1) }
            checks += 1
        }
        let views=try JSONDecoder().decode([BallObservation].self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let short=views.filter { $0.timestampMs <= 4133 }
        func proposal(_ input: [BallObservation],_ time: Int=4133) -> CompactReboundWindow.Proposal? {
            CompactReboundWindow.proposal(in:input,at:time)
        }
        try check(proposal(short)?.contact.timestampMs == 4033)
        try check(proposal(short.filter { $0.timestampMs <= 4100 },4100) == nil)
        try check(proposal(views.filter { $0.timestampMs <= 12700 },12700)?.contact.timestampMs == 12633)
        try check(proposal(Array(short.reversed()))?.contact.timestampMs == 4033)
        try check(proposal(short.filter { $0.timestampMs != 4066 }) == nil)
        try check(proposal(short+[short.last!]) == nil)
        try check(proposal(short.map { var b=$0;b.y=0.5;return b }) == nil)
        try check(proposal(short.map { var b=$0;b.y=0.4+Double(b.frameIndex)*0.001;return b }) == nil)
        try check(proposal(short.map { var b=$0;if b.timestampMs==4033 { b.confidence=0.2 };return b }) == nil)
        try check(proposal(short.map { var b=$0;if b.timestampMs==4033 { b.x=0 };return b }) == nil)
        try check(proposal(short.map { var b=$0;if b.timestampMs==4033 { b.height *= 2 };return b }) == nil)
        try check(proposal(short.map { var b=$0;if b.timestampMs==4033 { b.y = .nan };return b }) == nil)
        try check(proposal(short.map { var b=$0;b.timestampMs+=10000;return b },14133)?.contact.timestampMs == 14033)
        // Timing is unchanged by absolute clip time. Ground decisions retain
        // their old verdict unless the margin is explicitly selected.
        let ground=try JSONDecoder().decode(GroundContactEvidence.self,
            from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])))
        try check(ground.confirmsBallBelowFeet)
        var updated=ground;updated.requiresBelowAnkleMargin=true
        try check(!updated.confirmsBallBelowFeet)
        struct Fixture: Decodable { let id: String;let reject: Bool;var ground: GroundContactEvidence }
        for (index,path) in CommandLine.arguments.dropFirst(3).enumerated() {
            let fixtures=try JSONDecoder().decode([Fixture].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
            for f in fixtures {
                var g=f.ground
                if index==0 { g.checksUnliftedFloorRebound=true }
                else { g.checksCorroboratedFloorRebound=true }
                func rejects(_ g:GroundContactEvidence) -> Bool {
                    index==0 ? g.unliftedFloorReboundMs != nil : g.corroboratedFloorReboundMs != nil
                }
                try check(rejects(g)==f.reject)
                g.requiresBelowAnkleMargin=true
                try check(rejects(g)==f.reject)
            }
        }
        print("PASS: \(checks) candidate-window / ground-margin contracts")
    }
}
