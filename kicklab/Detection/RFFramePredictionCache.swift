import CoreGraphics
import CoreML
import CryptoKit
import Foundation
import UIKit

/// Bounded memoization of the stateless RF prediction, before association or counting.
/// A timestamp or a nearby mask is never a hit: the normalized tensor must match byte for byte.
/// The cache owns decoded boxes/compact masks, never a movie frame, input or model-output tensor.
nonisolated final class RFFramePredictionCache: @unchecked Sendable {
    struct Input: Hashable, Sendable {
        let digest: Data
        let edge: Int
        let width: Int
        let height: Int
    }
    struct Key: Hashable, Sendable {
        let input: Input
        let model: String
        let cpuOnly: Bool
        let threshold: Double
    }
    private struct Entry { let detections: FrameDetections; let bytes: Int }
    private let lock = NSLock()
    private let byteLimit: Int
    private let disk: RFPredictionDiskStore?
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var hits = 0

    init(byteLimit: Int = 16 * 1024 * 1024, disk: RFPredictionDiskStore? = nil) {
        self.byteLimit = max(0, byteLimit); self.disk = disk
    }
    var isPersistent: Bool { disk != nil }

    static func input(_ provider: MLFeatureProvider, sourceSize: CGSize) -> Input? {
        guard let tensor = provider.featureValue(for: "tensors")?.multiArrayValue,
              tensor.dataType == .float32, tensor.shape.count == 4 else { return nil }
        let shape = tensor.shape.map(\.intValue), strides = tensor.strides.map(\.intValue)
        let n = shape[3]
        guard n > 0, n <= 1024, shape == [1, 3, n, n], strides == [3 * n * n, n * n, n, 1],
              sourceSize.width.isFinite, sourceSize.height.isFinite,
              (1...65536).contains(sourceSize.width), (1...65536).contains(sourceSize.height),
              sourceSize.width.rounded() == sourceSize.width, sourceSize.height.rounded() == sourceSize.height else { return nil }
        let raw = UnsafeRawBufferPointer(start: tensor.dataPointer, count: tensor.count * MemoryLayout<Float>.stride)
        return Input(digest: Data(SHA256.hash(data: raw)), edge: n,
                     width: Int(sourceSize.width), height: Int(sourceSize.height))
    }

    func lookup(_ key: Key) throws -> FrameDetections? {
        lock.lock(); defer { lock.unlock() }
        if let found = entries[key] { hits += 1; return found.detections }
        guard let found = try disk?.lookup(key) else { return nil }
        hits += 1; retain(found, for: key)
        return found
    }

    func store(_ value: FrameDetections, for key: Key) throws {
        lock.lock(); defer { lock.unlock() }
        if let disk, try !disk.store(value, for: key) {
            guard let existing = try disk.lookup(key) else { throw RFPredictionDiskStore.Failure(detail: "Committed prediction disappeared") }
            retain(existing, for: key)
            return
        }
        retain(value, for: key)
    }

    private func retain(_ value: FrameDetections, for key: Key) {
        var compact = value
        compact.ballMask = value.ballMask?.compacted()
        let cost = 256 + key.model.utf8.count + compact.people.count * 40 + (compact.ballMask?.storageByteCount ?? 0)
        guard cost <= byteLimit else { return }
        // Both passes read the clip in order, so evicting the oldest would drop what the second
        // pass reaches next and a clip over the limit would reuse nothing. Once full, later
        // frames run the model and the start of the clip is still reused.
        guard entries[key] == nil else { return }
        // Disk-backed entries remain available after RAM pressure. Keep a bounded
        // read-through window; never discard the persistent record to make room.
        if disk != nil, bytes + cost > byteLimit { entries.removeAll(); bytes = 0 }
        guard bytes + cost <= byteLimit else { return }
        entries[key] = Entry(detections: compact, bytes: cost)
        bytes += cost
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll(); bytes = 0
    }

    var retainedBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var hitCount: Int { lock.lock(); defer { lock.unlock() }; return hits }
    var diskHitCount: Int { lock.lock(); defer { lock.unlock() }; return disk?.reads ?? 0 }
    var diskWriteCount: Int { lock.lock(); defer { lock.unlock() }; return disk?.writes ?? 0 }
}

/// Offline analyses are serialized; retain only the latest clip's predictions between its
/// counting and appearance passes. A source/pipeline change releases the previous cache.
nonisolated final class RFFramePredictionReuse: @unchecked Sendable {
    static let shared = RFFramePredictionReuse()
    private let lock = NSLock()
    private var current: (String, RFFramePredictionCache)?

    static var persistenceEnabled: Bool {
        #if DEBUG
        return Bundle.main.bundleIdentifier == "com.juggledude.counterresearch.debug"
            && ProcessInfo.processInfo.arguments.contains("--durable-rf-reuse")
        #else
        return false
        #endif
    }

    func persistentCache(for sourceDigest: String) throws -> RFFramePredictionCache {
        lock.lock(); defer { lock.unlock() }
        let runtime = RFDeviceProfile.hardwareIdentifier + "|" + ProcessInfo.processInfo.operatingSystemVersionString
        let identity = "persistent|" + sourceDigest + "|" + runtime
        if let current, current.0 == identity { return current.1 }
        let disk = try RFPredictionDiskStore(source: sourceDigest, runtime: runtime)
        let cache = RFFramePredictionCache(disk: disk)
        current = (identity, cache)
        return cache
    }

    init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.release() }
    }

    /// The appearance pass has read what it needs, or the phone needs the memory.
    func release() {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }

    func cache(for sourceAndPipeline: String) -> RFFramePredictionCache {
        lock.lock(); defer { lock.unlock() }
        if let current, current.0 == sourceAndPipeline { return current.1 }
        let cache = RFFramePredictionCache()
        current = (sourceAndPipeline, cache)
        return cache
    }
}
