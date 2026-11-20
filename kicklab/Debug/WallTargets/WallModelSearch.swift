#if DEBUG
import Foundation

/// CPU compatibility mode cannot afford a crop pass followed by a second
/// model pass on the same old camera frame. Search the room on the next fresh
/// frame, then return to the detailed board. GPU mode keeps immediate fallback.
nonisolated struct WallModelSearch {
    private var fullFramePending=false
    static let policy="cpu-one-model-pass-v1"

    mutating func useFullFrame(hasCrop: Bool,cpuOnly: Bool,at time: Double,lastFullSearch: Double) -> Bool {
        guard hasCrop else {fullFramePending=false;return true}
        guard cpuOnly,fullFramePending,time-lastFullSearch>=0.12 else {return false}
        fullFramePending=false
        return true
    }

    /// True means an extra pass may run now. Otherwise retain the request for
    /// the next frame; no old box is reused as a current ball observation.
    mutating func requestFullFrame(cpuOnly: Bool,at time: Double,lastFullSearch: Double) -> Bool {
        if cpuOnly {fullFramePending=true;return false}
        return time-lastFullSearch>=0.12
    }

    mutating func reset() {fullFramePending=false}
}
#endif
