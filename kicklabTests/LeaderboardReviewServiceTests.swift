import XCTest
@testable import kicklab

@MainActor final class LeaderboardReviewServiceTests: XCTestCase {
    private let owner = UUID(), sessionID = UUID(), attemptID = UUID()
    private var session: URLSession!
    private var config: AccountConfiguration!
    override func setUpWithError() throws {
        config = try AccountConfiguration(values: ["SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "sb_publishable_test", "AUTH_REDIRECT_URL": "juggledude://auth/callback"])
        let options = URLSessionConfiguration.ephemeral
        options.protocolClasses = [ReviewURLProtocol.self]
        session = URLSession(configuration: options)
        ReviewURLProtocol.requests = []
    }
    override func tearDown() { session.invalidateAndCancel(); ReviewURLProtocol.handler = nil }

    private func attemptData(user: UUID? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": attemptID.uuidString,
            "user_id": (user ?? owner).uuidString, "session_id": sessionID.uuidString, "status": "uploading",
            "proposed_count": 3, "proposed_start_ms": 0, "proposed_end_ms": 3000, "duration_ms": 4000,
            "video_bytes": 12, "video_sha256": String(repeating: "a", count: 64),
            "object_path": "\(owner.uuidString.lowercased())/\(attemptID.uuidString.lowercased()).mov",
            "created_at": "2026-10-18T10:00:00.123456+00:00"])
    }

    func testSubmissionRPCRequestsOneObjectAndChecksOwnerReceipt() async throws {
        let data = try attemptData()
        ReviewURLProtocol.handler = { _ in (200, [:], data) }
        let api = SupabaseLeaderboardReviewService(config: config, session: session) { _ in "user-test-token" }
        let item = HistorySession(id: sessionID, ownerID: owner, touches: 100, durationMS: 4000,
            source: .recording, completedAt: Date(), syncState: .synced)
        let result = try await api.begin(item: item, proposal: .init(count: 3,startMS: 0,endMS: 3000), bytes: 12, sha256: String(repeating: "a", count: 64))
        XCTAssertEqual(result.proposedCount, 3)
        let request = try XCTUnwrap(ReviewURLProtocol.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.pgrst.object+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer user-test-token")
        let other = try attemptData(user: UUID())
        ReviewURLProtocol.handler = { _ in (200, [:], other) }
        do { _ = try await api.finish(id: attemptID, owner: owner); XCTFail("Accepted another account's receipt") }
        catch { XCTAssertTrue(error is LeaderboardFailure) }
    }

    func testResumeUsesServerOffsetAfterLostChunkResponse() async throws {
        let attempt = try SupabaseLeaderboardReviewService.decoder().decode(LeaderboardAttempt.self, from: attemptData())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.mov"), checkpoint = root.appendingPathComponent("upload.tus")
        try Data(repeating: 1, count: 12).write(to: file)
        let uploadURL = try XCTUnwrap(URL(string: "https://example.storage.supabase.co/storage/v1/upload/resumable/test"))
        try JSONEncoder().encode(uploadURL).write(to: checkpoint)
        ReviewURLProtocol.handler = { request in
            if request.httpMethod == "HEAD" { return (200, ["Upload-Offset": "6"], Data()) }
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Upload-Offset"), "6")
            return (204, ["Upload-Offset": "12"], Data())
        }
        let uploader = LeaderboardVideoUpload(config: config, session: session) { _ in "user-test-token" }
        var progress = 0.0
        try await uploader.run(file: file, attempt: attempt, checkpoint: checkpoint, accountRoot: root) { progress = $0 }
        XCTAssertEqual(progress, 1)
        XCTAssertEqual(ReviewURLProtocol.requests.map(\.httpMethod), ["HEAD", "PATCH"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpoint.path), "Keep recovery information until finalization succeeds")
    }

    func testExplicitSubmissionIncludesPrivateMomentsButOldRecordingsStillWork() async throws {
        let data = try attemptData()
        ReviewURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "begin_leaderboard_attempt_with_review")
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let size = stream.read(&buffer, maxLength: buffer.count)
                    if size <= 0 { break }; body.append(contentsOf: buffer.prefix(size))
                }
            }
            let fields = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let report = fields?["p_touch_review"] as? [String: Any]
            XCTAssertEqual(report?["version"] as? Int, 1)
            XCTAssertEqual((report?["moments"] as? [[String: Any]])?.first?["kind"] as? String, "handsUncertain")
            return (200, [:], data)
        }
        let api = SupabaseLeaderboardReviewService(config: config, session: session) { _ in "user-test-token" }
        var item = HistorySession(id: sessionID, ownerID: owner, touches: 3, durationMS: 4000,
            source: .recording, completedAt: Date(), syncState: .synced)
        var evidence = TouchReviewEvidence()
        evidence.append(.init(frameIndex: 30, time: 1, rejection: .disallowedBodyContact,
            handConfirmed: false, bodyFailure: .handsUncertain, ball: nil))
        item.touchReview = LeaderboardTouchReview.make(evidence: evidence, touchTimes: [0.5,1.5,2.5], duration: 4)
        _ = try await api.begin(item: item, proposal: .init(count: 3, startMS: 0, endMS: 3000),
            bytes: 12, sha256: String(repeating: "a", count: 64))
    }
}

private final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String:String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, headers, data) = Self.handler?(request) ?? (500, [:], Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
            httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
