import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit

/// One-tap download from the editor: renders exactly what the editor shows (effects, ball,
/// environment and counter) at 1080p and saves it to Photos. No Original/Edited choice.
final class ReplayDownloader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case exporting(Double)
        case saving
        case saved
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .exporting, .saving: true
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var needsForeground = false
    /// The saved file, for sharing, and a frame of it for the toast.
    @Published private(set) var savedURL: URL?
    @Published private(set) var thumbnail: CGImage?
    private let burnIn = BallStyleBurnIn()
    /// What the last saved file shows; an edit after saving makes the next tap save again.
    private var savedLook: (SessionEditState, ExportOverlaySettings)?

    var progress: Double {
        switch phase {
        case .preparing: 0.02
        case .exporting(let value): max(0.02, value)
        case .saving, .saved: 1
        default: 0
        }
    }

    /// True when the saved file no longer matches the editor.
    func isStale(edit: SessionEditState, overlays: ExportOverlaySettings) -> Bool {
        guard let savedLook else { return true }
        return savedLook.0 != edit || savedLook.1 != overlays
    }

    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    func download(summary: SessionSummary, edit: SessionEditState, overlays: ExportOverlaySettings,
                  sceneModel: StadiumPreviewModel, preparation: SessionEffectsPreparation,
                  distanceTimeline: BallDistanceTimeline? = nil) async {
        guard !phase.isBusy else { return }
        phase = .preparing
        let analyticsStart = ContinuousClock.now
        let activity: ProductEvent.Activity = distanceTimeline == nil ? .juggling : .ballDistance
        ProductAnalytics.shared.track(.exportStarted(activity, effect: edit.style.rawValue, graph: overlays.graph.enabled))
        var outcome: ProductEvent.Outcome = .failed
        defer {
            let elapsed = analyticsStart.duration(to: .now)
            ProductAnalytics.shared.track(.exportFinished(activity, outcome, elapsed: Double(elapsed.components.seconds)))
        }
        await VideoSaveCompletion.shared.prepare()
        do {
            try await VideoBackgroundWork.shared.run(title: "Saving your replay",
                requiresGPU: (edit.style != .none && edit.intensity > 0) || edit.environment != .original || edit.scene != nil
                    || (edit.ballSkin != .original && summary.needsVisualPreparation && preparation.prepared == nil)) {
                try await self.performDownload(summary: summary, edit: edit, overlays: overlays,
                    sceneModel: sceneModel, preparation: preparation, distanceTimeline: distanceTimeline)
            }
            outcome = .completed
        } catch is CancellationError {
            if case .saved = phase { outcome = .completed; return }
            outcome = .cancelled
            burnIn.cancel()
            phase = .failed("Saving stopped. Tap Download to try again.")
        } catch {
            burnIn.cancel()
            phase = .failed(error.localizedDescription)
        }
    }

    private func performDownload(summary: SessionSummary, edit: SessionEditState, overlays: ExportOverlaySettings,
                  sceneModel: StadiumPreviewModel, preparation: SessionEffectsPreparation,
                  distanceTimeline: BallDistanceTimeline?) async throws {
        needsForeground = VideoWorkExecution.lease?.canContinue != true
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "ReplayExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Photos access in Settings to save your replay."])
        }
        let media: ScenePlayback
        do {
            let ready = edit.ballSkin != .original ? try await preparation.prepare(summary) : summary
            if let selection = edit.scene {
                media = try await sceneModel.media(summary: ready, selection: selection)
            } else {
                media = ScenePlayback(url: ready.videoURL, track: ready.renderTrack)
            }
        } catch {
            throw error
        }
        burnIn.export(source: media.url, track: media.track, style: edit.style, intensity: edit.intensity,
                      skin: edit.ballSkin, environment: edit.environment, shortEdge: 1080,
                      counter: ExportCounterTimeline(touches: summary.touchesMarked, total: summary.touches),
                      overlays: overlays, preserveFrameTimes: edit.scene != nil, distanceTimeline: distanceTimeline,
                      motionTimeline: overlays.graph.enabled ? MotionStyleTimeline(points: summary.track.map {
                          CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil, x: $0.detected ? $0.x : nil)
                      }, touchTimes: summary.touchesMarked.map(\.time)) : nil)
        while burnIn.isExporting {
            try await VideoWorkExecution.checkpoint()
            VideoWorkExecution.lease?.progress(burnIn.progress * 0.96, subtitle: "Saving your replay")
            phase = .exporting(burnIn.progress)
            try await Task.sleep(for: .milliseconds(80))
        }
        guard let url = burnIn.outputURL else {
            throw NSError(domain: "ReplayExport", code: 2, userInfo: [NSLocalizedDescriptionKey: burnIn.status.isEmpty ? "Couldn’t render your replay." : burnIn.status])
        }
        try await VideoWorkExecution.checkpoint()
        phase = .saving
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } catch {
            throw error
        }
        savedURL = url
        savedLook = (edit, overlays)
        thumbnail = await Self.frame(of: url)
        phase = .saved
        await VideoSaveCompletion.shared.saved()
    }

    private static func frame(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        return try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    }
}

// MARK: - Download button

/// Lime download circle → glass pill with a progress ring and percentage → mint check.
struct ReplayDownloadButton: View {
    let phase: ReplayDownloader.Phase
    let progress: Double
    let action: () -> Void
    var needsForeground = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lime = Color(red: 0.84, green: 1, blue: 0.42)

