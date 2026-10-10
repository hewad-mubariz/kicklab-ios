import CoreGraphics
import CryptoKit
import Foundation

/// A completed visual analysis belongs to the source and pipeline, never to a
/// selected skin or view. Store only final results; interrupted work is not ready.
actor SessionAnalysisStore {
    static let shared = SessionAnalysisStore()
    typealias Progress = @Sendable (Double) -> Void
    typealias Work = @Sendable (@escaping Progress) async throws -> [RecordedFrame]
    private struct Pending {
        let task: Task<[RecordedFrame], Error>
        var observers: [UUID: Progress]
    }
    private let folder: URL
    private var pending: [String: Pending] = [:]
    private var last: (String, [RecordedFrame])?
    private(set) var computations = 0
    private(set) var memoryHits = 0
    private(set) var diskHits = 0
    private static let byteLimit = 128 * 1024 * 1024
    nonisolated static let decodedMaskLimit = 128 * 1024 * 1024

    nonisolated static func canStore(_ frames: [RecordedFrame]) -> Bool {
        frames.reduce(0) { $0 + ($1.ballMask?.alpha.count ?? 0) } <= decodedMaskLimit
    }

    init(folder: URL = URL.cachesDirectory.appendingPathComponent("SessionAnalysis-v1", isDirectory: true)) {
        self.folder = folder
    }

    /// Content identity survives source copies and app relaunches. Hash in small
    /// chunks off the UI thread; never retain a decoded video or a full file Data.
    nonisolated static func sourceDigest(_ source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func frameData(_ frames: [RecordedFrame]) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        return try encoder.encode(frames.map(StoredFrame.init))
    }

    nonisolated static func pipelineSignature() -> String {
        let resource = BallDetector.configuredResourceName
        let model = Bundle.main.url(forResource: resource, withExtension: "mlmodelc")
        let date = model.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let binaryDate = Bundle.main.executableURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let options = pipelineOptions(arguments:ProcessInfo.processInfo.arguments,defaults:.standard)
        // Increment when detector, composition geometry, counter or repair rules change.
        return "analysis-v5|\(resource)|\(date?.timeIntervalSince1970 ?? 0)|\(binaryDate?.timeIntervalSince1970 ?? 0)|\(os)|\(options)"
    }

    /// Experimental visual execution must not read or overwrite serial artifacts.
    /// Live counting provenance deliberately keeps the regular signature.
    nonisolated static func visualPipelineSignature() -> String {
        let base = pipelineSignature() + DistantBallVisualRecovery.signature()
        guard BallDetector.visualBatchSize(visualOnly:true) == 2 else { return base }
        return base + (ProcessInfo.processInfo.arguments.contains("--visual-async2")
            ? "|visual-async2-v1" : "|visual-batch2-v1")
    }

    /// Key effective settings, not how they were selected. A development launch
    /// and normal relaunch with the same model must share completed artifacts.
    nonisolated static func pipelineOptions(arguments: [String], defaults: UserDefaults) -> String {
        let resource=BallDetector.configuredResourceName(arguments:arguments,defaults:defaults)
        let guarded=resource == "KickLabYOLO26MotionSegmentation" &&
            (arguments.contains("--yolo26-motion-segmentation") ||
             (!arguments.contains("--yolo26-motion-model-only") && defaults.string(forKey:"experimentalBallModel") == "motion"))
        let roi=resource == "KickLabYOLOXTinyFineTuned" && arguments.contains("--yolox-roi")
        return [resource,"guarded=\(guarded)","roi=\(roi)",
            "retry=\(!arguments.contains("--disable-marginal-retry"))",
            "confirmation=\(!arguments.contains("--disable-ball-confirmation"))",
            "hands=\(!arguments.contains("--juggling-no-hand-check"))"].joined(separator:"|")
    }

    func saveCapture(_ data: Data, key: String) {
        guard data.count <= Self.byteLimit else { return }
        let url = folder.appendingPathComponent(key + ".capture.plist")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try? data.write(to:url,options:.atomic)
        trim(keeping:url)
    }

    func saveCounterTrace(_ value: CounterTraceArchive) {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value), data.count <= 16 * 1024 * 1024 else { return }
        let url = folder.appendingPathComponent(value.sourceDigest + "." + value.mode.rawValue + ".counter.plist")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        trim(keeping: url)
    }

    func loadCounterTrace(sourceDigest: String, mode: CounterTraceArchive.Mode) -> CounterTraceArchive? {
        let url = folder.appendingPathComponent(sourceDigest + "." + mode.rawValue + ".counter.plist")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let value = try? PropertyListDecoder().decode(CounterTraceArchive.self, from: data),
              value.sourceDigest == sourceDigest, value.mode == mode else { return nil }
        return value
    }

    func loadInference(key: String) -> StoredInference? {
        let url = folder.appendingPathComponent(key + ".inference.plist")
        guard let size = try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize, size <= Self.byteLimit,
              let data = try? Data(contentsOf:url),
              let value = try? PropertyListDecoder().decode(StoredInference.self,from:data), value.isValid else { return nil }
        return value
    }

    func saveInference(_ value: StoredInference, key: String) {
        guard value.isValid else { return }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value), data.count <= Self.byteLimit else { return }
        let url = folder.appendingPathComponent(key + ".inference.plist")
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try? data.write(to:url,options:.atomic)
        trim(keeping:url)
    }

    func prepare(key: String, onProgress: @escaping Progress = { _ in },
                 work: @escaping Work) async throws -> [RecordedFrame] {
        try Task.checkCancellation()
        if let last, last.0 == key { memoryHits += 1; onProgress(1); return last.1 }
        let url = folder.appendingPathComponent(key + ".plist")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.byteLimit,
           let data = try? Data(contentsOf: url),
           let stored = try? PropertyListDecoder().decode([StoredFrame].self, from: data),
           StoredFrame.validated(stored) {
            try Task.checkCancellation()
            let frames = stored.map(\.frame)
            last = (key, frames); diskHits += 1
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            onProgress(1); return frames
        }
        let observer = UUID()
        let task: Task<[RecordedFrame], Error>
        if var existing = pending[key] {
            existing.observers[observer] = onProgress; pending[key] = existing
            task = existing.task
        } else {
            // Do not launch competing whole-video detector passes. A second
            // session can retry after the active request finishes.
            guard pending.isEmpty else { throw PreparationError.busy }
            computations += 1
            task = VideoWorkExecution.detached {
                try await work { value in Task { await self.progress(key: key, value: value) } }
            }
            pending[key] = Pending(task: task, observers: [observer: onProgress])
        }
        defer {
            if var value = pending[key] {
                value.observers[observer] = nil
                pending[key] = value
            }
        }
        return try await withTaskCancellationHandler {
            do {
                let frames = try await task.value
                guard !task.isCancelled else { throw CancellationError() }
                // Only the first returning waiter commits the shared result.
                if pending.removeValue(forKey: key) != nil {
                    last = (key, frames)
                    if Self.canStore(frames),
                       let data = try? Self.frameData(frames), data.count <= Self.byteLimit {
                        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try? data.write(to: url, options: .atomic)
                        trim(keeping: url)
                    }
                }
                try Task.checkCancellation()
                onProgress(1)
                return frames
            } catch {
                if task.isCancelled || !(error is CancellationError) { pending[key] = nil }
                throw error
            }
        } onCancel: {
            Task { await self.removeObserver(observer, key: key) }
        }
    }

    private func removeObserver(_ observer: UUID, key: String) {
        guard var value = pending[key] else { return }
        value.observers[observer] = nil
        if value.observers.isEmpty { value.task.cancel() }
        pending[key] = value
    }

    private func progress(key: String, value: Double) {
        for observer in pending[key]?.observers.values ?? Dictionary<UUID, Progress>().values {
            observer(value)
        }
    }

    private func trim(keeping current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let rows = files.filter { $0.pathExtension == "plist" }.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 > $1.2 }
        var bytes = 0
        for (i, row) in rows.enumerated() {
            bytes += row.1
            if row.0 != current && (i >= 8 || bytes > Self.byteLimit) { try? FileManager.default.removeItem(at: row.0) }
        }
    }

    enum PreparationError: LocalizedError {
        case busy
        var errorDescription: String? { "Another video is finishing its ball effects. Please try again shortly." }
    }
}

