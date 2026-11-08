import Foundation

/// Execution changes only: every source frame still receives fresh inference.
/// Automatic overlap is limited to the RF device/profile measured on hardware.
nonisolated enum RFVisualExecutionPolicy {
    enum Mode: Equatable {
        case serial, batch2, async2
        var batchSize: Int { self == .serial ? 1 : 2 }
        var cacheSuffix: String {
            switch self {
            case .serial: return ""
            case .batch2: return "|visual-batch2-v1"
            case .async2: return "|visual-async2-v1"
            }
        }

        /// Re-evaluate between pairs. CPU fallback and warmer devices retain
        /// serial execution; already submitted work finishes in source order.
        func canBatch(supported: Bool, cpuOnly: Bool, thermal: ProcessInfo.ThermalState) -> Bool {
            self != .serial && supported && !cpuOnly && thermal == .nominal
        }
    }

    static func select(visualOnly: Bool, isProductionRF: Bool, hardwareIdentifier: String,
                       arguments: [String]) -> Mode {
        guard visualOnly, !arguments.contains("--visual-serial") else { return .serial }
        if arguments.contains("--visual-async2") { return .async2 }
        if arguments.contains("--visual-batch2") { return .batch2 }
        // iPhone 17 Pro Max / RF384. Other devices require their own sustained
        // timing and memory checks before automatic concurrent execution.
        return isProductionRF && hardwareIdentifier == "iPhone18,2" ? .async2 : .serial
    }
}