    var body: some View {
        Button(action: action) {
            ZStack {
                switch phase {
                case .preparing, .exporting, .saving:
                    HStack(spacing: 7) {
                        ring.frame(width: 26, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phase == .saving ? "Saving" : "\(Int((progress * 100).rounded()))%")
                                .font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText(value: progress)).foregroundStyle(.white)
                            if needsForeground {
                                Text("Keep app open").font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                    .padding(.leading, 9).padding(.trailing, 13)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.sessionPop(scale: 0.6))
                case .saved:
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(SessionStyle.background)
                        .frame(width: 44, height: 44)
                        .background(SessionStyle.mint, in: .circle)
                        .shadow(color: SessionStyle.mint.opacity(0.6), radius: 10)
                        .transition(.sessionPop(scale: 0.3))
                default:
                    Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 44, height: 44)
                        .background(lime, in: .circle)
                        .transition(.sessionPop(scale: 0.6))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: kind)
        .animation(.linear(duration: 0.2), value: progress)
        .sensoryFeedback(.impact(weight: .medium), trigger: kind) { _, new in new == 1 }
        .sensoryFeedback(.success, trigger: kind) { _, new in new == 3 }
        .accessibilityLabel(label)
        .accessibilityHint(needsForeground && phase.isBusy ? "Saving pauses outside the app and resumes when you return." : "")
    }

    /// 0 idle/failed, 1 starting, 2 working, 3 saved: changes drive the morph.
    private var kind: Int {
        switch phase {
        case .idle, .failed: 0
        case .preparing: 1
        case .exporting, .saving: 2
        case .saved: 3
        }
    }

    private var label: String {
        switch phase {
        case .preparing: "Preparing download"
        case .exporting: "Saving, \(Int((progress * 100).rounded())) percent"
        case .saving: "Saving to Photos"
        case .saved: "Saved to Photos. Share"
        default: "Download"
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 3)
            if phase == .preparing {
                TimelineView(.animation(paused: reduceMotion)) { context in
                    Circle().trim(from: 0, to: 0.25)
                        .stroke(lime, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate * 320).truncatingRemainder(dividingBy: 360)))
                }
            } else {
                Circle().trim(from: 0, to: progress)
                    .stroke(lime, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "arrow.down").font(.system(size: 10, weight: .heavy)).foregroundStyle(lime)
        }
    }
}

// MARK: - Toast

/// Drops in under the top bar when the replay is in Photos, or when saving fails.
struct ReplaySavedToast: View {
    let thumbnail: CGImage?
    let detail: String
    var failure: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let failure {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(Theme.warn)
                    .frame(width: 30, height: 30)
                Text(failure).font(.system(size: 13, weight: .medium)).lineLimit(2)
            } else {
                Group {
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                    } else { Color.white.opacity(0.15) }
                }
                .frame(width: 30, height: 42).clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved to Photos").font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.black, SessionStyle.mint)
            }
        }
        .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
        .frame(maxWidth: 300)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("replay-saved-toast")
        .onTapGesture { if failure == nil { VideoSaveCompletion.shared.openPhotos() } }
        .accessibilityAddTraits(failure == nil ? .isButton : [])
        .accessibilityHint(failure == nil ? "Open Photos" : "")
    }
}

// MARK: - Share panel

/// After saving: where the replay goes next, and what to do after that.
struct ReplaySharePanel: View {
    let onShare: () -> Void
    let onClose: () -> Void
    var onRecordAnother: (() -> Void)?
    var onDone: (() -> Void)?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Share your replay").font(.system(size: 17, weight: .semibold))
                    .sessionEntrance(appeared, offset: 8)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel("Keep editing")
                .accessibilityIdentifier("replay-share-close")
            }
            HStack(spacing: 0) {
                target("Stories", "camera.fill", AnyShapeStyle(LinearGradient(
                    colors: [Color(red: 0.98, green: 0.75, blue: 0.2), Color(red: 0.93, green: 0.2, blue: 0.45), Color(red: 0.55, green: 0.25, blue: 0.9)],
                    startPoint: .bottomLeading, endPoint: .topTrailing)), order: 1)
                target("TikTok", "music.note", AnyShapeStyle(Color(white: 0.07)), order: 2)
                target("Messages", "message.fill", AnyShapeStyle(Color(red: 0.2, green: 0.78, blue: 0.35)), order: 3)
                target("More", "ellipsis", AnyShapeStyle(Color.white.opacity(0.12)), order: 4)
            }
            if onRecordAnother != nil || onDone != nil {
                HStack(spacing: 10) {
                    if let onRecordAnother {
                        Button(action: onRecordAnother) {
                            Label("Record another", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 46)
                                .background(.white.opacity(0.1), in: .capsule)
                        }
                        .buttonStyle(SessionPressStyle())
                        .accessibilityIdentifier("replay-record-another")
                    }
                    if let onDone {
                        Button(action: onDone) {
                            Text("Done").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 96, height: 46).background(SessionStyle.mint, in: .capsule)
                        }
                        .buttonStyle(SessionPressStyle())
                        .accessibilityIdentifier("replay-done")
                    }
                }
                .sessionEntrance(appeared, order: 5, offset: 10)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-share-panel")
    }

    /// Every target opens the system share sheet for now; it lists Instagram and TikTok when installed.
    private func target(_ title: String, _ symbol: String, _ fill: AnyShapeStyle, order: Int) -> some View {
        Button(action: onShare) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(fill, in: .circle)
                    .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6) }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .sessionEntrance(appeared, order: order, offset: 14, scale: 0.85)
        .accessibilityLabel("Share to \(title)")
    }
}

struct ReplayShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ReplayShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
