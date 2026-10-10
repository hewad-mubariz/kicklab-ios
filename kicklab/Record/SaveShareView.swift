//
//  SaveShareView.swift
//  kicklab
//
//  Save to Photos + share. Original = raw take; Edited = ball style burned in.
//

import AVFoundation
import Photos
import SwiftUI
import UIKit

struct SaveShareView: View {
    let summary: SessionSummary
    let edit: SessionEditState
    @ObservedObject var sceneModel: StadiumPreviewModel
    @ObservedObject var preparation: SessionEffectsPreparation
    @Binding var overlays: ExportOverlaySettings
    var onRecordAnother: () -> Void
    var onDone: () -> Void
    var onBack: () -> Void

    private enum Version: String, CaseIterable, Identifiable {
        case original = "Original"
        case edited = "Edited"
        var id: String { rawValue }
    }

    private enum Quality: String, CaseIterable, Identifiable {
        case p720 = "720p"
        case p1080 = "1080p"
        var id: String { rawValue }
    }

    @State private var version: Version
    @State private var isResolving = false
    @State private var showOverlayEditor = false
    @State private var quality: Quality = .p1080
    @State private var thumb: UIImage?
    @State private var thumbnailTime: Double = 0
    @State private var sourceSize = CGSize(width: 9, height: 16)
    @State private var effectTrack = BallEffectTrack(frames: [])
    @State private var statusMessage: String?
    @State private var isSaving = false
    @State private var sharePayload: SharePayload?
    @StateObject private var burnIn = BallStyleBurnIn()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var loadingThumb = false
    /// Which button is carrying the export, so only that one turns into a progress bar.
    @State private var running: ExportAction?
    @State private var justSaved = false
    @State private var saves = 0

    private enum ExportAction { case save, share }

    init(summary: SessionSummary,
         edit: SessionEditState,
         sceneModel: StadiumPreviewModel,
         overlays: Binding<ExportOverlaySettings>,
         preparation: SessionEffectsPreparation? = nil,
         onRecordAnother: @escaping () -> Void,
         onDone: @escaping () -> Void,
         onBack: @escaping () -> Void) {
        self.summary = summary
        self.edit = edit
        self.sceneModel = sceneModel
        self.preparation = preparation ?? SessionEffectsPreparation()
        self._overlays = overlays
        self.onRecordAnother = onRecordAnother
        self.onDone = onDone
        self.onBack = onBack
        _version = State(initialValue: edit.isEdited ? .edited : .original)
    }

