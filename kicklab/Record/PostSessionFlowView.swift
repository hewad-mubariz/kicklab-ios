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

    @State private var path = NavigationPath()
    @StateObject private var ballPreparation = SessionEffectsPreparation()
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    /// New sessions start from My style when there is one.
    @State private var edit: SessionEditState

    init(summary: SessionSummary, onFinished: @escaping () -> Void, onRecordAnother: @escaping () -> Void,
         recordsPersonalBest: Bool = true, historySessionID: UUID? = nil, ownerID: UUID? = nil,
         onClose: (() -> Void)? = nil, notice: String? = nil) {
        self.summary = summary; self.onFinished = onFinished; self.onRecordAnother = onRecordAnother
        self.recordsPersonalBest = recordsPersonalBest; self.historySessionID = historySessionID
        self.ownerID = ownerID; self.onClose = onClose; self.notice = notice
        _edit = State(initialValue: MyStyleStore.shared.startingEdit(touchCount: summary.touchesMarked.count))
    }
    @Namespace private var exportZoom

    private var activeSummary: SessionSummary { ballPreparation.prepared ?? summary }

    var body: some View {
        NavigationStack(path: $path) {
            ReplayEffectsView(
                summary: activeSummary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                onBack: { ballPreparation.cancel(); (onClose ?? onFinished)() },
                onRecordAnother: { ballPreparation.cancel(); onRecordAnother() },
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
                        onRecordAnother: { ballPreparation.cancel(); onRecordAnother() },
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
            if recordsPersonalBest { JugglingRecords.recordIfNeeded(summary.touches, ownerID: ownerID) }
        }
    }
}
