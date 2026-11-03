import SwiftUI

/// Reopens local originals without recording another result or changing the leaderboard.
struct HistoryReplayEditor: View {
    let item: HistorySession
    let source: URL
    @ObservedObject var store: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var analyzer = VideoAnalyzer()
    @State private var summary: SessionSummary?
    @State private var savedEdit: HistoryReplayEdit?
    @State private var error: String?
    @State private var rebuiltTiming = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let summary {
                PostSessionFlowView(summary: summary, onFinished: { dismiss() }, onRecordAnother: { dismiss() },
                    recordsPersonalBest: false, historySessionID: item.id, ownerID: item.ownerID,
                    notice: rebuiltTiming ? String(localized: "This older replay’s timing was rebuilt for editing. Your saved result is unchanged.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : nil,
                    savedEdit: savedEdit, offersRecordAnother: false)
            } else if let error {
                NavigationStack {
                    VStack(spacing: 18) {
                        HistoryReplayThumbnail(url: source)
                            .frame(width: 108, height: 144).clipShape(.rect(cornerRadius: 16))
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).accessibilityIdentifier("history-editor-error")
                        Button("Retry") { attempt += 1 }.appGlassButtonStyle()
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Your replay").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Cancel") { analyzer.cancel(); dismiss() }
                                .accessibilityIdentifier("history-editor-cancel")
                        }
                    }
                }
            } else {
                processingOverlay
            }
        }
        .task(id: attempt) { await open() }
        .onDisappear { analyzer.cancel() }
        .onChange(of: store.ownerID) { _, owner in
            if owner != item.ownerID { analyzer.cancel(); dismiss() }
        }
    }

    private var processingOverlay: some View {
        let finishedAnalysis = analyzer.status == "done"
        let progress = finishedAnalysis ? 0.95 : analyzer.isRunning ? 0.1 + analyzer.progress * 0.8 : 0.02
        let step = finishedAnalysis ? 3 : analyzer.isRunning ? (analyzer.progress < 0.85 ? 1 : 2) : 0
        let message = analyzer.isCooling
            ? String(localized: "Cooling down. Your video will continue automatically.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            : analyzer.isRunning && !analyzer.canContinueInBackground
                ? String(localized: "Keep Juggle Dude open. Processing resumes when you return.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
                : !analyzer.isRunning && !finishedAnalysis
                    ? String(localized: "Opening your replay…", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : nil
        return ProcessingOverlay(progress: progress, stepIndex: step,
            statusMessage: message, onCancel: { analyzer.cancel(); dismiss() },
            isPaused: analyzer.isCooling, videoInfo: analyzer.processingInfo)
            .preferredColorScheme(.dark)
    }

    private func open() async {
        guard summary == nil, store.ownerID == item.ownerID else { return }
        error = nil
        let library = store.library
        do {
            await store.waitForReplayAnalysis(id: item.id)
            let restored = try await Task.detached(priority: .userInitiated) {
                (try library.replayData(for: item), try library.replayEdit(for: item), try? library.replayAnalysis(for: item))
            }.value
            try Task.checkCancellation()
            guard store.ownerID == item.ownerID else { return }
            savedEdit = restored.1 ?? HistoryReplayEdit(edit: .init(style: .none, intensity: 0.8), overlays: .load())
            if let data = restored.0 {
                let base = data.summary(item: item, videoURL: source)
                summary = restored.2?.restoring(base) ?? base
                return
            }
            // Legacy entries need a source track once. The analyzer owns cancellation
            // and its usual cache; its count is never submitted as a new session.
            analyzer.analyse(url: source, visualOnly: item.touchTimesMS != nil)
            while analyzer.isRunning { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            guard store.ownerID == item.ownerID else { return }
            guard analyzer.status == "done" else { throw CocoaError(.fileReadUnknown) }
            let result = HistoryReplayData.rebuilt(item: item, videoURL: source, duration: analyzer.videoDuration,
                frames: analyzer.recordedTrack, detectedTouches: analyzer.recordedTouches)
            let compact = HistoryReplayData(summary: result)
            try await Task.detached(priority: .utility) { try library.saveReplayData(compact, for: item) }.value
            store.retainReplayAnalysis(result, id: item.id, owner: item.ownerID, prepared: false)
            try Task.checkCancellation()
            guard store.ownerID == item.ownerID else { return }
            rebuiltTiming = item.touchTimesMS == nil
            summary = result
        } catch is CancellationError {
            analyzer.cancel()
        } catch {
            #if DEBUG
            if SessionHistoryReview.requested {
                let details = "\(error)\n\(analyzer.status)\n\(analyzer.failureDiagnostic)"
                try? Data(details.utf8).write(to: URL.documentsDirectory.appendingPathComponent("history-editor-error.txt"), options: .atomic)
            }
            #endif
            self.error = String(localized: "This replay couldn’t be opened for editing. Try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}
