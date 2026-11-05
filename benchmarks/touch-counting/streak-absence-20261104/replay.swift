import Foundation
// Replays saved runs through the app's own StreakVisibilityEvidence.swift.
struct Run: Codable { let id, clip, level: String; let touches, boundaries: [Int]; let samples: [[Int]] }
struct Row: Codable { let id, clip, level: String; let touches: Int; let kinds: [String]; let times: [Int]; let gaps: [[Int]]; let gaps3: Int; let looks, overruled, rechecked: Int; let fps: Int }
let enc = JSONEncoder()
let out = FileHandle.standardOutput
for line in try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n") {
    let r = try JSONDecoder().decode(Run.self, from: Data(line.utf8))
    var e = StreakVisibilityEvidence()
    for s in r.samples { e.record(timeMS: s[0], personVisible: s[2] == 1, ballVisible: s[1] == 1) }
    let times = r.samples.map { $0[0] }
    // The saved video look is simulated from the same run's detections.
    let recheck: (StreakVisibilityEvidence.Window) -> [StreakVisibilityEvidence.Sample] = { w in
        stride(from: w.startMS+250, to: w.endMS, by: 500).compactMap { t in
            var lo = 0, hi = times.count
            while lo < hi { let m = (lo+hi)/2; if times[m] < t { lo = m+1 } else { hi = m } }
            let c = [lo-1, lo].filter { $0 >= 0 && $0 < times.count }.min { abs(times[$0]-t) < abs(times[$1]-t) }
            guard let i = c, abs(times[i]-t) <= 100 else { return nil }
            return .init(timeMS: t, personVisible: r.samples[i][2] == 1, ballVisible: r.samples[i][1] == 1)
        }
    }
    let a = e.assess(touchTimes: r.touches.map { Double($0)/1000 }, existingBoundaries: r.boundaries.map { Double($0)/1000 }, recheck: recheck)
    let tt = r.touches
    let dur = max(1, (times.last ?? 1) - (times.first ?? 0))
    let row = Row(id: r.id, clip: r.clip, level: r.level, touches: tt.count, kinds: a.decisions.map(\.kind.rawValue), times: a.decisions.map(\.timeMS),
        gaps: a.decisions.map { d in let i = tt.lastIndex { $0 <= d.timeMS } ?? 0; return [tt[i], tt[min(i+1, tt.count-1)]] },
        gaps3: zip(tt, tt.dropFirst()).filter { $1-$0 >= 3000 }.count, looks: a.secondLooks, overruled: a.absencesOverruled, rechecked: a.recheckedFrames, fps: r.samples.count*1000/dur)
    out.write(try enc.encode(row)); out.write(Data("\n".utf8))
}
