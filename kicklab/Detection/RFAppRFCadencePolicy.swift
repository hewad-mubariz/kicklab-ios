// Diagnostic scheduling only. All modes retain the same RF model and evidence rules.
nonisolated enum RFCadenceMode: String, CaseIterable {
    case fixed12, fixed8, fixed6, thermal
}

nonisolated struct RFCadencePolicy {
    let mode: RFCadenceMode

    func targetHz(thermalState: Int) -> Double {
        // Critical/unknown thermal state must not start more inference.
        guard (0...2).contains(thermalState) else { return 0 }
        switch mode {
        case .fixed12: return 12
        case .fixed8: return 8
        case .fixed6: return 6
        case .thermal: return [12.0, 8.0, 6.0][thermalState]
        }
    }
}
