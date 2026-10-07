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
    @StateObject private var sceneModel = StadiumPreviewModel()
    @State private var overlays = ExportOverlaySettings.load()
    @State private var edit = SessionEditState(style: .fire, intensity: 0.85)
    @Namespace private var exportZoom

    var body: some View {
        NavigationStack(path: $path) {
            ReplayEffectsView(
                summary: summary, edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                onSaveShare: { path.append(PostSessionRoute.share) }, onBack: onFinished,
                exportZoom: exportZoom
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .navigationDestination(for: PostSessionRoute.self) { route in
                switch route {
                case .effects:
                    ReplayEffectsView(
                        summary: summary,
                        edit: $edit, stadiumPreview: sceneModel, overlays: $overlays,
                        onSaveShare: { path.append(PostSessionRoute.share) },
                        onBack: { path.removeLast() },
                        exportZoom: exportZoom
                    )
                    .navigationBarBackButtonHidden(true)
                case .stats:
                    DetailedStatsView(
                        summary: summary,
                        onSaveShare: { path.append(PostSessionRoute.share) },
                        onBack: { path.removeLast() }
                    )
                    .navigationBarBackButtonHidden(true)
                case .share:
                    SaveShareView(
                        summary: summary,
                        edit: edit, sceneModel: sceneModel, overlays: $overlays,
                        onRecordAnother: onRecordAnother,
                        onDone: onFinished,
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
