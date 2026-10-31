#if DEBUG
import Foundation
import CoreVideo
import CoreGraphics
import CryptoKit

/// Opt-in measurements only. No image selection, cache eviction or counter decisions change.
nonisolated enum PoseWorkloadAudit {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pose-workload-audit")
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var rows = [[String: Any]]()
        var dropped = 0
    }
    private static let state = State()
    static func record(frame: Int, milliseconds: Int, scope: [String], cached: Bool,
                       elapsedMS: Double, kind: String = "body") {
        guard enabled else { return }
        state.lock.withLock {
            guard state.rows.count < 50_000 else { state.dropped += 1; return }
            state.rows.append(["frame": frame, "timestampMs": milliseconds,
                "scope": scope, "cached": cached, "elapsedMS": elapsedMS, "kind": kind])
        }
    }
    static var report: [String: Any] {
        state.lock.withLock { ["enabled": enabled, "rows": state.rows,
            "droppedRows": state.dropped,
            "scope": "Wall time on the contact worker; cache hits do not perform Vision. Scope labels describe the requesting check, not an accuracy verdict."] }
    }
}

nonisolated enum PoseFallbackAudit {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var rows = [[String: Any]]()
    }
    private static let state = State()
    static func record(frame: Int, milliseconds: Int, poses: Int, selected: Int?, elapsedMS: Double) {
        state.lock.withLock {
            if state.rows.count < 20_000 {
                state.rows.append(["frame": frame, "timestampMs": milliseconds, "rawLegacyPoses": poses,
                    "selectedIndex": selected.map { $0 as Any } ?? NSNull(), "milliseconds": elapsedMS])
            }
        }
    }
    static var report: [String: Any] {
        state.lock.withLock { ["enabled": PoseEmptyFallbackPolicy.enabled(), "rows": state.rows] }
    }
}