    var body: some View {
        ZStack {
            SessionBackdrop()
            VStack(spacing: 0) {
                SessionHeader(title: "Save & Share", onBack: onBack)
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        SessionSegments(options: Version.allCases, selection: $version) { $0.rawValue }
                            .disabled(busy)
                            .sessionEntrance(shown, offset: 10)
                        previewCard.sessionEntrance(shown, order: 1, offset: 14, scale: 0.97)
                        overlayControls.sessionEntrance(shown, order: 2, offset: 14)
                        qualityRow.disabled(busy).sessionEntrance(shown, order: 3, offset: 14)

                        if preparation.isPreparing {
                            ProgressView("Preparing ball effects…", value: preparation.progress)
                                .tint(SessionStyle.mint)
                        }
                        if sceneModel.isPreparing || sceneModel.isRendering {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(sceneModel.isPreparing ? "Preparing your cutout…" : "Rendering your environment…")
                                    .font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                                ProgressView(value: sceneModel.isPreparing ? sceneModel.progress : sceneModel.renderProgress).tint(SessionStyle.mint)
                            }
                            .transition(.sessionRise)
                        }

                        // The busy button becomes its own progress bar; the layout never shifts.
                        SessionAction(title: saveTitle, symbol: justSaved ? "checkmark.circle.fill" : "arrow.down.to.line",
                                      progress: running == .save ? exportProgress : nil) {
                            Task { await saveToDevice() }
                        }
                        .symbolEffect(.bounce, value: saves)
                        .disabled(busy)
                        .sessionEntrance(shown, order: 4, offset: 14)
                        SessionAction(title: running == .share ? progressTitle : "Share", symbol: "square.and.arrow.up", primary: false,
                                      progress: running == .share ? exportProgress : nil) {
                            Task { await shareClip() }
                        }
                        .disabled(busy)
                        .sessionEntrance(shown, order: 5, offset: 14)
                        socialRow.padding(.top, 4).disabled(busy)
                            .sessionEntrance(shown, order: 6, offset: 14)
                        if let statusMessage {
                            Text(statusMessage).font(.system(size: 12))
                                .foregroundStyle(SessionStyle.mint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.sessionRise)
                        }
                        HStack(spacing: 10) {
                            footerButton("Record Another Session", symbol: "arrow.counterclockwise", action: onRecordAnother)
                            footerButton("Done", action: onDone)
                                .frame(width: 88)
                        }
                        .padding(.top, 5)
                        .sessionEntrance(shown, order: 7, offset: 14)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal, SessionStyle.inset)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                    .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: statusMessage)
                    .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: sceneModel.isPreparing || sceneModel.isRendering)
                    .animation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion), value: overlays.counter.enabled)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { shown = true }
        .task(id: version) { await loadThumb() }
        .sensoryFeedback(.success, trigger: saves)
        .sheet(item: $sharePayload) { payload in ActivityView(items: [payload.url]) }
        .sheet(isPresented: $showOverlayEditor) {
            ExportOverlayEditor(preparation: preparation, summary: summary,
                edit: version == .edited ? edit : SessionEditState(style: .none, intensity: 0),
                sourceSize: sourceSize, sceneModel: sceneModel, settings: $overlays)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: overlays) { _, value in value.save() }
    }

    private var busy: Bool { isSaving || isResolving || burnIn.isExporting }

    /// Burn-in drives the bar; before it starts the bar holds a sliver, after it the bar stays full.
    private var exportProgress: Double {
        burnIn.isExporting ? max(0.03, burnIn.progress) : isResolving ? 0.03 : 1
    }

    private var progressTitle: String {
        burnIn.isExporting ? "Exporting \(Int((burnIn.progress * 100).rounded()))%" : isResolving ? "Preparing…" : "Saving…"
    }

    private var saveTitle: String {
        if justSaved { return "Saved to Photos" }
        return running == .save ? progressTitle : "Save to Device"
    }

    private func footerButton(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbol { Image(systemName: symbol).font(.system(size: 15)) }
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .modifier(SessionPanel(tint: .white.opacity(0.35)))
        }
        .buttonStyle(SessionPressStyle())
    }

    private var counterTimeline: ExportCounterTimeline {
        ExportCounterTimeline(touches: summary.touchesMarked, total: summary.touches)
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                let scale = min(geometry.size.width / sourceSize.width, geometry.size.height / sourceSize.height)
                let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
                ZStack(alignment: .topLeading) {
                    if let image = thumb?.cgImage {
                        // Switching Original/Edited softens the old frame until the new one lands.
                        ZStack(alignment: .topLeading) {
                            MetalStillSurface(image: image,
                                edit: previewEdit,
                                track: effectTrack, time: thumbnailTime) { statusMessage = $0 }
                            ExportOverlayLayer(settings: overlays, timeline: counterTimeline, time: thumbnailTime, size: size)
                        }
                        .blur(radius: loadingThumb ? 10 : 0)
                        .opacity(loadingThumb ? 0.55 : 1)
                        .scaleEffect(loadingThumb && !reduceMotion ? 0.97 : 1)
                        .overlay { if loadingThumb { ProgressView().tint(SessionStyle.mint).transition(.opacity) } }
                        .id(thumb)
                        .transition(.opacity)
                    } else {
                        Color.clear.overlay { ProgressView().tint(SessionStyle.mint) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(SessionMotion.animation(SessionMotion.settle, reduceMotion: reduceMotion), value: loadingThumb)
            }
            .frame(height: 330)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SessionStyle.rim, lineWidth: 0.7))
            HStack {
                Text("\(summary.touches) touches · \(summary.durationLabel)")
                Spacer()
                Text(version == .edited && edit.isEdited ? edit.label : "Original look")
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
        }
    }

    private var overlayControls: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $overlays.counter.enabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include counter").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text(counterTimeline.times.isEmpty ? "Show total touches on your video" : "Count along with every touch")
                        .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
                }
            }
            if overlays.hasVisibleOverlays {
                Group {
                Button { showOverlayEditor = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                        Text("Customize touch counter").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }.foregroundStyle(SessionStyle.mint).padding(.vertical, 8)
                }.disabled(thumb == nil)
                Text("Choose a style. Move, resize and rotate.")
                    .font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .transition(.sessionRise)
            }
        }
        .tint(SessionStyle.mint)
        .padding(14)
        .modifier(SessionPanel())
        .disabled(isSaving || isResolving || burnIn.isExporting)
    }

    private var qualityRow: some View {
        HStack {
            Text("Video Quality").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Spacer()
            Picker("Quality", selection: $quality) {
                ForEach(Quality.allCases) { value in Text(value.rawValue).tag(value) }
            }
            .pickerStyle(.menu).tint(.white)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .modifier(SessionPanel())
    }

    private var socialRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Share to").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            HStack(spacing: 18) {
                socialButton("camera", "Instagram")
                socialButton("music.note", "TikTok")
                socialButton("play.rectangle.fill", "YouTube")
                socialButton("ellipsis", "More") { Task { await shareClip() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func socialButton(_ icon: String, _ title: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action { action() }
            else { Task { await shareClip() } }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: title == "TikTok" ? .cyan : .clear, radius: 0, x: -1, y: -1)
                .shadow(color: title == "TikTok" ? .pink : .clear, radius: 0, x: 1, y: 1)
                .frame(width: 45, height: 42)
                .background {
                    if title == "Instagram" {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [.purple, .pink, .orange], startPoint: .topTrailing, endPoint: .bottomLeading))
                            .padding(7)
                    } else {
                        RoundedRectangle(cornerRadius: 12).fill(SessionStyle.panel)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SessionStyle.rim, lineWidth: 0.7))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SessionPressStyle(scale: 0.88))
        .accessibilityLabel(title)
    }

    private var previewEdit: SessionEditState {
        var value = version == .edited ? edit : SessionEditState(style: .none, intensity: 0)
        if loadingThumb || effectTrack.surfaceMotion == nil { value.ballSkin = .original }
        return value
    }

    private func loadThumb() async {
        loadingThumb = thumb != nil
        let media: ScenePlayback
        do {
            let ready = version == .edited && edit.ballSkin != .original
                ? try await preparation.prepare(summary) : summary
            media = try await sceneModel.media(summary: ready, selection: version == .edited ? edit.scene : nil)
            try Task.checkCancellation()
        } catch is CancellationError { return }
        catch {
            loadingThumb = false
            statusMessage = "Couldn’t load the video preview. \(error.localizedDescription)"; return
        }
        effectTrack = BallEffectTrack(frames: media.track, touchTimes: summary.touchesMarked.map(\.time))
        if version == .edited, edit.ballSkin != .original {
            do {
                effectTrack.surfaceMotion = try await BallSurfaceTimeline.prepare(source: summary.videoURL, track: BallEffectTrack(frames: (preparation.prepared ?? summary).renderTrack))
            } catch is CancellationError { return }
            catch { statusMessage = "Couldn’t prepare source spin. \(error.localizedDescription)" }
            guard !Task.isCancelled else { return }
        }
        let asset = AVURLAsset(url: media.url)
        let result = try? await EffectVideoGeometry.still(asset: asset, at: summary.duration * 0.35)
        guard !Task.isCancelled else { return }
        withAnimation(SessionMotion.fade) {
            if let result {
                thumb = UIImage(cgImage: result.image)
                thumbnailTime = CMTimeGetSeconds(result.actualTime)
                sourceSize = CGSize(width: result.image.width, height: result.image.height)
            }
            loadingThumb = false
        }
    }

    /// Resolves Original vs Edited file URL (burns style when needed).
    @MainActor
    private func resolveExportURL() async -> URL? {
        guard !isResolving, !burnIn.isExporting else { return nil }
        isResolving = true
        defer { isResolving = false }
        let edited = version == .edited && edit.isEdited
        let media: ScenePlayback
        do {
            let ready = edited && edit.ballSkin != .original ? try await preparation.prepare(summary) : summary
            if edited, let selection = edit.scene {
                media = try await sceneModel.media(summary: ready, selection: selection)
            } else {
                media = ScenePlayback(url: ready.videoURL, track: ready.renderTrack)
            }
        } catch { statusMessage = "Couldn’t prepare the export. \(error.localizedDescription)"; return nil }
        burnIn.export(source: media.url, track: media.track,
            style: edited ? edit.style : .none, intensity: edited ? edit.intensity : 0,
            skin: edited ? edit.ballSkin : .original, environment: edited ? edit.environment : .original, shortEdge: quality == .p1080 ? 1080 : 720,
            counter: counterTimeline, overlays: overlays,preserveFrameTimes:edited && edit.scene != nil)
        // Wait until burn-in finishes.
        while burnIn.isExporting {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        if burnIn.outputURL == nil { statusMessage = burnIn.status }
        return burnIn.outputURL
    }

    @MainActor
    private func saveToDevice() async {
        isSaving = true
        statusMessage = nil
        defer { isSaving = false; running = nil }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photos access needed to save."
            return
        }
        running = .save

        guard let url = await resolveExportURL() else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            let tag = version == .edited && edit.isEdited ? "Edited" : "Original"
            statusMessage = "Saved \(tag) to Photos (\(quality.rawValue))."
            celebrateSave()
        } catch {
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func shareClip() async {
        running = .share
        defer { running = nil }
        guard let url = await resolveExportURL() else { return }
        sharePayload = SharePayload(url: url)
    }

    /// A short confirmation on the button itself, then it returns to Save to Device.
    private func celebrateSave() {
        saves += 1
        justSaved = true
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            justSaved = false
        }
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
