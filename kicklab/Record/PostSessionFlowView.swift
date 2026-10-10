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

    @State private var path = NavigationPath()
    @StateObject private var ballPreparation = SessionEffectsPreparation()
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.85)
    @Namespace private var exportZoom

    private var activeSummary: SessionSummary { ballPreparation.prepared ?? summary }

    var body: some View {
        NavigationStack(path: $path) {
            ReplayEffectsView(
                summary: activeSummary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                onBack: { ballPreparation.cancel(); onFinished() },
                onRecordAnother: { ballPreparation.cancel(); onRecordAnother() },
                onDone: { ballPreparation.cancel(); onFinished() },
                preparation: ballPreparation
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
                        preparation: ballPreparation
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
        .onAppear { if recordsPersonalBest { JugglingRecords.recordIfNeeded(summary.touches) } }
    }
}
