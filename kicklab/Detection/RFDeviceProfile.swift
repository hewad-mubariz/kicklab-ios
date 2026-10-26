import Foundation
import Darwin

nonisolated enum RFInputResolution: Int, CaseIterable {
    case compact = 288
    case detailed = 384

    var functionName: String { "rf\(rawValue)" }
}

/// Offline policy shared by live counting, saved analysis and effects.
/// Edit this table to change a model's default in the next app build.
/// Hardware identifiers are not marketing generations: iPhone14,2 is a 13 Pro.
nonisolated enum RFDeviceProfile {
    static let policyVersion = "local-device-v1"
    static let fallback: RFInputResolution = .compact

    // Exact identifiers verified against DeviceKit's generated model mapping.
    // SE models and unrecognized/new identifiers deliberately use fallback.
    static let modelOverrides: [String: RFInputResolution] = [
        "iPhone14,7": .detailed, // iPhone 14
        "iPhone14,8": .detailed, // iPhone 14 Plus
        "iPhone15,2": .detailed, // iPhone 14 Pro
        "iPhone15,3": .detailed, // iPhone 14 Pro Max
        "iPhone15,4": .detailed, // iPhone 15
        "iPhone15,5": .detailed, // iPhone 15 Plus
        "iPhone16,1": .detailed, // iPhone 15 Pro
        "iPhone16,2": .detailed, // iPhone 15 Pro Max
        "iPhone17,3": .detailed, // iPhone 16
        "iPhone17,4": .detailed, // iPhone 16 Plus
        "iPhone17,1": .detailed, // iPhone 16 Pro
        "iPhone17,2": .detailed, // iPhone 16 Pro Max
        "iPhone17,5": .detailed, // iPhone 16e
        "iPhone18,3": .detailed, // iPhone 17
        "iPhone18,1": .detailed, // iPhone 17 Pro
        "iPhone18,2": .detailed, // iPhone 17 Pro Max
        "iPhone18,4": .detailed, // iPhone Air
        "iPhone18,5": .detailed, // iPhone 17e
        "iPhone19,2": .detailed, // iPhone 18 Pro
        "iPhone19,3": .detailed, // iPhone 18 Pro Max
        "iPhone19,7": .detailed, // iPhone 18 Pro Max variant
    ]

    static func resolution(for hardwareIdentifier: String) -> RFInputResolution {
        modelOverrides[hardwareIdentifier] ?? fallback
    }

    static let hardwareIdentifier: String = {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
        #else
        var system = utsname()
        guard uname(&system) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &system.machine) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #endif
    }()

    // Immutable for this process: no onboarding preference, network request or
    // mid-session resolution change. Future remote policy can resolve here.
    static let current = resolution(for: hardwareIdentifier)
}

/// How much extra detector work the contact checks may add around a candidate.
/// The single RF worker is shared with regular detection; on the compact
/// profile one prediction takes about 70 ms, so three impact-window rechecks
/// plus a gap retry per contact starve regular detection and break the track.
/// Compact keeps the base contact recheck and the backlog-guarded impact-gap
/// retry; it drops the three-image impact window and the neighbour repair.
/// Debug flags force either tier for same-device comparisons.
nonisolated enum RFContactRecheckTier: String {
    case full, compact
    static let compactSignature = "|recheck-compact"
    static func select(resolution: RFInputResolution = RFDeviceProfile.current,
                       arguments: [String] = ProcessInfo.processInfo.arguments) -> RFContactRecheckTier {
        if arguments.contains("--recheck-tier-full") { return .full }
        if arguments.contains("--recheck-tier-compact") { return .compact }
        return resolution == .compact ? .compact : .full
    }
    static let current = select()
}
