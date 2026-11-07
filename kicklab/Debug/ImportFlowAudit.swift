#if DEBUG
import AVFoundation
import Foundation
import UIKit

/// Opt-in timings around the production Photos import; no replacement pipeline.
@MainActor
enum ImportFlowAudit {
    static var enabled: Bool {
        Bundle.main.bundleIdentifier == "com.juggledude.release120.preview"
            && SessionDesignReview.argument("--import-flow-audit") != nil
    }
    private static var start: TimeInterval?
    private static var report: [String: Any] = [:]

    static func selected() {
        guard enabled else { return }
        start = ProcessInfo.processInfo.systemUptime
        report = ["selected_s": 0, "proxy_requests": 0, "effects_preparations": 0]
    }

    static func begin(pro: Bool) {
        guard enabled else { return }
        if start == nil { selected() }
        report.merge(["build": Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?",
                  "pro": pro, "started_at": Date().ISO8601Format(),
                  "start_thermal": ProcessInfo.processInfo.thermalState.rawValue,
                  "access_source": "--import-flow-pro fixture when requested; otherwise normal StoreKit"])
            { _, new in new }
        mark("transfer_started_s")
    }

    static func mark(_ name: String) {
        guard enabled, let start, report[name] == nil else { return }
        report[name] = ProcessInfo.processInfo.systemUptime - start
        write()
    }

    static func transferred(_ url: URL) {
        guard enabled else { return }
        report["source_bytes"] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        report["source_file"] = url.lastPathComponent
        mark("transfer_finished_s")
        let token = start
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let descriptions = try? await track.load(.formatDescriptions), start == token else { return }
            report["transfer_functions"] = descriptions.compactMap {
                CMFormatDescriptionGetExtension($0, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            }
            write()
        }
    }

    static func counted(_ analyzer: VideoAnalyzer) {
        guard enabled else { return }
        report["touches"] = analyzer.touchCount
        report["duration_s"] = analyzer.videoDuration
        report["frames"] = analyzer.framesRead
        report["masks"] = analyzer.recordedTrack.filter { $0.ballMask != nil }.count
        report["analysis"] = analyzer.performance
        report["model"] = analyzer.analyzedModel
        if let info = analyzer.processingInfo {
            report["width"] = info.size.width; report["height"] = info.size.height
            report["fps"] = info.fps
        }
        report["finish_thermal"] = ProcessInfo.processInfo.thermalState.rawValue
        mark("count_finished_s")
    }

    static func increment(_ name: String) {
        guard enabled, start != nil else { return }
        report[name] = (report[name] as? Int ?? 0) + 1
        write()
    }

    /// Removes only temporary copies named in this audit's own reports. Useful
    /// when terminating a UI diagnostic before normal import cleanup can run.
    static func cleanUp() async {
        guard Bundle.main.bundleIdentifier == "com.juggledude.release120.preview" else { return }
        do {
            let removed: [String] = try await VideoStorageMaintenance.run {
                let files = try FileManager.default.contentsOfDirectory(at: .documentsDirectory, includingPropertiesForKeys: nil)
                var removed: [String] = []
                for file in files where file.lastPathComponent.hasPrefix("import-flow-") && file.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: file),
                          let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = record["source_file"] as? String,
                          name.hasPrefix("juggledude-"), name.hasSuffix(".mov"),
                          UUID(uuidString: String(name.dropFirst(11).dropLast(4))) != nil else { continue }
                    let source = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileManager.default.removeItem(at: source)
                        removed.append(name)
                    }
                }
                return removed
            }
            let data = try JSONSerialization.data(withJSONObject: ["removed_temp_files": removed], options: [.prettyPrinted])
            try data.write(to: URL.documentsDirectory.appendingPathComponent("import-flow-cleanup.json"), options: .atomic)
        } catch { print("Import audit cleanup:", error.localizedDescription) }
    }

    private static func write() {
        guard let name = SessionDesignReview.argument("--import-flow-audit"),
              name == URL(fileURLWithPath: name).lastPathComponent,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL.documentsDirectory.appendingPathComponent("import-flow-\(name).json"), options: .atomic)
    }
}

/// Exercises paid import UI without making a purchase or changing stored access.
/// Only the dedicated Debug preview and isolated history launch can enable it.
@MainActor
struct ImportFlowProFixture: LocalSubscriptionEntitlementSource {
    func current() async -> LocalSubscriptionEntitlement? {
        LocalSubscriptionEntitlement(plan: .monthly, validUntil: Date().addingTimeInterval(3600), signedTransaction: nil)
    }
}
#endif
