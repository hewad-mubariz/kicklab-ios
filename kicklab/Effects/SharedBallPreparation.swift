import Foundation

/// The iPhone 17 Pro Max has passed fresh Gallery/editor output parity.
/// Other devices keep separate passes until their shared workflow is qualified.
nonisolated enum SharedBallPreparation {
    static var enabled: Bool {
        #if DEBUG
        if Bundle.main.bundleIdentifier == "com.juggledude.counterresearch.debug" {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--separate-ball-preparation") { return false }
            if arguments.contains("--shared-ball-preparation") { return true }
        }
        #endif
        return RFDeviceProfile.hardwareIdentifier == "iPhone18,2"
    }
}
