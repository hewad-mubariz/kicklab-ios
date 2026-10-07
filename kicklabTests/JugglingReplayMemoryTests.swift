import AVFoundation
import Metal
import SwiftUI
import XCTest
@testable import kicklab

/// On-device attribution probe. Presents the real replay screen repeatedly,
/// records physical footprint by phase, and checks that its owners disappear.
/// Memory snapshots include XCTest overhead; they are not a live accuracy test.
final class JugglingReplayMemoryTests: XCTestCase {
    @MainActor
    func testReplayMemoryPhases() async throws {
        let video = try XCTUnwrap(Bundle(for: type(of: self))
            .url(forResource: "juggling-eighteen", withExtension: "mov"))
        let frames = (0..<556).map { index in
            RecordedFrame(time: Double(index) / 30, x: 0.5, y: 0.65,
                width: 0.12, height: 0.0675, score: 0.9, smoothedX: 0.5, smoothedY: 0.65,
                vy: 0, motion: .unknown, detected: true, person: nil)
        }
        let summary = SessionSummary.make(touches: 18, duration: 18.57, bestCombo: 18,
            personalBest: 18, videoURL: video, touchesMarked: [], track: frames)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; original?.makeKey() }
        let device = MTLCreateSystemDefaultDevice()
        var samples: [[String: Any]] = []
        var lifetimes: [[String: Any]] = []
        let start = ProcessInfo.processInfo.systemUptime
        func sample(_ phase: String) {
            let memory = DetectorRecordingReview.memory()
            samples.append(["phase": phase, "elapsed_s": ProcessInfo.processInfo.systemUptime - start,
                "current_bytes": memory?.current ?? 0, "kernel_peak_bytes": memory?.peak ?? 0,
                "metal_allocated_bytes": device?.currentAllocatedSize ?? 0])
        }
        func settle(_ phase: String, seconds: Double = 2) async throws {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            repeat { sample(phase); try await Task.sleep(for: .milliseconds(50)) }
            while ProcessInfo.processInfo.systemUptime < until
        }
        try await settle("baseline")
        for cycle in 1...3 {
            var host: UIHostingController<ReplayEffectsView>? = UIHostingController(rootView:
                ReplayEffectsView(summary: summary, edit: .constant(.init(style: .fire, intensity: 0.8)),
                    stadiumPreview: StadiumPreviewModel(), overlays: .constant(ExportOverlaySettings()),
                    onSaveShare: {}, onBack: {}))
            weak var weakHost = host
            window.rootViewController = host
            try await settle("replay_\(cycle)", seconds: 4)
            window.rootViewController = UIViewController()
            host = nil
            try await settle("dismissed_\(cycle)", seconds: 3)
            lifetimes.append(["cycle": cycle, "host_released": weakHost == nil])
            XCTAssertNil(weakHost, "The dismissed replay controller must be released")
        }
        let folder = URL.documentsDirectory.appendingPathComponent("JugglingMemoryProbe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let report: [String: Any] = ["samples": samples, "lifetimes": lifetimes,
            "scope": "Physical footprint of real ReplayEffectsView, paused preview and artwork; synthetic track only to exercise rendering. No live capture or count validation."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("replay-phases.json"), options: .atomic)
    }
}
