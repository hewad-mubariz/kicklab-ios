import Foundation
import Testing
@testable import kicklab

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0

    func enter() async {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation = $0 }
        }
    }

    func release() { continuation?.resume(); continuation = nil }
    var isWaiting: Bool { continuation != nil }
}

@MainActor
struct ScenePreparationTests {
    private func preview() throws -> PreparedStadiumPreview {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("preparation-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("movie.mp4")
        return PreparedStadiumPreview(folder: folder, original: file, locked: file, moving: file,
            duration: 1, sourceDuration: 1, frames: 30, size: .init(width: 64, height: 128))
    }

    private func summary(_ prepared: PreparedStadiumPreview) -> SessionSummary {
        .make(touches: 0, duration: 1, bestCombo: 0, personalBest: 0,
            videoURL: prepared.original, touchesMarked: [], track: [])
    }

    private func waitForWorker(_ gate: PreparationGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.isWaiting) {
            try #require(ContinuousClock.now < deadline, "Preparation worker never started")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func closingTheSheetKeepsPreparationAndReusesItsResult() async throws {
        let prepared = try preview(), gate = PreparationGate()
        defer { prepared.removeFiles() }
        let model = StadiumPreviewModel { _, _, progress, stage in
            await stage("Finding the player")
            await progress(0.07)
            await gate.enter()
            try Task.checkCancellation()
            return prepared
        }
        let session = summary(prepared)
        let presentation = Task { await model.prepare(summary: session) }
        try await waitForWorker(gate)
        #expect(model.preparationStage == "Finding the player")
        #expect(model.progress == 0.07)
        presentation.cancel() // SwiftUI cancels .task when its sheet disappears.
        await model.prepare(summary: session) // Reopen while work is in flight.
        #expect(await gate.calls == 1)
        await gate.release()
        await presentation.value
        #expect(model.result != nil)
        #expect(!model.isPreparing)
        #expect(model.error == nil)
        await model.prepare(summary: session) // Choosing another environment reuses the cutout.
        #expect(await gate.calls == 1)
    }

    @Test func explicitCancelDoesNotAllowOverlappingNativeWorkOrPublishLateSuccess() async throws {
        let prepared = try preview(), gate = PreparationGate()
        defer { prepared.removeFiles() }
        let model = StadiumPreviewModel { _, _, progress, _ in
            await gate.enter()
            // Model native calls that return before observing cancellation.
            await progress(0.9)
            return prepared
        }
        let session = summary(prepared)
        let run = Task { await model.prepare(summary: session) }
        try await waitForWorker(gate)
        model.cancelPreparation()
        await model.prepare(summary: session)
        #expect(model.isPreparing)
        #expect(await gate.calls == 1)
        await gate.release()
        await run.value
        #expect(model.result == nil)
        #expect(!model.isPreparing)
        #expect(model.progress == 0)
        #expect(model.error?.contains("cancelled") == true)
        #expect(!FileManager.default.fileExists(atPath: prepared.folder.path))
    }

    @Test func preparationFailureShowsItsStageAndCanBeRetried() async throws {
        let prepared = try preview(), gate = PreparationGate()
        defer { prepared.removeFiles() }
        let model = StadiumPreviewModel { _, _, _, stage in
            await stage("Loading player cutout model")
            await gate.enter()
            if await gate.calls == 1 { throw StadiumPreviewPreparer.failure("Model unavailable") }
            return prepared
        }
        let session = summary(prepared)
        let run = Task { await model.prepare(summary: session) }
        try await waitForWorker(gate)
        await gate.release()
        await run.value
        #expect(!model.isPreparing)
        #expect(model.error == "Loading player cutout model: Model unavailable")
        await model.prepare(summary: session)
        #expect(model.error == nil)
        #expect(model.result != nil)
        #expect(await gate.calls == 2)
    }
}
