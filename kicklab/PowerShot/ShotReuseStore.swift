import CryptoKit
import Foundation

/// Complete, content-addressed PowerShot artifacts. Appearance is deliberately not a key.
/// Callers save only after their complete native operation succeeds.
nonisolated struct ShotReuseStore: Sendable {
    private static let writeLock = NSLock()
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Saved shot analysis: " + detail }
    }
    private struct Envelope: Codable {
        let version: Int
        let source: String
        let contract: String
        let payload: Data
        let checksum: String
    }
    let root: URL
    var payloadLimit = 128 * 1024 * 1024
    var totalLimit = 512 * 1024 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func sourceDigest(_ source: URL) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data); return true
        }) { }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func file(source: String, contract: String) -> URL {
        root.appendingPathComponent(Self.digest(Data(("shot-reuse-v1|"+source+"|"+contract).utf8))+".shotreuse")
    }
    func load(source: String, contract: String) throws -> Data? {
        let url = file(source: source, contract: contract)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= payloadLimit + 64 * 1024 else { throw Failure(detail: "Artifact exceeds storage limit") }
        let data = try Data(contentsOf: url)
        let value: Envelope
        do { value = try PropertyListDecoder().decode(Envelope.self, from: data) }
        catch { throw Failure(detail: "Unreadable artifact") }
        guard value.version == 1, value.source == source, value.contract == contract,
              value.payload.count <= payloadLimit, value.checksum == Self.digest(value.payload) else {
            throw Failure(detail: "Artifact identity or checksum mismatch")
        }
        return value.payload
    }
    func save(_ payload: Data, source: String, contract: String) throws {
        try Self.writeLock.withLock { try saveLocked(payload, source: source, contract: contract) }
    }
    private func saveLocked(_ payload: Data, source: String, contract: String) throws {
        try Task.checkCancellation()
        guard source.count == 64, !contract.isEmpty, payload.count <= payloadLimit else {
            throw Failure(detail: "Invalid or oversized artifact")
        }
        if let previous = try load(source: source, contract: contract) {
            guard previous == payload else { throw Failure(detail: "Conflicting completed artifact") }
            return
        }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(Envelope(version: 1, source: source, contract: contract,
            payload: payload, checksum: Self.digest(payload)))
        let destination = file(source: source, contract: contract)
        let used = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "shotreuse" && $0 != destination }
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        guard used <= totalLimit - data.count else { throw Failure(detail: "Storage limit reached") }
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }
}
