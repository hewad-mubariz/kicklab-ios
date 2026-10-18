import Foundation

// Admission estimates leave room for the unchanged contact verifier. They are
// not a guarantee against OS stalls: runtime queue drops remain a release gate.
nonisolated struct ContactBacklogPolicy {
    let capacity = 32
    let maximumOutstanding = 4 // Includes the currently executing contact input.
    let maximumCurrentFrameLag = 0.250
    let maximumRFBudget = 0.140
    let verifierReserve = 0.300
    let safetyFrames = 2
    let sourceHz = 60.0

    func rfBudget(recentMaximum: Double) -> Double {
        max(0.080, recentMaximum * 1.25)
    }
    func projectedFrames(outstanding: Int, rfBudget: Double) -> Int {
        outstanding + Int(ceil((rfBudget + verifierReserve) * sourceHz)) + safetyFrames
    }
    func permits(outstanding: Int, currentFrameLag: Double, rfBudget: Double) -> Bool {
        guard (0...maximumOutstanding).contains(outstanding),
              currentFrameLag.isFinite, currentFrameLag >= 0,
              currentFrameLag <= maximumCurrentFrameLag,
              rfBudget.isFinite, rfBudget >= 0.080, rfBudget <= maximumRFBudget else { return false }
        return projectedFrames(outstanding: outstanding, rfBudget: rfBudget) <= capacity
    }
}
