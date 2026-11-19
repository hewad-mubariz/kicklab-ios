import Foundation

/// Research gate shared with durable RF reuse; the normal editor remains unchanged.
/// PowerShot requests visual observations, never the juggling counter's decisions.
nonisolated enum ShotReplayReuse {
    static var enabled: Bool {
        #if DEBUG
        RFFramePredictionReuse.persistenceEnabled && ProcessInfo.processInfo.arguments.contains("--shot-reuse")
        #else
        false
        #endif
    }
    static var store: ShotReuseStore {
        ShotReuseStore(root: RFPredictionDiskStore.root.appendingPathComponent("PowerShot-v1", isDirectory: true))
    }
    private static func contract() throws -> String {
        guard let model = Bundle.main.url(forResource: BallDetector.configuredResourceName, withExtension: "mlmodelc") else {
            throw ShotReuseStore.Failure(detail: "Missing model identity")
        }
        return "powershot-visual-fullrate-v1|" + SessionAnalysisStore.visualPipelineSignature()
            + "|model=" + (try RFPredictionModelIdentity.digest(model))
            + "|device=" + RFDeviceProfile.hardwareIdentifier + "|ci-cpu=\(VideoWorkExecution.cpuOnly)"
    }
    static func frames(source: URL, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [RecordedFrame] {
        let task = VideoWorkExecution.detached {
            let digest = try SessionAnalysisStore.sourceDigest(source)
            let identity = try contract()
            if let data = try store.load(source: digest, contract: identity) {
                let values = try PropertyListDecoder().decode([StoredFrame].self, from: data)
                guard StoredFrame.validated(values) else { throw ShotReuseStore.Failure(detail: "Invalid visual track") }
                onProgress(1); return values.map(\.frame)
            }
            let frames = try await VideoAnalyzer.replayTrack(source: source, onProgress: onProgress)
            try Task.checkCancellation()
            // Save even a successful empty observation sequence. It is a completed search,
            // although the editor may still explain that it could not follow the ball.
            try store.save(SessionAnalysisStore.frameData(frames), source: digest, contract: identity)
            return frames
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
