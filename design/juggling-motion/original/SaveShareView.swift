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

    init(summary: SessionSummary,
         edit: SessionEditState,
         sceneModel: StadiumPreviewModel,
         overlays: Binding<ExportOverlaySettings>,
         onRecordAnother: @escaping () -> Void,
         onDone: @escaping () -> Void,
         onBack: @escaping () -> Void) {
        self.summary = summary
        self.edit = edit
        self.sceneModel = sceneModel
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
                            .disabled(isSaving || isResolving || burnIn.isExporting)
                        previewCard
                        overlayControls
                        qualityRow.disabled(isSaving || isResolving || burnIn.isExporting)

                        if sceneModel.isPreparing || sceneModel.isRendering {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(sceneModel.isPreparing ? "Preparing your cutout…" : "Rendering your environment…")
                                    .font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                                ProgressView(value: sceneModel.isPreparing ? sceneModel.progress : sceneModel.renderProgress).tint(SessionStyle.mint)
                            }
                        }
                        if burnIn.isExporting {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(burnIn.status).font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                                ProgressView(value: burnIn.progress).tint(SessionStyle.mint)
                            }
                        }

                        SessionAction(title: isSaving ? "Saving…" : "Save to Device", symbol: "arrow.down.to.line") {
                            Task { await saveToDevice() }
                        }
                        .disabled(isSaving || isResolving || burnIn.isExporting)
                        SessionAction(title: "Share", symbol: "square.and.arrow.up", primary: false) {
                            Task { await shareClip() }
                        }
                        .disabled(isSaving || isResolving || burnIn.isExporting)
                        socialRow.padding(.top, 4).disabled(isSaving || isResolving || burnIn.isExporting)
                        if let statusMessage {
                            Text(statusMessage).font(.system(size: 12))
                                .foregroundStyle(SessionStyle.mint)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 10) {
                            footerButton("Record Another Session", symbol: "arrow.counterclockwise", action: onRecordAnother)
                            footerButton("Done", action: onDone)
                                .frame(width: 88)
                        }
                        .padding(.top, 5)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal, SessionStyle.inset)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: version) { await loadThumb() }
        .sheet(item: $sharePayload) { payload in ActivityView(items: [payload.url]) }
        .sheet(isPresented: $showOverlayEditor) {
            ExportOverlayEditor(summary: summary,
                edit: version == .edited ? edit : SessionEditState(style: .none, intensity: 0),
                sourceSize: sourceSize, sceneModel: sceneModel, settings: $overlays)
                .presentationDragIndicator(.visible)
        }
        .onChange(of: overlays) { _, value in value.save() }
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
        .buttonStyle(HomePressStyle())
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
                        MetalStillSurface(image: image,
                            edit: version == .edited ? edit : SessionEditState(style: .none, intensity: 0),
                            track: effectTrack, time: thumbnailTime) { statusMessage = $0 }
                        ExportOverlayLayer(settings: overlays, timeline: counterTimeline, time: thumbnailTime, size: size)
                    } else {
                        Color.clear.overlay { ProgressView().tint(SessionStyle.mint) }
                    }
                }
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 330)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(SessionStyle.rim, lineWidth: 0.7))
            HStack {
                Text("\(summary.touches) touches · \(summary.durationLabel)")
                Spacer()
                Text(version == .edited && edit.isEdited ? edit.label : "Original look")
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
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(title)
    }

    private func loadThumb() async {
        thumb = nil
        let media: ScenePlayback
        do {
            media = try await sceneModel.media(summary: summary, selection: version == .edited ? edit.scene : nil)
            try Task.checkCancellation()
        } catch is CancellationError { return }
        catch { statusMessage = "Couldn’t load the video preview. \(error.localizedDescription)"; return }
        effectTrack = BallEffectTrack(frames: media.track)
        let asset = AVURLAsset(url: media.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: summary.duration * 0.35, preferredTimescale: 600)
        if let result = try? await gen.image(at: time) {
            guard !Task.isCancelled else { return }
            thumb = UIImage(cgImage: result.image)
            thumbnailTime = CMTimeGetSeconds(result.actualTime)
            sourceSize = CGSize(width: result.image.width, height: result.image.height)
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
            if edited, let selection = edit.scene {
                media = try await sceneModel.media(summary: summary, selection: selection)
            } else {
                media = ScenePlayback(url: summary.videoURL, track: summary.renderTrack)
            }
        } catch { statusMessage = "Couldn’t export the environment. \(error.localizedDescription)"; return nil }
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
        defer { isSaving = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photos access needed to save."
            return
        }

        guard let url = await resolveExportURL() else { return }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            let tag = version == .edited && edit.isEdited ? "Edited" : "Original"
            statusMessage = "Saved \(tag) to Photos (\(quality.rawValue))."
        } catch {
            statusMessage = "Couldn’t save: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func shareClip() async {
        guard let url = await resolveExportURL() else { return }
        sharePayload = SharePayload(url: url)
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
