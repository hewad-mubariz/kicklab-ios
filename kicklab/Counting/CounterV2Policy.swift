import Foundation

/// The qualified selective Full-model counter used by both camera and Gallery.
/// Control variants remain confined to the separate research bundle.
nonisolated enum CounterV2Policy {
    private static var researchArguments: [String] {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.juggledude.counterresearch.debug" {
            return ProcessInfo.processInfo.arguments
        }
        #endif
        return []
    }
    static var singlePersonControl: Bool { researchArguments.contains("--counter-single-person-control") }
    static var extendedContacts: Bool {
        !singlePersonControl && !researchArguments.contains("--counter-prior-contact-control")
    }
    static var poseModelName: String {
        researchArguments.contains("--counter-heavy-toes") ? "pose_landmarker_heavy" : "pose_landmarker_full"
    }
    static var signature: String {
        "|counter-v2-live-import-v2|short-observed|resolved-edge|" +
            (singlePersonControl ? "mp-full-toes-single-player-control" : "mp-full-toes-locked-player-v2") +
            (extendedContacts ? "|toe-body-and-ground-v4-overlap" : "") + "|" + poseModelName
    }
    static func configuration(_ original: CounterConfig = CounterConfig()) -> CounterConfig {
        var result = original
        result.recoversShortObservedFootRebound = true
        result.requiresResolvedEdgeFootContact = true
        return result
    }
}
