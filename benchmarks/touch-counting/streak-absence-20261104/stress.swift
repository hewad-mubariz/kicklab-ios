import Foundation
// Real valid juggling with the touches between two points removed, as if the counter
// had missed them. Any streak ended here is a wrong break, on real detector output.
struct Run: Codable { let id, clip, level: String; let touches: [Int]; let samples: [[Int]]; let spans: [[Int]] }
var windows = 0, wrong = 0, looks = 0, overruled = 0
var perLength: [Int: (Int, Int)] = [:], perClip: [String: (Int, Int)] = [:]
var clips = Set<String>(), examples: [String] = []
for line in try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n") {
    let r = try JSONDecoder().decode(Run.self, from: Data(line.utf8))
    clips.insert(r.clip)
    let times = r.samples.map { $0[0] }
    func lower(_ t: Int) -> Int { var a = 0, b = times.count; while a < b { let m = (a+b)/2; if times[m] < t { a = m+1 } else { b = m } }; return a }
    for span in r.spans {
        let inside = r.touches.filter { $0 >= span[0] && $0 <= span[1] }
        for length in [3_000, 3_600, 4_000, 5_000, 6_000, 8_000, 10_000, 15_000, 30_000] {
            for (i, start) in inside.enumerated() {
                guard let end = inside[(i+1)...].first(where: { $0-start >= length }) else { break }
                var e = StreakVisibilityEvidence()
                for k in lower(start)..<lower(end) { let s = r.samples[k]; e.record(timeMS: s[0], personVisible: s[2] == 1, ballVisible: s[1] == 1) }
                let a = e.assess(touchTimes: [Double(start)/1000, Double(end)/1000], existingBoundaries: []) { w in
                    stride(from: w.startMS+250, to: w.endMS, by: 500).compactMap { t in
                        let l = lower(t)
                        guard let n = [l-1, l].filter({ $0 >= 0 && $0 < times.count }).min(by: { abs(times[$0]-t) < abs(times[$1]-t) }), abs(times[n]-t) <= 100 else { return nil }
                        return .init(timeMS: t, personVisible: r.samples[n][2] == 1, ballVisible: r.samples[n][1] == 1)
                    }
                }
                windows += 1; looks += a.secondLooks; overruled += a.absencesOverruled
                let bad = a.decisions.filter { $0.kind != .visibilityUnverified || true }.count > 0
                perLength[length, default: (0, 0)].0 += 1; perClip[r.clip, default: (0, 0)].0 += 1
                if bad {
                    wrong += 1; perLength[length]!.1 += 1; perClip[r.clip]!.1 += 1
                    if examples.count < 30 { examples.append("\(r.clip) \(r.level) \(start)-\(end) \(a.decisions.map { "\($0.kind.rawValue)@\($0.timeMS)" }) \(r.id)") }
                }
            }
        }
    }
}
print("clips \(clips.count), forced gaps \(windows), wrong breaks \(wrong), second looks \(looks), overruled \(overruled)")
print("by length (gaps, wrong):", perLength.sorted { $0.key < $1.key }.map { "\(Double($0.key)/1000)s: \($0.value.0), \($0.value.1)" }.joined(separator: " | "))
print("by clip:", perClip.sorted { $0.value.0 > $1.value.0 }.map { "\($0.key): \($0.value.0), \($0.value.1)" }.joined(separator: " | "))
examples.forEach { print(" ", $0) }
