import AVFoundation
import Photos
import XCTest
@testable import kicklab

@MainActor
final class ReplayLiveActivityTests: XCTestCase {
    nonisolated private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Double, String)] = []
        func append(_ value: Double, _ subtitle: String) {
            lock.withLock { values.append((value, subtitle)) }
        }
        var snapshot: [(Double, String)] { lock.withLock { values } }
    }

    func testRealReplayExportReportsRenderingThenSavingWithoutAlternating() async throws {
        let permission = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard permission == .authorized || permission == .limited else {
            throw XCTSkip("Grant Photos add access in the preview app before running this save integration test")
        }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "juggling-eighteen", withExtension: "mov"))
        let duration = try await AVURLAsset(url: source).load(.duration).seconds
        let summary = SessionSummary.make(touches: 0, duration: duration, bestCombo: 0,
            personalBest: 0, videoURL: source, touchesMarked: [], track: [])
        let reports = Reports()
        let lease = VideoWorkLease(allowed: true, cpuOnly: true, backgroundGPU: false) { value, subtitle in
            reports.append(value, subtitle)
        }
        let downloader = ReplayDownloader()
        await VideoWorkExecution.$lease.withValue(lease) {
            await downloader.download(summary: summary, edit: SessionEditState(style: .none, intensity: 0),
                overlays: ExportOverlaySettings(), sceneModel: StadiumPreviewModel(),
                preparation: SessionEffectsPreparation(),
                choice: ExportChoice(shortEdge: 360, maxFrameRate: 30, label: "Test export"))
        }
        XCTAssertEqual(downloader.phase, .saved)
        let output = try XCTUnwrap(downloader.savedURL)
        defer { try? FileManager.default.removeItem(at: output) }
        let outputDuration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(outputDuration, duration, accuracy: 0.1)
        let samples = reports.snapshot
        var stages: [String] = []
        for (_, subtitle) in samples where stages.last != subtitle { stages.append(subtitle) }
        XCTAssertEqual(stages, [
            String(localized: "Rendering your video", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
            String(localized: "Finishing video", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
            String(localized: "Saving to Photos", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
        ], "One export must advance through stages instead of alternating renderer and polling-loop labels")
        XCTAssertGreaterThan(samples.count, 3, "Exercise multiple renderer updates and the UI polling loop")
        for (previous, next) in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.0, next.0, "Live Activity progress must not move backwards")
        }
        XCTAssertEqual(samples.last?.0, 0.99)
        let report = XCTAttachment(string: samples.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        report.name = "Real replay Live Activity stages"; report.lifetime = .keepAlways; add(report)
    }
}
