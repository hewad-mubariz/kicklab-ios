//
//  PostSessionFlowView.swift
//  kicklab
//
//  Opens the stopped-session editor, then the existing save/share flow.
//

import SwiftUI

private enum PostSessionRoute: Hashable {
    case effects
    case stats
    case share
}

struct PostSessionFlowView: View {
    let summary: SessionSummary
    var onFinished: () -> Void
    var onRecordAnother: () -> Void
    var recordsPersonalBest = true
    var historySessionID: UUID? = nil
    var ownerID: UUID? = nil
    /// The editor's back button. Finishes by default.
    var onClose: (() -> Void)? = nil
    /// Shown once over the replay, e.g. when recording ended early.
    var notice: String? = nil
    var offersRecordAnother = true

    @EnvironmentObject private var player: PlayerStore
    @Environment(\.scenePhase) private var scenePhase

    @State private var path = NavigationPath()
    @StateObject private var ballPreparation = SessionEffectsPreparation()
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    /// New sessions start from My style when there is one.
    @State private var edit: SessionEditState
    @State private var draftRevision = 0

    init(summary: SessionSummary, onFinished: @escaping () -> Void, onRecordAnother: @escaping () -> Void,
         recordsPersonalBest: Bool = true, historySessionID: UUID? = nil, ownerID: UUID? = nil,
         onClose: (() -> Void)? = nil, notice: String? = nil,
         savedEdit: HistoryReplayEdit? = nil, offersRecordAnother: Bool = true) {
        self.summary = summary; self.onFinished = onFinished; self.onRecordAnother = onRecordAnother
        self.recordsPersonalBest = recordsPersonalBest; self.historySessionID = historySessionID
        self.ownerID = ownerID; self.onClose = onClose; self.notice = notice
        self.offersRecordAnother = offersRecordAnother
        _edit = State(initialValue: savedEdit?.edit ?? MyStyleStore.shared.startingEdit(touchCount: summary.touchesMarked.count))
        _overlays = State(initialValue: savedEdit?.overlays ?? ExportOverlaySettings.load())
    }
    @Namespace private var exportZoom

    private var activeSummary: SessionSummary {
        var value = ballPreparation.prepared ?? summary
        if let item = player.history.items.first(where: { $0.id == historySessionID && $0.ownerID == ownerID }) {
            value.historyReplay = HistoryReplayContext(item: item, library: player.history.library)
        }
        return value
    }
    private var draft: HistoryReplayEdit { HistoryReplayEdit(edit: edit, overlays: overlays) }

    var body: some View {
        NavigationStack(path: $path) {
            ReplayEffectsView(
                summary: activeSummary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                onBack: { ballPreparation.cancel(); (onClose ?? onFinished)() },
                onRecordAnother: offersRecordAnother ? { ballPreparation.cancel(); onRecordAnother() } : nil,
                onDone: { ballPreparation.cancel(); onFinished() },
                preparation: ballPreparation, historySessionID: historySessionID,
                closeLabel: onClose == nil ? "Close editor" : "Back to camera", notice: notice
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: PostSessionRoute.self) { route in
                switch route {
                case .effects:
                    ReplayEffectsView(
                        summary: activeSummary,
                        edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                        onBack: { path.removeLast() },
                        onRecordAnother: offersRecordAnother ? { ballPreparation.cancel(); onRecordAnother() } : nil,
                        onDone: { ballPreparation.cancel(); onFinished() },
                        preparation: ballPreparation, historySessionID: historySessionID
                    )
                    .navigationBarBackButtonHidden(true)
                case .stats:
                    DetailedStatsView(
                        summary: activeSummary,
                        onSaveShare: { path.append(PostSessionRoute.share) },
                        onBack: { path.removeLast() }
                    )
                    .navigationBarBackButtonHidden(true)
                case .share:
                    SaveShareView(
                        summary: activeSummary,
                        edit: edit, sceneModel: sceneModel, overlays: $overlays, preparation: ballPreparation,
                        onRecordAnother: { ballPreparation.cancel(); onRecordAnother() },
                        onDone: { ballPreparation.cancel(); onFinished() },
                        onBack: { path.removeLast() }
                    )
                    .navigationBarBackButtonHidden(true)
                    // Save & Share grows out of the Export pill and shrinks back into it.
                    .navigationTransition(.zoom(sourceID: SessionMotion.exportZoomID, in: exportZoom))
                }
            }
        }
        .onAppear {
            if recordsPersonalBest, let streak = summary.bestStreak { JugglingRecords.recordIfNeeded(streak.count, ownerID: ownerID) }
        }
        .onChange(of: draft) { _, _ in draftRevision += 1 }
        .onReceive(ballPreparation.$prepared) { ready in
            if let ready, let historySessionID {
                player.history.retainReplayAnalysis(ready, id: historySessionID, owner: ownerID, prepared: true)
            }
        }
        .task(id: draftRevision) {
            do { try await Task.sleep(for: .milliseconds(250)); saveDraft() }
            catch { }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveDraft() } }
        .onDisappear { saveDraft() }
    }

    private func saveDraft() {
        guard let historySessionID else { return }
        player.history.saveReplayEdit(draft, id: historySessionID, owner: ownerID)
    }
}
