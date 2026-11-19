import CryptoKit
import Foundation

/// Completed neutral previews belong to source bytes and rendering policy, never a model or look.
actor PreviewMovieCache {
    typealias Render = @Sendable (URL) async throws -> URL
    typealias Validate = @Sendable (URL) async throws -> Bool
    private nonisolated struct Receipt: Codable, Sendable { let bytes: Int; let digest: String }
    private struct Pending {
        let id: UUID
        let task: Task<URL, Error>
        var observers: Set<UUID>
    }
    private let folder: URL, policy: String
    private let byteLimit: Int, fileLimit: Int
    private let render: Render, validate: Validate
    private var pending: [String: Pending] = [:]
    // Files handed to players are not evicted during this cache's lifetime.
    private var protected = Set<String>()
    private var temporary: [String: URL] = [:]
    private var running = 0
    var isBusy: Bool { running > 0 || !pending.isEmpty }

    init(folder: URL, policy: String, byteLimit: Int = 1_024 * 1_024 * 1_024,
         fileLimit: Int = 4, render: @escaping Render, validate: @escaping Validate) {
        self.folder = folder; self.policy = policy; self.byteLimit = byteLimit
        self.fileLimit = fileLimit; self.render = render; self.validate = validate
    }

    func releaseMemory() { protected.removeAll(); temporary.removeAll() }

    func existing(for source: URL) async throws -> URL? {
        // The common direct-preview path never scans the source for a cache that does not exist.
        guard !temporary.isEmpty || !movies().isEmpty else { return nil }
        let key = try await contentKey(source)
        if let url = temporary[key], FileManager.default.fileExists(atPath: url.path) { return url }
        if let url = try await read(key) { protected.insert(url.standardizedFileURL.path); return url }
        return nil
    }

    func converted(_ source: URL) async throws -> URL {
        let key = try await contentKey(source)
        try Task.checkCancellation()
        let observer = UUID()
        let work: Pending
        if var existing = pending[key] {
            existing.observers.insert(observer); pending[key] = existing; work = existing
        } else {
            let id = UUID()
            let task = Task { try await self.produce(source, key: key, id: id) }
            work = Pending(id: id, task: task, observers: [observer]); pending[key] = work
        }
        return try await withTaskCancellationHandler {
            do {
                let url = try await work.task.value
                try Task.checkCancellation()
                leave(key, id: work.id, observer: observer, cancel: false)
                return url
            } catch {
                leave(key, id: work.id, observer: observer, cancel: Task.isCancelled)
                throw error
            }
        } onCancel: {
            Task { await self.leave(key, id: work.id, observer: observer, cancel: true) }
        }
    }

    private func leave(_ key: String, id: UUID, observer: UUID, cancel: Bool) {
        guard var work = pending[key], work.id == id else { return }
        work.observers.remove(observer)
        if work.observers.isEmpty {
            pending[key] = nil
            if cancel { work.task.cancel() }
        } else { pending[key] = work }
    }

    private func produce(_ source: URL, key: String, id: UUID) async throws -> URL {
        running += 1; defer { running -= 1 }
        if let url = temporary[key], FileManager.default.fileExists(atPath: url.path) { return url }
        if let url = try await read(key) { protected.insert(url.standardizedFileURL.path); return url }
        let render = self.render
        let worker = Task.detached(priority: .userInitiated) { try await render(source) }
        let output = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        var retained = false
        defer { if !retained, output != source { try? FileManager.default.removeItem(at: output) } }
        try Task.checkCancellation()
        guard output != source, try await validate(output) else { throw Failure.invalidOutput }
        let checksum = try await Self.fingerprint(output)
        try Task.checkCancellation()
        guard pending[key]?.id == id else { throw CancellationError() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = movie(key)
        // A damaged receipt/movie must not consume the slot needed for its replacement.
        if !protected.contains(destination.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: receipt(key))
        }
        // Bound retained disk data. Oversized previews remain session-only temporary results.
        if protected.contains(destination.standardizedFileURL.path) || checksum.bytes > byteLimit || !makeRoom(bytes: checksum.bytes) {
            temporary[key] = output; retained = true; return output
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: output, to: destination)
        do {
            // Publish the receipt last. Partial/cancelled work is never a cache hit.
            try JSONEncoder().encode(checksum).write(to: receipt(key), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination); throw error
        }
        protected.insert(destination.standardizedFileURL.path); retained = true
        return destination
    }

    private func contentKey(_ source: URL) async throws -> String {
        let content = try await Self.fingerprint(source)
        return SHA256.hash(data: Data((policy + "|" + content.digest).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func read(_ key: String) async throws -> URL? {
        let url = movie(key)
        guard let data = try? Data(contentsOf: receipt(key)),
              let expected = try? JSONDecoder().decode(Receipt.self, from: data),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              expected.bytes > 0, size == expected.bytes else { return nil }
        do {
            let actual = try await Self.fingerprint(url)
            guard actual.digest == expected.digest, try await validate(url) else { return nil }
            try Task.checkCancellation()
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    private func movie(_ key: String) -> URL { folder.appendingPathComponent(key + ".mov") }
    private func receipt(_ key: String) -> URL { folder.appendingPathComponent(key + ".json") }
    private func movies() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "mov" }
    }
    private func makeRoom(bytes: Int) -> Bool {
        let all = movies().sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        var count = all.count
        var total = all.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for url in all where !protected.contains(url.standardizedFileURL.path) {
            if count < fileLimit && total + bytes <= byteLimit { break }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("json"))
                total -= size; count -= 1
            } catch { continue }
        }
        return count < fileLimit && total + bytes <= byteLimit
    }

    private nonisolated static func fingerprint(_ source: URL) async throws -> Receipt {
        let worker = Task.detached(priority: .utility) { () throws -> Receipt in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var hash = SHA256(), bytes = 0
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                hash.update(data: data); bytes += data.count; return true
            }) { }
            return Receipt(bytes: bytes, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    enum Failure: Error { case invalidOutput }
}