/// Binary plist storage keeps alpha bytes compact and preserves Double values.
/// The wire format is independent of UI types and can be invalidated as a unit.
nonisolated struct StoredFrame: Codable, Sendable {
    let values: [Double]
    let detected: Bool
    let person: [Double]?
    let motion: Int
    let maskRect: [Double]?
    let maskWidth: Int?
    let maskHeight: Int?
    private let rawAlpha: Data?
    private let packedAlpha: Data?
    let usesMasks: Bool
    let repair: Bool
    let visualRecovery: Bool?
    let identity: RecordedFrameIdentity?

    private enum CodingKeys: String, CodingKey {
        case values, detected, person, motion, maskRect, maskWidth, maskHeight
        case rawAlpha = "alpha"
        case packedAlpha, usesMasks, repair, visualRecovery, identity
    }

    /// Lossless runs keep long-session masks cacheable without retaining model
    /// tensors or allocating a second whole-clip uncompressed byte archive.
    var alpha: Data? {
        if let rawAlpha { return rawAlpha }
        guard let packedAlpha, let w=maskWidth, let h=maskHeight,
              (1...128).contains(w), (1...128).contains(h) else { return nil }
        return Self.unpack(packedAlpha, count:w*h)
    }

    private static func pack(_ bytes: [UInt8]) -> Data? {
        var result=Data(), index=0
        while index < bytes.count {
            let value=bytes[index], start=index
            while index < bytes.count, bytes[index] == value, index-start < 65535 { index += 1 }
            let count=index-start
            result.append(value); result.append(UInt8(count & 255)); result.append(UInt8(count >> 8))
            if result.count >= bytes.count { return nil }
        }
        return result
    }

    private static func unpack(_ data: Data, count: Int) -> Data? {
        guard data.count % 3 == 0, data.count <= count*3 else { return nil }
        let bytes=Array(data)
        var result=Data(capacity:count)
        for i in stride(from:0,to:bytes.count,by:3) {
            let length=Int(bytes[i+1]) | (Int(bytes[i+2]) << 8)
            guard length > 0, length <= count-result.count else { return nil }
            result.append(contentsOf:repeatElement(bytes[i],count:length))
        }
        return result.count == count ? result : nil
    }

    static func validated(_ frames: [StoredFrame]) -> Bool {
        var bytes=0
        for frame in frames {
            guard frame.isValid else { return false }
            bytes += (frame.maskWidth ?? 0)*(frame.maskHeight ?? 0)
            guard bytes <= SessionAnalysisStore.decodedMaskLimit else { return false }
        }
        return true
    }

    init(_ f: RecordedFrame) {
        values = [f.time,f.x,f.y,f.width,f.height,f.score,f.smoothedX,f.smoothedY,f.vy]
        detected = f.detected
        person = f.person.map { [$0.x,$0.y,$0.width,$0.height] }
        motion = f.motion == .falling ? -1 : f.motion == .rising ? 1 : 0
        maskRect = f.ballMask.map { [$0.rect.minX,$0.rect.minY,$0.rect.width,$0.rect.height] }
        maskWidth = f.ballMask?.width; maskHeight = f.ballMask?.height
        packedAlpha = f.ballMask.flatMap { Self.pack($0.alpha) }
        rawAlpha = packedAlpha == nil ? f.ballMask.map { Data($0.alpha) } : nil
        usesMasks = f.usesBallMasks; repair = f.isVisualMaskRepair; identity = f.identity
        visualRecovery = f.isVisualRecovery ? true : nil
    }

    var isValid: Bool {
        guard values.count == 9, values.allSatisfy(\.isFinite),
              person == nil || (person!.count == 4 && person!.allSatisfy(\.isFinite)),
              [-1,0,1].contains(motion), identity == nil || identity!.isValid,
              !(repair && visualRecovery == true) else { return false }
        guard rawAlpha == nil || packedAlpha == nil else { return false }
        if let rect = maskRect {
            guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0,
                  let w = maskWidth, let h = maskHeight, (1...128).contains(w), (1...128).contains(h),
                  alpha?.count == w*h else { return false }
        } else if rawAlpha != nil || packedAlpha != nil || maskWidth != nil || maskHeight != nil { return false }
        return true
    }

    var frame: RecordedFrame {
        var f = RecordedFrame(time:values[0],x:values[1],y:values[2],width:values[3],height:values[4],
            score:values[5],smoothedX:values[6],smoothedY:values[7],vy:values[8],
            motion:motion == -1 ? .falling : motion == 1 ? .rising : .unknown,detected:detected,
            person:person.map { PersonBox(x:$0[0],y:$0[1],width:$0[2],height:$0[3]) },
            usesBallMasks:usesMasks,isVisualMaskRepair:repair)
        if let r = maskRect, let w = maskWidth, let h = maskHeight, let alpha {
            f.ballMask = BallMask(rect:CGRect(x:r[0],y:r[1],width:r[2],height:r[3]),width:w,height:h,alpha:Array(alpha))
        }
        f.identity = identity
        f.isVisualRecovery = visualRecovery == true
        return f
    }
}

