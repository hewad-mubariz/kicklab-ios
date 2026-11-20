#if DEBUG
import Foundation

nonisolated enum GoalChallengeMode: String, CaseIterable, Identifiable, Sendable {
    case topBins = "top-bins", findSpace = "find-space"
    var id: String { rawValue }
    var title: String { self == .topBins ? "Top Bins" : "Find the Space" }
    var instruction: String {
        self == .topBins ? "Five shots · upper rings 100 · lower rings 50" : "Five shots · shoot through the green opening · 100 points"
    }
    static func launchMode(_ arguments: [String]) -> Self? {
        allCases.first { arguments.contains("--" + $0.rawValue) }
    }
}

/// All geometry is in goal coordinates: left/top = 0, right/bottom = 1.
/// Rendering and scoring use these same definitions, including the adjusted goal height.
nonisolated struct GoalChallengeRules {
    struct Bin: Identifiable, Sendable {
        let id: Int
        let u, v: Double
        let points: Int
    }
    static let bins = [Bin(id:0,u:0.14,v:0.23,points:100), Bin(id:1,u:0.86,v:0.23,points:100),
                       Bin(id:2,u:0.14,v:0.77,points:50), Bin(id:3,u:0.86,v:0.77,points:50)]
    static let binRadius = 0.064 // fraction of goal width; always a circle on the output
    static let blockerWidth = 0.42
    static let shotLimit = 5
    static func blockerCentre(elapsed: Double) -> Double {
        0.5 + 0.27 * sin(max(0,elapsed) * 2 * .pi / 8)
    }
    static func bin(u: Double, v: Double, goalAspect: Double) -> Bin? {
        guard u.isFinite,v.isFinite,goalAspect.isFinite,goalAspect>0,
              (0...1).contains(u),(0...1).contains(v) else { return nil }
        return bins.first { hypot(u-$0.u,(v-$0.v)/goalAspect) <= binRadius }
    }
    static func clearGap(u: Double,v: Double,radiusU: Double,radiusV: Double,centre: Double) -> Bool {
        guard [u,v,radiusU,radiusV,centre].allSatisfy(\.isFinite),radiusU>=0,radiusV>=0,
              u-radiusU>=0,u+radiusU<=1,v-radiusV>=0,v+radiusV<=1 else { return false }
        return u+radiusU < centre-blockerWidth/2 || u-radiusU > centre+blockerWidth/2
    }
}

nonisolated struct GoalChallengeRound: Sendable {
    struct Shot: Identifiable, Sendable {
        let id: Int
        let u,v,contactTime,confirmedAt,displayTime: Double
        let points: Int
        let bin: Int?
        let blockerCentre: Double?
        let label: String
    }
    let mode: GoalChallengeMode
    private(set) var shots: [Shot] = []
    private(set) var readyAfter = -Double.infinity
    var score: Int { shots.reduce(0) { $0+$1.points } }
    var finished: Bool { shots.count >= GoalChallengeRules.shotLimit }
    var remaining: Int { max(0,GoalChallengeRules.shotLimit-shots.count) }
    func accepting(at time: Double) -> Bool { !finished && time>=readyAfter }

    /// Confirmation arrives after the rebound. Score the earlier visible frame,
    /// never the blocker's position when the detector finally confirms the shot.
    mutating func hit(u: Double,v: Double,radiusU: Double,radiusV: Double,
                      goalAspect: Double,contactTime: Double,confirmedAt: Double,
                      displayLead: Double,epoch: Double) -> Shot? {
        guard [u,v,radiusU,radiusV,goalAspect,contactTime,confirmedAt,displayLead,epoch].allSatisfy(\.isFinite),
              goalAspect>0,radiusU>=0,radiusV>=0,confirmedAt>=contactTime,
              contactTime>=epoch,accepting(at:contactTime) else { return nil }
        let displayTime=max(epoch,contactTime-min(0.5,max(0,displayLead)))
        let bin=mode == .topBins ? GoalChallengeRules.bin(u:u,v:v,goalAspect:goalAspect):nil
        let centre=mode == .findSpace ? GoalChallengeRules.blockerCentre(elapsed:displayTime-epoch):nil
        let clear=centre.map { GoalChallengeRules.clearGap(u:u,v:v,radiusU:radiusU,radiusV:radiusV,centre:$0) } ?? false
        let points=mode == .topBins ? (bin?.points ?? 0):(clear ? 100:0)
        let inside=(0...1).contains(u) && (0...1).contains(v)
        let label=points>0 ? "+\(points)" : !inside ? "WIDE" : mode == .topBins ? "MISSED":"BLOCKED"
        let shot=Shot(id:shots.count+1,u:u,v:v,contactTime:contactTime,confirmedAt:confirmedAt,
                      displayTime:displayTime,points:points,bin:bin?.id,blockerCentre:centre,label:label)
        shots.append(shot)
        // One acknowledgement, then enough space for the real rebound to leave.
        readyAfter=confirmedAt+1.6
        return shot
    }
}
#endif
