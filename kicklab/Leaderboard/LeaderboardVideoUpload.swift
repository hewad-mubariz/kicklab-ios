import Foundation

@MainActor final class LeaderboardVideoUpload {
    let config: AccountConfiguration
    let session: URLSession
    let token: (UUID) async throws -> String
    init(config: AccountConfiguration, session: URLSession, token: @escaping (UUID) async throws -> String) {
        self.config = config; self.session = session; self.token = token
    }
    private var endpoint: URL {
        var parts = URLComponents(url: config.projectURL, resolvingAgainstBaseURL: false)!
        if let host = parts.host, host.hasSuffix(".supabase.co"), !host.hasSuffix(".storage.supabase.co") {
            parts.host = host.replacingOccurrences(of: ".supabase.co", with: ".storage.supabase.co")
        }
        parts.path = "/storage/v1/upload/resumable"
        return parts.url!
    }
    private func accepts(_ url: URL) -> Bool {
        url.scheme == "https" && [endpoint.host, config.projectURL.host].contains(url.host)
            && url.port == nil && url.user == nil && url.password == nil
            && url.path.hasPrefix("/storage/v1/upload/resumable/")
    }
    private func call(_ url: URL, method: String, owner: UUID, headers: [String: String] = [:], data: Data? = nil) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 120
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await token(owner))", forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let response: URLResponse
        if let data { (_, response) = try await session.upload(for: request, from: data) }
        else { (_, response) = try await session.data(for: request) }
        guard let http = response as? HTTPURLResponse else { throw LeaderboardFailure.upload }
        if [401,403].contains(http.statusCode) { throw LeaderboardFailure.signIn }
        // Storage refuses bytes over the project's upload limit. That is final, not a lost connection.
        if http.statusCode == 413 { throw LeaderboardFailure.tooLarge }
        return http
    }
    func run(file: URL, attempt: LeaderboardAttempt, checkpoint: URL, accountRoot: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        var uploadURL: URL?
        if let data = try? Data(contentsOf: checkpoint), let saved = try? JSONDecoder().decode(URL.self, from: data), accepts(saved) { uploadURL = saved }
        var offset: Int64 = 0
        if let saved = uploadURL {
            let response = try await call(saved, method: "HEAD", owner: attempt.userID)
            if [404,410].contains(response.statusCode) { uploadURL = nil }
            else {
                guard response.statusCode == 200 || response.statusCode == 204,
                      let value = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init) else { throw LeaderboardFailure.upload }
                offset = value
            }
        }
        if uploadURL == nil {
            let values = ["bucketName": "leaderboard-originals", "objectName": attempt.objectPath,
                          "contentType": "video/quicktime", "cacheControl": "0"]
            let metadata = values.sorted { $0.key < $1.key }.map { $0.key + " " + Data($0.value.utf8).base64EncodedString() }.joined(separator: ",")
            let response = try await call(endpoint, method: "POST", owner: attempt.userID,
                headers: ["Upload-Length": String(attempt.videoBytes), "Upload-Metadata": metadata])
            guard response.statusCode == 201, let location = response.value(forHTTPHeaderField: "Location"),
                  let url = URL(string: location, relativeTo: endpoint)?.absoluteURL, accepts(url) else { throw LeaderboardFailure.upload }
            uploadURL = url
            try Task.checkCancellation()
            try AccountDataGuard.write(owner: attempt.userID, root: accountRoot) {
                try FileManager.default.createDirectory(at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(url).write(to: checkpoint, options: [.atomic, .completeFileProtection])
            }
        }
        guard let uploadURL, offset >= 0, offset <= attempt.videoBytes else { throw LeaderboardFailure.upload }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        while offset < attempt.videoBytes {
            try Task.checkCancellation()
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: Int(min(6*1024*1024, attempt.videoBytes-offset))), !data.isEmpty else { throw LeaderboardFailure.changedVideo }
            let response = try await call(uploadURL, method: "PATCH", owner: attempt.userID,
                headers: ["Upload-Offset": String(offset), "Content-Type": "application/offset+octet-stream"], data: data)
            guard response.statusCode == 204,
                  let next = response.value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init),
                  next == offset + Int64(data.count) else { throw LeaderboardFailure.upload }
            offset = next; progress(Double(offset)/Double(attempt.videoBytes))
        }
        // Retain the checkpoint until finish succeeds; a lost completion response
        // can then be retried without uploading the original again.
    }
}