nonisolated struct StoredInference: Codable, Sendable {
    let frames: [StoredFrame]
    let touches: [[Double]]
    let count: Int
    let detections: Int
    let rejected: Int
    let framesRead: Int
    let duration: Double
    let peak: Double
    let model: String
    let elapsed: Double
    /// Only additions; original frames and counting statistics retain their old meaning.
    var visualRecoveries: [StoredFrame]? = nil
    var isValid: Bool {
        StoredFrame.validated(frames + (visualRecoveries ?? []))
        && frames.allSatisfy { $0.visualRecovery != true }
        && (visualRecoveries ?? []).allSatisfy { $0.visualRecovery == true && $0.detected && $0.usesMasks && $0.maskRect != nil }
        && touches.allSatisfy {
            $0.count == 4 && $0.allSatisfy(\.isFinite) && $0[0] >= 0 && $0[0] < 1_000_000_000
                && $0[0].rounded() == $0[0] && $0[1] >= 0
        } && count >= 0 && detections >= 0 && rejected >= 0 && framesRead >= frames.count + (visualRecoveries?.count ?? 0)
            && duration.isFinite && duration >= 0 && peak.isFinite && elapsed.isFinite && elapsed >= 0
            && zip(frames, frames.dropFirst()).allSatisfy { $0.values[0] <= $1.values[0] }
    }
    var recordedTouches: [RecordedTouch] {
        touches.map { RecordedTouch(index:Int($0[0]),time:$0[1],x:$0[2],y:$0[3]) }
    }
}
