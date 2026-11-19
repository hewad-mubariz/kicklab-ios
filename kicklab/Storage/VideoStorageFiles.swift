import Foundation

/// Only app-owned local files. Photos, account records and settings are never candidates.
nonisolated struct VideoStorageFiles: Sendable {
    let historyRoot: URL
    let cacheRoot: URL
    let temporaryRoot: URL
    let documentsRoot: URL
    private var predictionRoot: URL { historyRoot.deletingLastPathComponent().appendingPathComponent("Predictions-v1") }

    init(historyRoot: URL, cacheRoot: URL, temporaryRoot: URL, documentsRoot: URL) {
        self.historyRoot = historyRoot; self.cacheRoot = cacheRoot
        self.temporaryRoot = temporaryRoot; self.documentsRoot = documentsRoot
    }

    init(library: SessionHistoryLibrary) {
        let production = URL.applicationSupportDirectory.appendingPathComponent("JuggleDudeResults/History")
        historyRoot = library.root
        // UI reviews and unit-test libraries must never clear the real app's files.
        if library.root.standardizedFileURL == production.standardizedFileURL {
            cacheRoot = .cachesDirectory; temporaryRoot = .temporaryDirectory; documentsRoot = .documentsDirectory
        } else {
            let root = library.root.deletingLastPathComponent()
            cacheRoot = root.appendingPathComponent("ProcessingCaches")
            temporaryRoot = root.appendingPathComponent("TemporaryVideoFiles")
            documentsRoot = root.appendingPathComponent("BenchmarkFiles")
        }
    }

    struct Snapshot: Sendable {
        var saved: Int64 = 0
        var cached: Int64 = 0
        var benchmarks: Int64 = 0
    }

    func snapshot() throws -> Snapshot {
        let saved = try files(in: historyRoot)
        let cache = try cacheCandidates() + temporaryExports() + duplicateImports()
        return Snapshot(saved: bytes(saved), cached: bytes(Array(Set(cache))), benchmarks: bytes(try benchmarkFiles()))
    }

    func clearCaches() throws {
        for file in Set(try cacheCandidates() + temporaryExports() + duplicateImports()) { try remove(file) }
    }

    /// These shared results can be regenerated. Saved analyses of other sessions remain intact.
    func clearSharedVideoCaches() throws {
        for name in ["SessionAnalysis-v1", "SessionSpin-v3", "EffectPreview-v1"] {
            for file in try files(in: cacheRoot.appendingPathComponent(name)) { try remove(file) }
        }
        for file in try temporaryExports() { try remove(file) }
    }

    func removeTemporaryCopies(of source: URL) throws {
        guard isRegular(source) else { return }
        let size = fileBytes(source)
        let candidates = try files(in: temporaryRoot).filter { isImportedCopy($0) && $0 != source && fileBytes($0) == size }
        guard !candidates.isEmpty else { return }
        let digest = try SessionAnalysisStore.sourceDigest(source)
        for file in candidates where try SessionAnalysisStore.sourceDigest(file) == digest { try remove(file) }
    }

    func cleanupRetainedImport(source: URL, retained: URL) throws {
        guard isImportedCopy(source), isRegular(retained), fileBytes(source) == fileBytes(retained),
              try SessionAnalysisStore.sourceDigest(source) == SessionAnalysisStore.sourceDigest(retained) else { return }
        try remove(source)
    }

    func clearBenchmarks() throws { for file in try benchmarkFiles() { try remove(file) } }

    private func cacheCandidates() throws -> [URL] {
        // Cached masks/spin in History are rebuildable; edits and counting records are not.
        try files(in: cacheRoot) + files(in: predictionRoot) + files(in: historyRoot).filter {
            $0.lastPathComponent.hasSuffix(".analysis.plist") || $0.lastPathComponent.hasSuffix(".motion.plist")
        }
    }

    private func temporaryExports() throws -> [URL] {
        try files(in: temporaryRoot).filter {
            let name = $0.lastPathComponent
            return ["juggledude-render-", "juggledude-edited-", "juggledude-sounds-", "power-shot-"].contains(where: name.hasPrefix)
                && ["mov", "mp4", "m4a"].contains($0.pathExtension.lowercased())
        }
    }

    private func duplicateImports() throws -> [URL] {
        let originals = try files(in: historyRoot).filter { $0.pathExtension.lowercased() == "mov" }
        let grouped = Dictionary(grouping: originals, by: fileBytes)
        var digests: [URL: String] = [:]
        var duplicates: [URL] = []
        for file in try files(in: temporaryRoot) where isImportedCopy(file) {
            guard let matches = grouped[fileBytes(file)], !matches.isEmpty else { continue }
            let digest = try SessionAnalysisStore.sourceDigest(file)
            for original in matches {
                let originalDigest: String
                if let cached = digests[original] { originalDigest = cached }
                else { originalDigest = try SessionAnalysisStore.sourceDigest(original); digests[original] = originalDigest }
                if digest == originalDigest { duplicates.append(file); break }
            }
        }
        return duplicates
    }

    private func benchmarkFiles() throws -> [URL] {
        #if DEBUG
        return try files(in: documentsRoot).filter { file in
            let relative = String(file.path.dropFirst(documentsRoot.path.count + 1))
            return ["pipeline-9064", "background-", "pose-", "pose17-", "exact-clip-check/", "DetectorBenchmarks/"].contains(where: relative.hasPrefix)
        }
        #else
        return []
        #endif
    }

    func isImportedCopy(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == temporaryRoot.resolvingSymlinksInPath(),
              isRegular(url), url.pathExtension.lowercased() == "mov" else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        let prefix = stem.hasPrefix("juggledude-run-") ? "juggledude-run-" : "juggledude-"
        return stem.hasPrefix(prefix) && UUID(uuidString: String(stem.dropFirst(prefix.count))) != nil
    }

    func files(in root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let rootValues = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues.isSymbolicLink != true else { return [] }
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in failure = error; return false }) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true { result.append(url) }
        }
        if let failure { throw failure }
        return result
    }
    private func isRegular(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
    private func fileBytes(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    private func bytes(_ urls: [URL]) -> Int64 { urls.reduce(0) { $0 + fileBytes($1) } }
    private func remove(_ url: URL) throws {
        // A malicious/stale symlink must never redirect cleanup outside these roots.
        let resolved = url.resolvingSymlinksInPath().path
        guard [historyRoot, cacheRoot, temporaryRoot, documentsRoot, predictionRoot].contains(where: {
            resolved.hasPrefix($0.resolvingSymlinksInPath().path + "/")
        }), isRegular(url) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
