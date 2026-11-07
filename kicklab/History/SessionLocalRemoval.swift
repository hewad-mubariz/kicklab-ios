import Foundation

extension SessionHistoryLibrary {
    nonisolated func isLocallyDeleted(id: UUID, owner: UUID?) -> Bool {
        FileManager.default.fileExists(atPath: localMarker(id: id, owner: owner).path)
    }

    nonisolated func requireLocalSession(id: UUID, owner: UUID?) throws {
        guard !isLocallyDeleted(id: id, owner: owner) else { throw CancellationError() }
    }

    /// Durable local tombstone prevents refresh and late writes resurrecting this row.
    /// Account results and their small outbox records retain their existing sync semantics.
    nonisolated func removeLocalSession(_ item: HistorySession) throws {
        try AccountDataGuard.write(owner: item.ownerID, root: root.deletingLastPathComponent()) {
            let marker = localMarker(id: item.id, owner: item.ownerID)
            try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker, options: [.atomic, .completeFileProtection])
            try finishLocalRemoval(id: item.id, owner: item.ownerID)
        }
    }

    nonisolated func reconcileLocalRemovals(owner: UUID?) throws {
        let folder = root.appendingPathComponent(owner?.uuidString ?? "guest")
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasSuffix(".session-removed") {
            if let id = UUID(uuidString: String(file.lastPathComponent.prefix(36))) {
                try AccountDataGuard.write(owner: owner, root: root.deletingLastPathComponent()) {
                    try finishLocalRemoval(id: id, owner: owner)
                }
            }
        }
    }

    nonisolated func cleanupRetainedImport(id: UUID, owner: UUID?) throws {
        let folder = root.appendingPathComponent(owner?.uuidString ?? "guest")
        let manifest = folder.appendingPathComponent(id.uuidString + ".import-source")
        guard let path = try? String(contentsOf: manifest, encoding: .utf8) else { return }
        let source = URL(fileURLWithPath: path)
        let retained = folder.appendingPathComponent(id.uuidString + ".mov")
        try VideoStorageFiles(library: self).cleanupRetainedImport(source: source, retained: retained)
        if !FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: manifest) }
    }

    nonisolated private func localMarker(id: UUID, owner: UUID?) -> URL {
        root.appendingPathComponent(owner?.uuidString ?? "guest").appendingPathComponent(id.uuidString + ".session-removed")
    }
    nonisolated private func finishLocalRemoval(id: UUID, owner: UUID?) throws {
        let marker = localMarker(id: id, owner: owner)
        for file in try FileManager.default.contentsOfDirectory(at: marker.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix(id.uuidString + ".") && file != marker {
            try FileManager.default.removeItem(at: file)
        }
    }
}
