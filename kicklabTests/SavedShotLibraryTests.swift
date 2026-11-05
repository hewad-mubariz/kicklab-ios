import XCTest
@testable import kicklab

@MainActor
final class SavedShotLibraryTests: XCTestCase {
    private var root: URL!
    private var library: SavedShotLibrary!
    private let owner = UUID()

    override func setUp() {
        root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        library = SavedShotLibrary(root: root.appendingPathComponent("Shots", isDirectory: true))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// A temporary copy, the way the camera and the photo picker hand a video over.
    private func temporaryVideo(_ extension: String = "mp4") throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/power-shot-2.5s.mp4")
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + `extension`)
        try FileManager.default.copyItem(at: fixture, to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        return copy
    }
    private func add(owner: UUID? = nil, source: SavedJugglingResult.Source = .recording, at date: Date = Date()) async throws -> SavedShot {
        try await library.add(video: try temporaryVideo(), id: UUID(), owner: owner, source: source, completedAt: date)
    }

    func testAddingMovesTheVideoInAndKeepsItsDetails() async throws {
        let video = try temporaryVideo()
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let shot = try await library.add(video: video, id: UUID(), owner: nil, source: .gallery, completedAt: date)

        XCTAssertFalse(FileManager.default.fileExists(atPath: video.path), "Leaving the editor must not be able to delete the only copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.videoURL(for: shot).path))
        XCTAssertEqual(library.videoURL(for: shot).pathExtension, "mp4")
        XCTAssertEqual(Double(shot.durationMS) / 1000, 2.5, accuracy: 0.2)
        XCTAssertEqual(shot.durationLabel, "0:03")
        XCTAssertEqual(try library.shots(owner: nil), [shot])
        XCTAssertEqual(try library.shots(owner: nil).first?.source, .gallery)
        XCTAssertEqual(try library.shots(owner: nil).first?.completedAt, date)
    }

    func testVideoIsLeftOutOfPhoneBackups() async throws {
        let shot = try await add()
        let values = try library.videoURL(for: shot).deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAFileThatIsNotAVideoIsRefusedAndNothingIsListed() async throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("not a video".utf8).write(to: junk)
        addTeardownBlock { try? FileManager.default.removeItem(at: junk) }
        do {
            _ = try await library.add(video: junk, id: UUID(), owner: nil, source: .gallery, completedAt: Date())
            XCTFail("Expected the file to be refused")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: junk.path), "The editor still has to report on this file")
        XCTAssertEqual(try library.shots(owner: nil), [])
    }

    func testNewestComesFirst() async throws {
        let older = try await add(at: Date(timeIntervalSinceReferenceDate: 100))
        let newer = try await add(at: Date(timeIntervalSinceReferenceDate: 200))
        XCTAssertEqual(try library.shots(owner: nil).map(\.id), [newer.id, older.id])
    }

    func testEachAccountSeesOnlyItsOwnShots() async throws {
        let guest = try await add()
        let mine = try await add(owner: owner)
        XCTAssertEqual(try library.shots(owner: nil).map(\.id), [guest.id])
        XCTAssertEqual(try library.shots(owner: owner).map(\.id), [mine.id])
        XCTAssertEqual(try library.shots(owner: UUID()), [])
    }

    func testAShotThatDidNotFinishSavingOrCannotBeReadHidesNothingElse() async throws {
        let shot = try await add()
        let folder = library.videoURL(for: shot).deletingLastPathComponent().deletingLastPathComponent()
        let unfinished = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unfinished, withIntermediateDirectories: true)
        try Data().write(to: unfinished.appendingPathComponent("video.mov"))
        let unreadable = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: unreadable.appendingPathComponent("shot.json"))
        XCTAssertEqual(try library.shots(owner: nil).map(\.id), [shot.id])
    }

    func testAShotWhoseVideoIsGoneIsNotListed() async throws {
        let shot = try await add()
        try FileManager.default.removeItem(at: library.videoURL(for: shot))
        XCTAssertEqual(try library.shots(owner: nil), [])
    }

    func testChoicesComeBackWhenTheShotIsReopened() async throws {
        let shot = try await add()
        XCTAssertNil(library.look(id: shot.id, owner: nil), "A new shot opens on the editor's defaults")

        var look = ShotReplayLook(style: .glowTrail)
        look.intensity = 0.4
        look.graphStyle = .comet
        look.showGraph = false
        var camera = ShotCameraTrack(strike: 0.9)
        camera.insert(ShotCameraMove.allCases[0], range: 0.5...1.5, duration: 2.5)
        look.camera = camera
        try library.saveLook(look, id: shot.id, owner: nil)

        XCTAssertEqual(library.look(id: shot.id, owner: nil), look)
    }

    func testEveryEffectAndGraphSurvivesSaving() async throws {
        let shot = try await add()
        for style in ShotTrailStyle.allCases {
            let look = ShotReplayLook(style: style)
            try library.saveLook(look, id: shot.id, owner: nil)
            XCTAssertEqual(library.look(id: shot.id, owner: nil)?.style, style)
        }
        for graph in ShotGraphStyle.allCases {
            var look = ShotReplayLook()
            look.graphStyle = graph
            try library.saveLook(look, id: shot.id, owner: nil)
            XCTAssertEqual(library.look(id: shot.id, owner: nil)?.graphStyle, graph)
        }
    }

    func testChoicesFromALaterVersionFallBackToTheDefaults() async throws {
        let shot = try await add()
        let file = library.trackURL(id: shot.id, owner: nil).deletingLastPathComponent().appendingPathComponent("look.json")
        try Data(#"{"style":"fromTheFuture","intensity":1,"graphStyle":"comet","showGraph":true,"camera":{"clips":[]}}"#.utf8).write(to: file)
        XCTAssertNil(library.look(id: shot.id, owner: nil))
    }

    func testChoicesForAShotThatWasNotSavedLeaveNothingBehind() {
        XCTAssertThrowsError(try library.saveLook(ShotReplayLook(), id: UUID(), owner: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.path))
    }

    func testRemovingAShotTakesItsWholeFolderAndNoOther() async throws {
        let kept = try await add()
        let removed = try await add()
        let folder = library.videoURL(for: removed).deletingLastPathComponent()
        try library.remove(id: removed.id, owner: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try library.shots(owner: nil).map(\.id), [kept.id])
        XCTAssertNoThrow(try library.remove(id: removed.id, owner: nil))
    }

    func testDeletingAnAccountRemovesItsShotsAndKeepsGuestOnes() async throws {
        let guest = try await add()
        _ = try await add(owner: owner)
        try library.removeAccount(owner)
        XCTAssertEqual(try library.shots(owner: owner), [])
        XCTAssertEqual(try library.shots(owner: nil).map(\.id), [guest.id])
    }

    func testNothingIsSavedForAnAccountBeingDeleted() async throws {
        AccountDataGuard.markDeleted(owner, root: root)
        let video = try temporaryVideo()
        do {
            _ = try await library.add(video: video, id: UUID(), owner: owner, source: .recording, completedAt: Date())
            XCTFail("Expected the save to be refused")
        } catch {}
        XCTAssertEqual(try library.shots(owner: owner), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }
}
