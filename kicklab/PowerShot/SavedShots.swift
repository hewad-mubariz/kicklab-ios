import AVFoundation
import Foundation

/// One Ball Distance shot kept on this phone. Its folder holds the video, the finished ball
/// track and the editor's choices, so reopening skips tracking and brings the look back.
nonisolated struct SavedShot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let ownerID: UUID?
    let videoFile: String
    let durationMS: Int
    let source: SavedJugglingResult.Source
    let completedAt: Date

    var durationLabel: String {
        let seconds = Int((Double(durationMS) / 1000).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sourceLabel: String {
        source == .recording
            ? String(localized: "shot.source.recorded", defaultValue: "Recorded", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            : String(localized: "shot.source.imported", defaultValue: "Imported", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
}

/// Account-scoped like session history. The record is written last, so a shot that didn't
/// finish saving never appears.
nonisolated struct SavedShotLibrary: Sendable {
    let root: URL
    private var accountRoot: URL { root.deletingLastPathComponent() }
    private func folder(_ owner: UUID?) -> URL {
        root.appendingPathComponent(owner?.uuidString ?? "guest", isDirectory: true)
    }
    private func directory(id: UUID, owner: UUID?) -> URL {
        folder(owner).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    private func lookURL(id: UUID, owner: UUID?) -> URL {
        directory(id: id, owner: owner).appendingPathComponent("look.json")
    }

    func videoURL(for shot: SavedShot) -> URL {
        directory(id: shot.id, owner: shot.ownerID).appendingPathComponent(shot.videoFile)
    }
    func trackURL(id: UUID, owner: UUID?) -> URL {
        directory(id: id, owner: owner).appendingPathComponent("ball-track.plist")
    }

    /// Moves a finished recording or picked video in. The file stays readable while the phone
    /// is locked, because a Download started from the editor keeps running in the background.
    func add(video: URL, id: UUID, owner: UUID?, source: SavedJugglingResult.Source, completedAt: Date) async throws -> SavedShot {
        let seconds = try await AVURLAsset(url: video).load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let shot = SavedShot(id: id, ownerID: owner, videoFile: "video." + (video.pathExtension.isEmpty ? "mov" : video.pathExtension),
            durationMS: Int((seconds * 1000).rounded()), source: source, completedAt: completedAt)
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            var shotFolder = directory(id: id, owner: owner)
            try AccountDataGuard.write(owner: owner, root: accountRoot) {
                try files.createDirectory(at: shotFolder, withIntermediateDirectories: true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try shotFolder.setResourceValues(values)
                try files.moveItem(at: video, to: videoURL(for: shot))
                try files.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                        ofItemAtPath: videoURL(for: shot).path)
                try JSONEncoder().encode(shot).write(to: shotFolder.appendingPathComponent("shot.json"),
                                                     options: [.atomic, .completeFileProtection])
            }
        }.value
        return shot
    }

    func shots(owner: UUID?) throws -> [SavedShot] {
        guard FileManager.default.fileExists(atPath: folder(owner).path) else { return [] }
        // An unreadable record must not hide every other saved shot.
        return try FileManager.default.contentsOfDirectory(at: folder(owner), includingPropertiesForKeys: nil)
            .compactMap { folder -> SavedShot? in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("shot.json")),
                      let shot = try? JSONDecoder().decode(SavedShot.self, from: data),
                      shot.ownerID == owner, FileManager.default.fileExists(atPath: videoURL(for: shot).path) else { return nil }
                return shot
            }
            .sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
    }

    func look(id: UUID, owner: UUID?) -> ShotReplayLook? {
        guard let data = try? Data(contentsOf: lookURL(id: id, owner: owner)) else { return nil }
        return try? JSONDecoder().decode(ShotReplayLook.self, from: data)
    }
    /// Fails when the shot has no folder, so a shot that wasn't saved leaves nothing behind.
    func saveLook(_ look: ShotReplayLook, id: UUID, owner: UUID?) throws {
        try AccountDataGuard.write(owner: owner, root: accountRoot) {
            try JSONEncoder().encode(look).write(to: lookURL(id: id, owner: owner), options: [.atomic, .completeFileProtection])
        }
    }

    func remove(id: UUID, owner: UUID?) throws {
        let url = directory(id: id, owner: owner)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    func removeAccount(_ owner: UUID) throws {
        let url = folder(owner)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
