import Foundation
import CoreGraphics

@main struct StationaryMotionContracts {
    struct Candidate: Decodable { let query: Int; let score: Double; let xywh: [Double]; let eligible: Bool }
    struct Row: Decodable { let time: Double; let candidates: [Candidate] }
    struct Clip: Decodable { let clip: String; let rows: [Row] }
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: message, code: checks) }
            checks += 1
        }
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var result: [[String: Any]] = []
        for clip in clips {
            let baseline = StationaryCandidateGate(version: 2), motion = StationaryCandidateGate(version: 3)
            var changes: [Double] = []
            for row in clip.rows {
                let candidates = row.candidates.map {
                    AsyncBallCandidate(query: $0.query, hit: FollowHit(rect: CGRect(x:$0.xywh[0],y:$0.xywh[1],width:$0.xywh[2],height:$0.xywh[3]),score:$0.score))
                }
                let old = baseline.eligible(candidates, at: row.time).map(\.query)
                let new = motion.eligible(candidates, at: row.time).map(\.query)
                try check(old == row.candidates.filter(\.eligible).map(\.query), "Default gate changed on \(clip.clip) at \(row.time)")
                try check(Set(old).isSubset(of: Set(new)), "Motion proof suppressed an existing candidate")
                if old != new { changes.append(row.time) }
            }
            if CommandLine.arguments.contains("--screen") {
                // Broader captured inputs report all changes without imposing
                // the expected outcomes of the original four-clip fixture.
            } else if clip.clip.hasPrefix("low-") {
                try check(changes.first == 0.3, "Measured low-kick motion must release at 0.3 s")
            } else {
                try check(changes.isEmpty, "Unexpected anchor release on \(clip.clip)")
            }
            result.append(["clip":clip.clip,"replies":clip.rows.count,"changedTimes":changes])
        }
        func candidate(_ x: Double, _ y: Double, score: Double = 0.95, size: Double = 100, query: Int = 0) -> AsyncBallCandidate {
            .init(query: query, hit: .init(rect: CGRect(x:x-size/2,y:y-size/2,width:size,height:size),score:score))
        }
        let positions = [(0.0,0.0),(-6.0,26.1),(-17.7,-3.1),(-25.5,13.1)]
        let moving = positions.enumerated().map { i,p in StationaryAnchorMotion.Sample(time:Double(i)*0.1,x:p.0,y:p.1,width:100,height:100,score:0.95) }
        try check(StationaryAnchorMotion.confirms(moving), "Short motion proof")
        for kind in 0..<8 {
            let altered = moving.enumerated().map { i, v in
                StationaryAnchorMotion.Sample(time:kind == 0 && i == 2 ? 0.1 : kind == 1 && i == 3 ? 0.9 : v.time,
                    x:kind == 2 && i == 2 ? .nan : v.x, y:v.y,
                    width:kind == 3 && i == 2 ? 150 : kind == 4 && i == 2 ? 0 : v.width,
                    height:kind == 5 && i == 1 ? 60 : v.height,
                    score:kind == 6 && i == 2 ? 0.79 : kind == 7 && i == 0 ? .infinity : v.score)
            }
            try check(!StationaryAnchorMotion.confirms(altered), "Invalid view must fail \(kind)")
        }
        // Long-running subthreshold jitter cannot accumulate into movement.
        let stationary = StationaryCandidateGate(version: 3)
        for i in 0..<1000 {
            let d = Double(i % 3 - 1) * 4
            try check(stationary.eligible([candidate(100+d,500-d)],at:Double(i)*0.1).isEmpty, "Stationary jitter")
        }
        // One jump, an interrupted history, or two possible identities cannot
        // release a spot. A second stationary object remains excluded when the
        // first ball moves inside its own starting spot.
        for kind in 0..<4 {
            let gate = StationaryCandidateGate(version: 3)
            for (i,p) in positions.enumerated() {
                var cs = [candidate(p.0+100,p.1+500)]
                if kind == 0 && i != 2 { cs = [candidate(100,500)] }
                if kind == 1 && i == 2 { cs = [] }
                if kind == 2 && i == 2 { cs.append(candidate(p.0+102,p.1+501,query:1)) }
                cs.append(candidate(600,300,query:2))
                let output = gate.eligible(cs,at:Double(i)*0.1)
                try check(!output.contains { $0.query == 2 }, "Spare ball must remain anchored")
                try check(output.count == (kind == 3 && i == 3 ? 1 : 0), "Ambiguous or isolated motion")
            }
        }
        try check(StationaryCandidateGate.version(arguments:[]) == 2, "Default remains V2")
        #if DEBUG
        try check(StationaryCandidateGate.version(arguments:["--stationary-gate-motion-v3"]) == 3, "Debug opt in")
        #else
        try check(StationaryCandidateGate.version(arguments:["--stationary-gate-motion-v3"]) == 2, "Release unchanged")
        #endif
        print(String(data: try JSONSerialization.data(withJSONObject:["checks":checks,"clips":result],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