/// Explicit, bounded input capture for a pose-repeatability investigation.
/// Copies bytes rather than retaining pooled buffers; disk writes happen only
/// after the paced replay. Never supplies evidence to any counter decision.
nonisolated enum PoseInputAudit {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--pose-input-audit")
    struct Snapshot {
        let bytes: Data
        let width, height: Int
        let sha: String
        let attachments: String
        let colorSpaceICC: String
    }
    struct Ticket {
        let snapshot: Snapshot
        let frame, milliseconds: Int
        let rechecked: Bool
        let scope: [String]
        let selection: ActivePlayerSelection?
        let captureMS: Double
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var rows = [[String: Any]]()
        var files = [String: Data]()
        var errors = [String]()
    }
    private static let state = State()
    static func snapshot(_ pixels: CVPixelBuffer) throws -> Snapshot {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else {
            throw NSError(domain: "PoseAuditPixelFormatOrLock", code: 1)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw NSError(domain: "PoseAuditBase", code: 1) }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var bytes = Data(capacity: width*height*4)
        for y in 0..<height { bytes.append(base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self), count: width*4) }
        var serializable = [String: Any](), icc = ""
        for (key, value) in CVBufferCopyAttachments(pixels, .shouldPropagate) as? [String: Any] ?? [:] {
            if CFGetTypeID(value as CFTypeRef) == CGColorSpace.typeID {
                if let data = (value as! CGColorSpace).copyICCData() { icc = (data as Data).base64EncodedString() }
            } else if PropertyListSerialization.propertyList(value, isValidFor: .binary) { serializable[key] = value }
        }
        let metadata = try PropertyListSerialization.data(fromPropertyList: serializable, format: .binary, options: 0)
        return Snapshot(bytes: bytes, width: width, height: height,
            sha: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            attachments: metadata.base64EncodedString(), colorSpaceICC: icc)
    }
    static func begin(pixels: CVPixelBuffer, frame: Int, milliseconds: Int,
                      rechecked: Bool, scope: [String], selection: ActivePlayerSelection?) -> Ticket? {
        guard enabled, (17_700...19_800).contains(milliseconds), state.lock.withLock({ state.rows.count < 96 }) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let value = try snapshot(pixels)
            return Ticket(snapshot: value, frame: frame, milliseconds: milliseconds, rechecked: rechecked,
                scope: scope, selection: selection, captureMS: (ProcessInfo.processInfo.systemUptime-started)*1000)
        } catch { state.lock.withLock { state.errors.append(String(describing: error)) }; return nil }
    }
    static func finish(_ ticket: Ticket?, pixels: CVPixelBuffer, poses: [BodyPose], selected: Int?) {
        guard let ticket else { return }
        do {
            let after = try snapshot(pixels), before = ticket.snapshot
            state.lock.withLock {
                let file = "\(state.rows.count)-\(ticket.milliseconds)-\(ticket.frame).bgra"
                state.files[file] = before.bytes
                var row: [String: Any] = ["file": file, "frame": ticket.frame, "timestampMs": ticket.milliseconds,
                    "width": before.width, "height": before.height, "rowBytes": before.width*4,
                    "sha256": before.sha, "afterSHA256": after.sha, "pixelsUnchanged": before.sha == after.sha,
                    "attachmentsPlist": before.attachments, "colorSpaceICC": before.colorSpaceICC,
                    "captureMS": ticket.captureMS, "contactRecheck": ticket.rechecked, "scope": ticket.scope,
                    "rawPoseCount": poses.count, "poses": VisionIntegrationProbe.encoded(poses),
                    "selectedIndex": selected.map { $0 as Any } ?? NSNull()]
                if let selection = ticket.selection,
                   let data = try? JSONEncoder().encode(selection),
                   let value = try? JSONSerialization.jsonObject(with: data) { row["playerSelection"] = value }
                if after.sha != before.sha { state.files["after-"+file] = after.bytes }
                state.rows.append(row)
            }
        } catch { state.lock.withLock { state.errors.append(String(describing: error)) } }
    }
    static func write(to folder: URL) throws {
        guard enabled else { return }
        let captured = state.lock.withLock { (state.rows, state.files, state.errors) }
        let directory = folder.appendingPathComponent("pose-input-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, bytes) in captured.1 { try bytes.write(to: directory.appendingPathComponent(name), options: .atomic) }
        try RFDiagnosticJSON.data(["rows": captured.0, "errors": captured.2,
            "scope": "Exact packed BGRA before uncached pose calls, 17.7–19.8s only, max96 calls. Input copy/hash overhead makes this a diagnostic, not a timing benchmark."])
            .write(to: directory.appendingPathComponent("inputs.json"), options: .atomic)
    }
    static func pixels(row: [String: Any], folder: URL) throws -> CVPixelBuffer {
        guard let name = row["file"] as? String, name == URL(fileURLWithPath: name).lastPathComponent,
              let width = row["width"] as? Int, let height = row["height"] as? Int,
              (1...1024).contains(width), (1...1024).contains(height),
              let expected = row["sha256"] as? String else { throw NSError(domain: "PoseAuditPlan", code: 1) }
        let bytes = try Data(contentsOf: folder.appendingPathComponent(name))
        guard bytes.count == width*height*4,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw NSError(domain: "PoseAuditInputHash", code: 1)
        }
        var optional: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &optional) == kCVReturnSuccess,
              let buffer = optional, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw NSError(domain: "PoseAuditBuffer", code: 1)
        }
        let base = CVPixelBufferGetBaseAddress(buffer)!, stride = CVPixelBufferGetBytesPerRow(buffer)
        bytes.withUnsafeBytes { source in
            for y in 0..<height { memcpy(base.advanced(by: y*stride), source.baseAddress!.advanced(by: y*width*4), width*4) }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if let encoded = row["attachmentsPlist"] as? String, let data = Data(base64Encoded: encoded),
           let attachments = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            CVBufferSetAttachments(buffer, attachments as CFDictionary, .shouldPropagate)
        }
        if let encoded = row["colorSpaceICC"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty,
           let space = CGColorSpace(iccData: data as CFData) {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        }
        return buffer
    }
    static func runProbe(folder: URL) throws -> [String: Any] {
        guard let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("inputs.json"))) as? [String: Any],
              let inputs = plan["rows"] as? [[String: Any]], !inputs.isEmpty, inputs.count <= 96 else {
            throw NSError(domain: "PoseAuditEmptyPlan", code: 1)
        }
        var results = [[String: Any]]()
        for repetition in 1...2 {
            for mode in ["retained-captured-order", "retained-chronological", "fresh-per-image"] {
                let session = VisionBodyPoseRevision2.Session()
                let ordered = mode == "retained-chronological" ? inputs.sorted { ($0["timestampMs"] as! Int) < ($1["timestampMs"] as! Int) } : inputs
                for row in ordered {
                    let image = try pixels(row: row, folder: folder)
                    let poses = try VisionBodyPoseRevision2.poses(in: image,
                        session: mode == "fresh-per-image" ? VisionBodyPoseRevision2.Session() : session)
                    let after = try snapshot(image)
                    guard after.sha == row["sha256"] as? String else { throw NSError(domain: "PoseProbeInputChanged", code: 1) }
                    results.append(["file": row["file"]!, "timestampMs": row["timestampMs"]!,
                        "sha256": after.sha, "mode": mode, "repeat": repetition,
                        "rawPoseCount": poses.count, "poses": VisionIntegrationProbe.encoded(poses)])
                    guard ProcessInfo.processInfo.thermalState.rawValue <= 1 else { throw NSError(domain: "PoseInputProbeThermal", code: 1) }
                }
                try RFDiagnosticJSON.data(["rows": results]).write(to: folder.appendingPathComponent("exact-probe-results.json"), options: .atomic)
            }
        }
        return ["mode": "pose-exact-input-probe", "images": inputs.count, "results": results.count,
            "scope": "Packed captured BGRA and color attachments restored; raw pose only, no ball/counter, two repetitions with retained/captured, retained/chronological and fresh requests."]
    }
}
#endif
