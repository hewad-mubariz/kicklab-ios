#if DEBUG && BALL_DETECTION_DEBUG
import UIKit
import Combine
import Darwin

/// Diagnostic only: never changes capture, inference, graphics or thermal policy.
/// Runs for the debug app's lifetime, including menus and the simulated keeper.
@MainActor final class WallPowerMonitor {
    static let shared = WallPowerMonitor()
    private let run = UUID().uuidString
    private let historyQueue = DispatchQueue(label: "com.juggledude.power-history", qos: .utility)
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var runtime: WallRuntimeSample?
    private var context = "ball-diagnostic"
    private var gameplayProvider: (() -> WallPowerGameplay?)?
    private let environment: WallPowerEnvironment = {
        var system = utsname()
        uname(&system)
        let hardware = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let bundle = Bundle.main
        return WallPowerEnvironment(hardware: hardware,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            buildFingerprint: bundle.object(forInfoDictionaryKey: "WallEnduranceBuild") as? String,
            physicalMemoryMiB: Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576)
    }()

    // Owned only by historyQueue. No camera/video data or growing sample array.
    private let writer = Writer()
    private nonisolated final class Writer: @unchecked Sendable {
        let history = WallPowerHistory(folder: FileManager.default.urls(for: .documentDirectory,
            in: .userDomainMask)[0].appendingPathComponent("PowerDiagnostics", isDirectory: true))
        var failed = false
    }

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let events: [(Notification.Name, String)] = [
            (UIDevice.batteryLevelDidChangeNotification, "battery_level"),
            (UIDevice.batteryStateDidChangeNotification, "charging_state"),
            (.NSProcessInfoPowerStateDidChange, "low_power_mode"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal_state"),
            (UIApplication.didReceiveMemoryWarningNotification, "memory_warning"),
            (UIApplication.willResignActiveNotification, "will_resign_active"),
            (UIApplication.didEnterBackgroundNotification, "did_enter_background"),
            (UIApplication.willEnterForegroundNotification, "will_enter_foreground"),
            (UIApplication.didBecomeActiveNotification, "did_become_active"),
            (UIApplication.willTerminateNotification, "will_terminate")
        ]
        for (name, event) in events {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
                Task { @MainActor in self?.record(event) }
            }.store(in: &subscriptions)
        }
        record("app_launch")
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record("sample") }
        }
    }

    func readPower() -> WallPowerReading {
        let state: WallPowerReading.Charging = switch UIDevice.current.batteryState {
        case .unplugged: .unplugged
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        return WallPowerReading(level: UIDevice.current.batteryLevel, charging: state,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    func updateRuntime(_ sample: WallRuntimeSample) { runtime = sample }
    func clearRuntime() { runtime = nil }
    /// Read state at sample time without creating game objects or retaining a camera.
    func setGameplayProvider(_ provider: (() -> WallPowerGameplay?)?) { gameplayProvider = provider }
    func setContext(_ value: String) {
        guard context != value else { return }
        context = value
        record("mode_changed")
    }

    private func record(_ event: String) {
        let info = ProcessInfo.processInfo
        let uptime = info.systemUptime
        let recent = runtime.flatMap { (0..<3).contains(uptime - $0.uptime) ? $0 : nil }
        let state: String = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let memory = DetectorPerformance.memoryMB()
        let sample = WallPowerEvent(run: run, event: event, wallTime: Date().timeIntervalSince1970,
            uptime: uptime, processID: info.processIdentifier, appState: state, context: context,
            power: readPower(), thermalState: info.thermalState.rawValue,
            memoryMiB: memory > 0 ? memory : nil, cameraResting: recent?.cameraResting,
            analysisFPS: recent?.analysisFPS, inferenceMS: recent?.inferenceMS,
            brightness: Double(UIScreen.main.brightness), idleTimerDisabled: UIApplication.shared.isIdleTimerDisabled,
            environment: environment, gameplay: gameplayProvider?(), captureFPS: recent?.captureFPS,
            cpuSeconds: Self.cpuSeconds(), displayCount: UIScreen.screens.count,
            screenCaptured: UIScreen.main.isCaptured)
        historyQueue.async { [writer] in
            guard !writer.failed else { return }
            do { try writer.history.append(sample) }
            catch { writer.failed = true; NSLog("Power history unavailable: %@", error.localizedDescription) }
        }
    }

    /// Whole-process CPU time, excluding GPU/ANE work; not a power measurement.
    private static func cpuSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
