import Foundation

nonisolated struct HistorySession: Codable, Equatable, Identifiable, Sendable {
    enum SyncState: String, Codable, Sendable { case saving, deviceOnly, pending, synced }
    let id: UUID
    let ownerID: UUID?
    let touches: Int
    let durationMS: Int
    let source: SavedJugglingResult.Source
    let completedAt: Date
    var syncState: SyncState
    var scoreStatus: String = "device_reported"

    init(result: SavedJugglingResult, syncState: SyncState = .pending) {
        id = result.id; ownerID = result.ownerID; touches = result.touches
        durationMS = result.durationMS; source = result.source; completedAt = result.completedAt
        self.syncState = syncState
    }

    init(id: UUID, ownerID: UUID?, touches: Int, durationMS: Int, source: SavedJugglingResult.Source,
         completedAt: Date, syncState: SyncState, scoreStatus: String = "device_reported") {
        self.id = id; self.ownerID = ownerID; self.touches = touches; self.durationMS = durationMS
        self.source = source; self.completedAt = completedAt; self.syncState = syncState; self.scoreStatus = scoreStatus
    }

    var durationLabel: String {
        let seconds = Int((Double(durationMS) / 1000).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    var sourceLabel: String { source == .recording ? "Recorded" : "Imported" }
    var syncLabel: String {
        switch syncState {
        case .saving: "Session ready"
        case .deviceOnly: "On this device"
        case .pending: "Saved on this phone"
        case .synced: "Saved to account"
        }
    }
    var syncIcon: String {
        switch syncState {
        case .saving: "checkmark"
        case .deviceOnly: "iphone"
        case .pending: "arrow.trianglehead.2.clockwise.rotate.90"
        case .synced: "checkmark.icloud"
        }
    }
}

/// A small recovery journal; no video bytes or analysis buffers are encoded.
nonisolated struct SessionSaveRequest: Codable, Sendable {
    let item: HistorySession
    let result: SavedJugglingResult?
    let videoURL: URL
    var key: String { "\(item.ownerID?.uuidString ?? "guest")/\(item.id.uuidString)" }

    func persist(library: SessionHistoryLibrary, queue: JugglingResultQueue) throws -> HistorySession {
        try library.saveRequest(self)
        let existing = try library.session(id: item.id, owner: item.ownerID)
        // The outbox becomes visible only after the history write. Recovery
        // must never downgrade a result already acknowledged by the server.
        if existing == nil { try library.save(item) }
        if let result, existing?.syncState != .synced { try queue.save(result) }
        return existing ?? item
    }
}

/// Keep the original timestamp string: rounding PostgreSQL microseconds can skip
/// rows at a page boundary. UUID breaks ties between identical timestamps.
struct SessionHistoryCursor: Equatable, Sendable {
    let timestamp: String
    let id: UUID
}

struct SessionHistoryPage: Sendable {
    let items: [HistorySession]
    let next: SessionHistoryCursor?
    static let size = 30

    static func query(userID: UUID, before: SessionHistoryCursor?) -> [URLQueryItem] {
        var query: [URLQueryItem] = [
            .init(name: "select", value: "id,user_id,touch_count,duration_ms,source,completed_at,score_status"),
            .init(name: "user_id", value: "eq.\(userID.uuidString)"),
            .init(name: "order", value: "completed_at.desc,id.desc"),
            .init(name: "limit", value: "\(size + 1)")
        ]
        if let before {
            query.append(.init(name: "or", value: "(completed_at.lt.\(before.timestamp),and(completed_at.eq.\(before.timestamp),id.lt.\(before.id.uuidString)))"))
        }
        return query
    }

    static func decode(_ data: Data, owner: UUID) throws -> Self {
        struct Row: Decodable {
            let id: UUID
            let user_id: UUID
            let touch_count: Int
            let duration_ms: Int
            let source: SavedJugglingResult.Source
            let completed_at: String
            let score_status: String
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let items = try rows.prefix(size).map { row in
            guard row.user_id == owner,
                  let date = fractional.date(from: row.completed_at) ?? plain.date(from: row.completed_at) else {
                throw PlayerDataError.requestFailed
            }
            return HistorySession(id: row.id, ownerID: owner, touches: row.touch_count,
                durationMS: row.duration_ms, source: row.source, completedAt: date,
                syncState: .synced, scoreStatus: row.score_status)
        }
        let last = rows.prefix(size).last
        let next = rows.count > size ? last.map { SessionHistoryCursor(timestamp: $0.completed_at, id: $0.id) } : nil
        return .init(items: items, next: next)
    }
}

/// Metadata is durable and account-scoped. Videos stay private on this device,
/// outside temporary storage, with no raw analysis/mask buffers in history.
nonisolated struct SessionHistoryLibrary: Sendable {
    let root: URL
    private func folder(_ owner: UUID?) -> URL {
        root.appendingPathComponent(owner?.uuidString ?? "guest", isDirectory: true)
    }
    private func videoPath(_ item: HistorySession) -> URL {
        folder(item.ownerID).appendingPathComponent(item.id.uuidString + ".mov")
    }
    private func requestPath(_ item: HistorySession) -> URL {
        folder(item.ownerID).appendingPathComponent(item.id.uuidString + ".save-request.json")
    }
    func saveRequest(_ request: SessionSaveRequest) throws {
        try AccountDataGuard.write(owner: request.item.ownerID, root: root.deletingLastPathComponent()) {
            try FileManager.default.createDirectory(at: folder(request.item.ownerID), withIntermediateDirectories: true)
            try JSONEncoder().encode(request).write(to: requestPath(request.item), options: [.atomic, .completeFileProtection])
        }
    }
    func finishRequest(_ item: HistorySession) throws {
        let path = requestPath(item)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    func pendingRequests(owner: UUID?) throws -> [SessionSaveRequest] {
        guard FileManager.default.fileExists(atPath: folder(owner).path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder(owner), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".save-request.json") }
            .compactMap { try? JSONDecoder().decode(SessionSaveRequest.self, from: Data(contentsOf: $0)) }
            .filter { $0.item.ownerID == owner }
    }
    func session(id: UUID, owner: UUID?) throws -> HistorySession? {
        let url = folder(owner).appendingPathComponent(id.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(HistorySession.self, from: Data(contentsOf: url))
    }
    func save(_ item: HistorySession) throws {
        try AccountDataGuard.write(owner: item.ownerID, root: root.deletingLastPathComponent()) {
            try FileManager.default.createDirectory(at: folder(item.ownerID), withIntermediateDirectories: true)
            try JSONEncoder().encode(item).write(to: folder(item.ownerID).appendingPathComponent(item.id.uuidString + ".json"),
                options: [.atomic, .completeFileProtection])
        }
    }
    func sessions(owner: UUID?) throws -> [HistorySession] {
        guard FileManager.default.fileExists(atPath: folder(owner).path) else { return [] }
        // An unreadable record must not hide every other saved session.
        return try FileManager.default.contentsOfDirectory(at: folder(owner), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(HistorySession.self, from: Data(contentsOf: $0)) }
            .filter { $0.ownerID == owner }
            .sorted { $0.completedAt == $1.completedAt ? $0.id.uuidString > $1.id.uuidString : $0.completedAt > $1.completedAt }
    }
    func videoURL(for item: HistorySession) -> URL? {
        let url = videoPath(item)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func retainVideo(_ source: URL, for item: HistorySession) async throws {
        let destination = videoPath(item)
        try await Task.detached(priority: .utility) {
            try Self.copyVideo(source, to: destination, owner: item.ownerID, accountRoot: root.deletingLastPathComponent())
        }.value
    }
    func removeVideo(for item: HistorySession) throws {
        if let url = videoURL(for: item) { try FileManager.default.removeItem(at: url) }
    }
    func removeAccount(_ owner: UUID) throws {
        let url = folder(owner)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    nonisolated private static func copyVideo(_ source: URL, to destination: URL, owner: UUID?, accountRoot: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { return }
        try AccountDataGuard.write(owner: owner, root: accountRoot) {
            try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // A retry replaces only this session's interrupted copy.
        let partial = destination.appendingPathExtension("partial")
        if files.fileExists(atPath: partial.path) { try files.removeItem(at: partial) }
        defer { try? files.removeItem(at: partial) }
        try files.copyItem(at: source, to: partial)
        try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: partial.path)
        var excluded = partial
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        try AccountDataGuard.write(owner: owner, root: accountRoot) { try files.moveItem(at: partial, to: destination) }
    }
}
