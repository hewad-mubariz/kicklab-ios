import CoreGraphics
import CryptoKit
import Foundation
import SQLite3

/// Durable stateless observations only. A completed insert is committed before returning.
/// This database is separate from counter rules, effect selection and completed analyses.
nonisolated final class RFPredictionDiskStore: @unchecked Sendable {
    static let root = URL.applicationSupportDirectory.appendingPathComponent("JuggleDudeResults/Predictions-v1", isDirectory: true)
    private let lock = NSLock()
    private var database: OpaquePointer?
    private let namespace: String
    private(set) var reads = 0
    private(set) var writes = 0
    static let payloadLimit = 1024 * 1024

    struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "Could not save or read reusable video analysis. \(detail)" }
    }

    init(root: URL = root, source: String, runtime: String, byteLimit: Int = 2 * 1024 * 1024 * 1024) throws {
        namespace = Self.digest(Data((source + "|" + runtime + "|rf-decoder-v1").utf8)).hex
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let path = root.appendingPathComponent("predictions.sqlite3").path
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close(database); database = nil
            throw Failure(detail: detail)
        }
        do {
            sqlite3_busy_timeout(database, 5000)
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("PRAGMA wal_autocheckpoint=256")
            try execute("PRAGMA journal_size_limit=4194304")
            let pageSize = try scalar("PRAGMA page_size")
            try execute("PRAGMA max_page_count=\(max(16, byteLimit / pageSize))")
            try execute("CREATE TABLE IF NOT EXISTS predictions (clip TEXT NOT NULL, key BLOB NOT NULL, payload BLOB NOT NULL, checksum BLOB NOT NULL, PRIMARY KEY (clip,key)) WITHOUT ROWID")
        } catch { sqlite3_close(database); database = nil; throw error }
    }

    deinit { sqlite3_close(database) }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> Failure { Failure(detail: String(cString: sqlite3_errmsg(database))) }
    private func scalar(_ sql: String) throws -> Int {
        let stmt = try prepare(sql); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(stmt, 0))
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }
    private func bind(_ data: Data, _ index: Int32, _ statement: OpaquePointer) throws {
        let status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard status == SQLITE_OK else { throw failure() }
    }
    private func bindIdentity(_ key: RFFramePredictionCache.Key, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, 1, namespace, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { throw failure() }
        try bind(Self.keyDigest(key), 2, statement)
    }
    private func blob(_ statement: OpaquePointer, _ column: Int32, max: Int) throws -> Data {
        let size = Int(sqlite3_column_bytes(statement, column))
        guard size > 0, size <= max, let pointer = sqlite3_column_blob(statement, column) else {
            throw Failure(detail: "Invalid saved prediction size")
        }
        return Data(bytes: pointer, count: size)
    }

    func lookup(_ key: RFFramePredictionCache.Key) throws -> FrameDetections? {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare("SELECT payload,checksum FROM predictions WHERE clip=? AND key=?")
        defer { sqlite3_finalize(stmt) }
        try bindIdentity(key, to: stmt)
        switch sqlite3_step(stmt) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            let data = try blob(stmt, 0, max: Self.payloadLimit)
            guard Self.digest(data) == (try blob(stmt, 1, max: 32)) else { throw Failure(detail: "Saved prediction checksum mismatch") }
            let result = try Payload.decode(data)
            reads += 1
            return result
        default: throw failure()
        }
    }

    @discardableResult
    func store(_ value: FrameDetections, for key: RFFramePredictionCache.Key) throws -> Bool {
        let payload = try Payload.encode(value)
        guard payload.count <= Self.payloadLimit else { throw Failure(detail: "Prediction exceeds storage bound") }
        lock.lock(); defer { lock.unlock() }
        // Never overwrite a previously committed result for an exact key.
        let stmt = try prepare("INSERT OR IGNORE INTO predictions (clip,key,payload,checksum) VALUES (?,?,?,?)")
        defer { sqlite3_finalize(stmt) }
        try bindIdentity(key, to: stmt)
        try bind(payload, 3, stmt); try bind(Self.digest(payload), 4, stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        let inserted = sqlite3_changes(database) != 0
        writes += inserted ? 1 : 0
        return inserted
    }

    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func keyDigest(_ key: RFFramePredictionCache.Key) -> Data {
        var data = key.input.digest
        func number(_ n: UInt64) { var v = n.bigEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        number(UInt64(key.input.edge)); number(UInt64(key.input.width)); number(UInt64(key.input.height))
        number(UInt64(key.model.utf8.count)); data.append(contentsOf: key.model.utf8)
        number(key.cpuOnly ? 1 : 0); number(key.threshold.bitPattern)
        return digest(data)
    }

    /// Binary plist doubles preserve coordinates exactly. Alpha runs are lossless and bounded.
    private struct Payload: Codable {
        let ball: [Double]?
        let person: [Double]?
        let people: [[Double]]
        let usesMasks: Bool
        let mask: Mask?
        struct Mask: Codable {
            let rect: [Double]
            let width: Int, height: Int
            let sampling: [Double]?
            let bytes: Data
            let packed: Bool
            init(_ mask: BallMask) throws {
                rect = [mask.rect.origin.x, mask.rect.origin.y, mask.rect.width, mask.rect.height]
                width = mask.width; height = mask.height
                sampling = mask.decoderPixelSize.map { [$0.width, $0.height] }
                guard (1...128).contains(width), (1...128).contains(height) else { throw Failure(detail: "Invalid mask dimensions") }
                let raw = mask.alpha
                guard raw.count == width*height else { throw Failure(detail: "Invalid mask payload") }
                var runs = Data(), i = 0
                while i < raw.count {
                    let start = i, value = raw[i]
                    repeat { i += 1 } while i < raw.count && raw[i] == value && i-start < 65535
                    runs.append(value); runs.append(UInt8((i-start)&255)); runs.append(UInt8((i-start)>>8))
                }
                packed = runs.count < raw.count; bytes = packed ? runs : Data(raw)
            }
            func restored() throws -> BallMask {
                guard rect.count == 4, rect.allSatisfy(\.isFinite), rect[2] > 0, rect[3] > 0,
                      (1...128).contains(width), (1...128).contains(height),
                      sampling == nil || (sampling!.count == 2 && sampling!.allSatisfy({ $0.isFinite && $0 > 0 })) else { throw Failure(detail: "Invalid stored mask geometry") }
                var alpha: [UInt8] = []
                if packed {
                    guard bytes.count % 3 == 0, bytes.count <= width*height*3 else { throw Failure(detail: "Invalid stored mask runs") }
                    let raw = Array(bytes)
                    for i in stride(from: 0, to: raw.count, by: 3) {
                        let count = Int(raw[i+1]) | Int(raw[i+2]) << 8
                        guard count > 0, count <= width*height-alpha.count else { throw Failure(detail: "Invalid stored mask run length") }
                        alpha.append(contentsOf: repeatElement(raw[i], count: count))
                    }
                } else { alpha = Array(bytes) }
                guard alpha.count == width*height else { throw Failure(detail: "Incomplete stored mask") }
                return BallMask(rect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]), width: width, height: height,
                    alpha: alpha, decoderPixelSize: sampling.map { CGSize(width: $0[0], height: $0[1]) }).compacted()
            }
        }
        static func values(_ d: Detection?) -> [Double]? { d.map { [$0.score,$0.x,$0.y,$0.width,$0.height] } }
        static func detection(_ values: [Double]?) throws -> Detection? {
            guard let v = values else { return nil }
            guard v.count == 5, v.allSatisfy(\.isFinite), (0...1).contains(v[0]), v[3] > 0, v[4] > 0 else { throw Failure(detail: "Invalid stored detection") }
            return Detection(score: v[0], x: v[1], y: v[2], width: v[3], height: v[4])
        }
        static func encode(_ value: FrameDetections) throws -> Data {
            let p = Payload(ball: values(value.ball), person: values(value.person), people: value.people.map { values($0)! },
                usesMasks: value.usesBallMasks, mask: try value.ballMask.map(Mask.init))
            _ = try p.restored()
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            return try encoder.encode(p)
        }
        static func decode(_ data: Data) throws -> FrameDetections { try PropertyListDecoder().decode(Self.self, from: data).restored() }
        func restored() throws -> FrameDetections {
            guard people.count <= 8, usesMasks || mask == nil else { throw Failure(detail: "Invalid observation contract") }
            return FrameDetections(ball: try Self.detection(ball), person: try Self.detection(person),
                people: try people.map { try Self.detection($0)! }, ballMask: try mask?.restored(), usesBallMasks: usesMasks)
        }
    }
}

private extension Data { nonisolated var hex: String { map { String(format: "%02x", $0) }.joined() } }

/// Fingerprint the actual compiled resource once per process, independently of app/counter builds.
nonisolated enum RFPredictionModelIdentity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [URL: String] = [:]
    static func digest(_ directory: URL) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let value = values[directory] { return value }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw RFPredictionDiskStore.Failure(detail: "Cannot identify model")
        }
        let files = try enumerator.compactMap { $0 as? URL }.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw RFPredictionDiskStore.Failure(detail: "Empty model resource") }
        var hash = SHA256()
        for file in files {
            hash.update(data: Data(file.path.dropFirst(directory.path.count).utf8)); hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                try Task.checkCancellation()
                guard let data = try handle.read(upToCount: 1024*1024), !data.isEmpty else { return false }
                hash.update(data: data); return true
            }) {}
        }
        let result = Data(hash.finalize()).hex; values[directory] = result
        return result
    }
}
