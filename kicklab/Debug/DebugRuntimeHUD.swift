import SwiftUI

extension View {
    /// A normal main-app Debug build exposes diagnostics without changing access,
    /// capture timing, model decisions or rendered/exported video pixels.
    @ViewBuilder
    func debugRuntimeOverlay(performance: DetectorPerformanceSnapshot? = nil,
                             capture: CaptureCadenceSnapshot? = nil, recording: Bool = false,
                             topInset: CGFloat = 64, onOpenTests: (() -> Void)? = nil) -> some View {
        #if DEBUG
        modifier(DebugRuntimeOverlay(performance: performance, capture: capture, recording: recording,
                                     topInset: topInset, onOpenTests: onOpenTests))
        #else
        self
        #endif
    }
}

#if DEBUG
import Combine

/// One persisted switch hides all diagnostic visuals, including existing touch-outline preferences.
/// Main-app builds start clean; the dedicated touch-testing app keeps its diagnostic default.
enum DebugOverlayPreferences {
    static let visibilityKey = "debug.overlaysVisible"
    #if TOUCH_COUNTING_DEBUG
    static let visibleByDefault = true
    #else
    static let visibleByDefault = false
    #endif
}

private struct DebugRuntimeOverlay: ViewModifier {
    let performance: DetectorPerformanceSnapshot?
    let capture: CaptureCadenceSnapshot?
    let recording: Bool
    let topInset: CGFloat
    let onOpenTests: (() -> Void)?
    @AppStorage(DebugOverlayPreferences.visibilityKey) private var visible = DebugOverlayPreferences.visibleByDefault

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if visible {
                DebugRuntimeHUD(performance: performance, capture: capture, recording: recording, onOpenTests: onOpenTests)
                    .padding(.top, topInset).padding(.trailing, 12)
            }
        }
    }
}

@MainActor
private final class DebugRuntimeMonitor: ObservableObject {
    static let shared = DebugRuntimeMonitor()
    @Published private(set) var memory = 0.0
    @Published private(set) var peak = 0.0
    @Published private(set) var thermal = "nominal"
    private var users = 0
    private var sampling: Task<Void, Never>?

    func start() {
        users += 1
        guard sampling == nil else { return }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.memory = DetectorPerformance.memoryMB()
                self.peak = max(self.peak, self.memory)
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: self.thermal = "nominal"
                case .fair: self.thermal = "fair"
                case .serious: self.thermal = "serious"
                case .critical: self.thermal = "critical"
                @unknown default: self.thermal = "unknown"
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        if users == 0 { sampling?.cancel(); sampling = nil }
    }
}

private struct DebugRuntimeHUD: View {
    let performance: DetectorPerformanceSnapshot?
    let capture: CaptureCadenceSnapshot?
    let recording: Bool
    let onOpenTests: (() -> Void)?
    @ObservedObject private var tests = FinalTestCoordinator.shared
    @State private var showTests = false
    @ObservedObject private var monitor = DebugRuntimeMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DebugOverlayPreferences.visibilityKey) private var visible = DebugOverlayPreferences.visibleByDefault
    @AppStorage("debug.touchOutlines") private var showTouchOutlines = true
    @State private var expanded = true
    @State private var observing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ladybug")
                        Text("\(monitor.memory, specifier: "%.0f") MiB · Thermal: \(monitor.thermal)")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("debug-runtime-toggle")
                Button { visible = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hide debug overlays")
                .accessibilityHint("Restore them in Profile, Settings.")
                .accessibilityIdentifier("debug-runtime-close")
            }
            if expanded {
                Text(RFSmallModel(rawValue: BallDetector.configuredResourceName)?.displayName ?? BallDetector.configuredResourceName)
                Text("Counter V9 · completed rise")
                Text("Thermal: \(monitor.thermal)")
                    .foregroundStyle(monitor.thermal == "nominal" ? .green : monitor.thermal == "fair" ? .yellow : .red)
                    .accessibilityIdentifier("debug-thermal-state")
                Text("App peak \(monitor.peak, specifier: "%.0f") MiB")
                if recording, let performance, let capture {
                    Text("Model: \(performance.computeBackend)")
                    Text("Analysis \(performance.processedFPS, specifier: "%.1f") fps · infer \(performance.inferenceMS, specifier: "%.0f") ms")
                    if let live = performance.live {
                        Text("Full frame avg \(live.meanFrameMS, specifier: "%.0f") · p95 \(performance.liveP95MS, specifier: "%.0f") ms")
                    }
                    Text("Saved \(savedFPS(capture), specifier: "%.1f") / target \(capture.selectedFPS) fps")
                    Text("Drops camera \(capture.captureDrops) · writer \(capture.writerDrops)")
                    Text("Analysis replaced \(capture.analysisReplaced)")
                }
                if let target = tests.armedSeconds { Text("Test armed: \(FinalTestCoordinator.label(target))") }
                Button("Final tests · 30s–15min") { onOpenTests?(); showTests = true }
                    .accessibilityIdentifier("debug-final-tests")
                Toggle("Touch outlines", isOn: $showTouchOutlines)
                    .toggleStyle(.button)
                    .tint(.orange)
                    .accessibilityIdentifier("debug-touch-outlines")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { observe(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in observe(phase == .active) }
        .onDisappear { observe(false) }
        .sheet(isPresented: $showTests) { FinalTestPanel() }
    }

    private func savedFPS(_ stats: CaptureCadenceSnapshot) -> Double {
        stats.duration > 0 ? Double(max(0, stats.writtenFrames - 1)) / stats.duration : 0
    }

    private func observe(_ active: Bool) {
        guard active != observing else { return }
        observing = active
        if active { monitor.start() } else { monitor.stop() }
    }
}
#endif
