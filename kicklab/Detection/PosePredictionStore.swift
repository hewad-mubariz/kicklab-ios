import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import SQLite3

/// Stateless observations before player association. No pixels or temporal decisions
/// are retained. Each successful write is committed before the caller continues.
nonisolated final class PosePredictionStore: @unchecked Sendable {
    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Could not preserve reusable pose observations. " + detail }
    }
    struct Key: Hashable { let kind: String; let pixels: Data }
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let namespace: Data
    private var hits: [String: Int] = [:], writes: [String: Int] = [:]
    static let payloadLimit = 256 * 1024

    init(root: URL, source: String, runtime: String, byteLimit: Int = 512 * 1024 * 1024) throws {
        namespace = Self.digest(Data((source + "|" + runtime + "|pose-observations-v1").utf8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root, values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let path = root.appendingPathComponent("poses.sqlite3").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        do {
            sqlite3_busy_timeout(db, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA wal_autocheckpoint=256")
            try execute("PRAGMA journal_size_limit=4194304")
            let statement = try prepare("PRAGMA page_size"); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
            let pageSize = Int(sqlite3_column_int(statement, 0))
            try execute("PRAGMA max_page_count=\(max(16, byteLimit / pageSize))")
            try execute("CREATE TABLE IF NOT EXISTS observations (clip BLOB NOT NULL, kind TEXT NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, checksum BLOB NOT NULL, PRIMARY KEY(clip,kind,key)) WITHOUT ROWID")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func failure() -> Failure { Failure(detail: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database") }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }
    private func bind(_ data: Data, _ index: Int32, _ statement: OpaquePointer) throws {
        let rc = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard rc == SQLITE_OK else { throw failure() }
    }
    private func bind(_ key: Key, to statement: OpaquePointer) throws {
        try bind(namespace, 1, statement)
        guard sqlite3_bind_text(statement, 2, key.kind, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
        try bind(key.pixels, 3, statement)
    }
    private func data(_ statement: OpaquePointer, column: Int32, limit: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, count <= limit, let pointer = sqlite3_column_blob(statement, column) else { throw Failure(detail: "Invalid payload size") }
        return Data(bytes: pointer, count: count)
    }
    func lookup<T: Decodable>(_ type: T.Type, key: Key) throws -> T? {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload,checksum FROM observations WHERE clip=? AND kind=? AND key=?")
        defer { sqlite3_finalize(statement) }; try bind(key, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            let payload = try data(statement, column: 0, limit: Self.payloadLimit)
            guard Self.digest(payload) == (try data(statement, column: 1, limit: 32)) else { throw Failure(detail: "Checksum mismatch") }
            do {
                let value = try PropertyListDecoder().decode(type, from: payload)
                hits[key.kind, default: 0] += 1
                return value
            } catch { throw Failure(detail: "Invalid saved observation: \(error.localizedDescription)") }
        default: throw failure()
        }
    }
    /// Return the authoritative committed value, including when another writer won.
    func store<T: Codable>(_ value: T, key: Key) throws -> T {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload: Data
        do { payload = try encoder.encode(value) } catch { throw Failure(detail: error.localizedDescription) }
        guard payload.count <= Self.payloadLimit else { throw Failure(detail: "Observation exceeds storage bound") }
        let inserted: Bool = try lock.withLock {
            let statement = try prepare("INSERT OR IGNORE INTO observations(clip,kind,key,payload,checksum) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(statement) }; try bind(key, to: statement)
            try bind(payload, 4, statement); try bind(Self.digest(payload), 5, statement)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            let inserted = sqlite3_changes(db) != 0
            if inserted { writes[key.kind, default: 0] += 1 }
            return inserted
        }
        if inserted { return value }
        guard let saved = try lookup(T.self, key: key) else { throw Failure(detail: "Committed observation disappeared") }
        return saved
    }
    func metrics() -> [String: Double] {
        lock.withLock {
            var result: [String: Double] = ["pose_disk_hits": Double(hits.values.reduce(0,+)), "pose_disk_writes": Double(writes.values.reduce(0,+))]
            for family in ["vision-r2", "vision-r1", "hand", "toe"] {
                result[family + "_disk_hits"] = Double(hits.filter { $0.key.hasPrefix(family) }.values.reduce(0,+))
                result[family + "_disk_writes"] = Double(writes.filter { $0.key.hasPrefix(family) }.values.reduce(0,+))
            }
            return result
        }
    }
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024*1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Exact BGRA content, geometry and attachments; row padding is not image content.
    /// Unsupported attachment types fail rather than admitting a speculative hit.
    static func key(pixels: CVPixelBuffer, kind: String) throws -> Key {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixels), (1...4096).contains(width), (1...4096).contains(height),
              CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { throw Failure(detail: "Unsupported pose input") }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        guard stride >= width*4, let base = CVPixelBufferGetBaseAddress(pixels) else { throw Failure(detail: "Missing pose pixels") }
        var hash = SHA256()
        hash.update(data: Data("bgra-up-v1|\(width)|\(height)|".utf8))
        for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
            let attachments = CVBufferCopyAttachments(pixels, mode) as? [String: Any] ?? [:]
            hash.update(data: try attachmentData(attachments))
        }
        for row in 0..<height { hash.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: row*stride), count: width*4)) }
        return Key(kind: kind, pixels: Data(hash.finalize()))
    }
    private static func attachmentData(_ value: Any) throws -> Data {
        func field(_ tag: String, _ bytes: Data) -> Data { Data((tag + String(bytes.count) + ":").utf8) + bytes }
        if let dictionary = value as? [String: Any] {
            var bytes = Data()
            for key in dictionary.keys.sorted() { bytes += field("k",Data(key.utf8)); bytes += try attachmentData(dictionary[key]!) }
            return field("d", bytes)
        }
        if let values = value as? [Any] { return field("a",try values.reduce(into: Data()) { $0 += try attachmentData($1) }) }
        if let string = value as? String { return field("s",Data(string.utf8)) }
        if let number = value as? NSNumber { return field("n",Data((String(cString:number.objCType)+":"+number.stringValue).utf8)) }
        if let data = value as? Data { return field("b",data) }
        if CFGetTypeID(value as CFTypeRef) == CGColorSpace.typeID {
            let space = value as! CGColorSpace
            if let data = space.copyICCData() { return field("c",data as Data) }
            if let name = space.name { return field("c-name",Data((name as String).utf8)) }
        }
        throw Failure(detail: "Unsupported image attachment")
    }
}
