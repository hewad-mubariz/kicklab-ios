import Foundation

/// The first tracking-model load after an install or update prepares the model for this phone (1.7 s
/// on an iPhone 11, 0.3 s on an iPhone 17 Pro Max) and would land just as the camera opens. It runs
/// once per build in the background shortly after home appears instead; Core ML keeps the prepared
/// model, so the camera's own load takes milliseconds. The prewarmed objects are released at once.
nonisolated enum TrackingModelPrewarm {
    private static let key = "kicklab.tracking.prewarmedBuild"

    static func runIfNeeded() {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        guard UserDefaults.standard.string(forKey: key) != build, let resources = Bundle.main.resourceURL else { return }
        Task.detached(priority: .background) {
            let loaded = autoreleasepool { (try? RFWorker(resources: resources)) != nil }
            guard loaded else { return }
            if JugglingContactVerifier.enabled {
                autoreleasepool { JugglingContactVerifier(observations: ContactObservationStore()).warmUp() }
            }
            UserDefaults.standard.set(build, forKey: key)
        }
    }
}
