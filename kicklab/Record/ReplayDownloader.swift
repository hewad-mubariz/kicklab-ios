import AVFoundation
import Combine
import Photos
import SwiftUI
import UIKit

/// One-tap download from the editor: renders exactly what the editor shows (effects, ball,
/// environment and counter) at 1080p, or at the clip's own size and frame rate when chosen, and
/// saves it to Photos. No Original/Edited choice.
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
    /// The saved file's size and frame rate, such as "4K · 120 fps", for the toast.
    @Published private(set) var savedQuality = "1080p"
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
                  distanceTimeline: BallDistanceTimeline? = nil, choice: ExportChoice? = nil) async {
        guard !phase.isBusy else { return }
        #if DEBUG
        if FinalTestCoordinator.shared.analysisRunning, FinalTestCoordinator.shared.matches(summary.videoURL) {
            phase = .failed("Wait for the validation analysis to finish before exporting."); return
        }
        FinalTestCoordinator.shared.exportStarted(summary.videoURL, settings: overlays)
        #endif
        phase = .preparing
        let analyticsStart = ContinuousClock.now
        let activity: ProductEvent.Activity = distanceTimeline == nil ? .juggling : .ballDistance
        ProductAnalytics.shared.track(.exportStarted(activity, effect: edit.style.rawValue, graph: overlays.graph.enabled))
        var outcome: ProductEvent.Outcome = .failed
        defer {
            let elapsed = analyticsStart.duration(to: .now)
            ProductAnalytics.shared.track(.exportFinished(activity, outcome, elapsed: Double(elapsed.components.seconds)))
        }
        do {
            try await VideoBackgroundWork.shared.run(title: String(localized: "Saving your replay", bundle: AppLanguage.bundle, locale: AppLanguage.locale),
                requiresGPU: edit.usesEffects || edit.environment != .original || edit.scene != nil
                    || (edit.usesBallMaterial && summary.needsVisualPreparation && preparation.prepared == nil)) {
                try await self.performDownload(summary: summary, edit: edit, overlays: overlays,
                    sceneModel: sceneModel, preparation: preparation, distanceTimeline: distanceTimeline, choice: choice)
            }
            outcome = .completed
            #if DEBUG
            await FinalTestCoordinator.shared.exportFinished(summary.videoURL, output: savedURL, error: nil)
            #endif
        } catch is CancellationError {
            if case .saved = phase { outcome = .completed; return }
            outcome = .cancelled
            await burnIn.cancelAndWait()
            phase = .failed(String(localized: "Saving stopped. Tap Download to try again.", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            #if DEBUG
            await FinalTestCoordinator.shared.exportFinished(summary.videoURL, output: nil, error: "Export cancelled")
            #endif
        } catch {
            await burnIn.cancelAndWait()
            phase = .failed(error.localizedDescription)
            #if DEBUG
            await FinalTestCoordinator.shared.exportFinished(summary.videoURL, output: nil, error: error.localizedDescription)
            #endif
        }
    }

    private func performDownload(summary: SessionSummary, edit: SessionEditState, overlays: ExportOverlaySettings,
                  sceneModel: StadiumPreviewModel, preparation: SessionEffectsPreparation,
                  distanceTimeline: BallDistanceTimeline?, choice: ExportChoice?) async throws {
        needsForeground = VideoWorkExecution.lease?.canContinue != true
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "ReplayExport", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Allow Photos access in Settings to save your replay.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)])
        }
        let media: ScenePlayback
        do {
            let ready = try await preparation.prepare(summary, for: edit, everyFrame: choice?.keepsEveryFrame == true)
            if let selection = edit.scene {
                media = try await sceneModel.media(summary: ready, selection: selection)
            } else {
                media = ScenePlayback(url: ready.videoURL, track: ready.renderTrack)
            }
        } catch {
            throw error
        }
        try Task.checkCancellation()
        burnIn.export(source: media.url, track: media.track, style: edit.style, intensity: edit.intensity,
                      skin: edit.ballSkin, environment: edit.environment, shortEdge: choice == nil ? 1080 : choice?.shortEdge,
                      maxFrameRate: choice?.maxFrameRate,
                      counter: ExportCounterTimeline(touches: summary.touchesMarked, total: summary.touches),
                      overlays: overlays, preserveFrameTimes: edit.scene != nil, distanceTimeline: distanceTimeline,
                      motionTimeline: overlays.graph.enabled ? MotionStyleTimeline(points: summary.track.map {
                          CaptureMotionPoint(time: $0.time, y: $0.detected ? $0.y : nil, x: $0.detected ? $0.x : nil)
                      }, touchTimes: summary.touchesMarked.map(\.time)) : nil,
                      lookChanges: edit.lookChanges, swapEffect: edit.swapEffect,
                      soundtrack: ReplaySoundtrack(edit: edit, touchTimes: summary.touchesMarked.map(\.time),
                                                   milestones: overlays.milestoneFanfare),
                      clipAudio: edit.clipAudio)
        while burnIn.isExporting {
            try await VideoWorkExecution.checkpoint()
            VideoWorkExecution.lease?.progress(burnIn.progress * 0.96, subtitle: String(localized: "Saving your replay", bundle: AppLanguage.bundle, locale: AppLanguage.locale))
            phase = .exporting(burnIn.progress)
            #if DEBUG
            FinalTestCoordinator.shared.exportProgress(summary.videoURL, progress: burnIn.progress, saving: false)
            #endif
            try await Task.sleep(for: .milliseconds(80))
        }
        guard let url = burnIn.outputURL else {
            throw NSError(domain: "ReplayExport", code: 2, userInfo: [NSLocalizedDescriptionKey: burnIn.status.isEmpty ? String(localized: "Couldn’t render your replay.", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : burnIn.status])
        }
        #if DEBUG && TOUCH_COUNTING_DEBUG
        RFEffectsRoutingAudit.exported(source: summary.videoURL, output: url, track: media.track,
            edit: edit, count: summary.touches, touches: summary.touchesMarked)
        #endif
        try await VideoWorkExecution.checkpoint()
        phase = .saving
        #if DEBUG
        FinalTestCoordinator.shared.exportProgress(summary.videoURL, progress: 1, saving: true)
        #endif
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
        savedQuality = await Self.quality(of: url) ?? savedQuality
        phase = .saved
        await VideoSaveCompletion.shared.saved()
    }

    private static func quality(of url: URL) async -> String? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize), let fps = try? await track.load(.nominalFrameRate) else { return nil }
        return ExportChoice.label(size: size, fps: Double(fps))
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
    /// Set while a large or fast clip asks how to save: the button stretches into the two choices.
    var choices: (faster: ExportChoice, original: ExportChoice)?
    var onChoose: (ExportChoice) -> Void = { _ in }
    var onCancelChoice: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lime = Color(red: 0.84, green: 1, blue: 0.42)
    /// Overshoots a little as the circle stretches into the choices and back.
    private static let stretch = Animation.spring(response: 0.46, dampingFraction: 0.62)

    private var choosing: Bool { choices != nil && kind == 0 }

    var body: some View {
        ZStack(alignment: .trailing) {
            if let choices, choosing {
                choicePill(choices).fixedSize()
                    // A container keeps each choice's own identifier under the caller's one.
                    .accessibilityElement(children: .contain)
                    .transition(.modifier(active: StretchFromTrailing(amount: 0.18), identity: StretchFromTrailing(amount: 1)))
            } else {
                downloadButton.transition(.sessionPop(scale: 0.6))
            }
        }
        // While idle the button keeps the circle's width, so the choices grow to the left over the
        // title instead of pushing the bar's layout; progress widens it as before.
        .frame(width: kind == 0 ? 44 : nil, alignment: .trailing)
        .animation(SessionMotion.animation(Self.stretch, reduceMotion: reduceMotion), value: choosing)
        .sensoryFeedback(.impact(weight: .light), trigger: choosing) { _, new in new }
    }

    private func choicePill(_ choices: (faster: ExportChoice, original: ExportChoice)) -> some View {
        HStack(spacing: 6) {
            Button(action: onCancelChoice) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.14), in: .circle)
            }
            .buttonStyle(SessionPressStyle(scale: 0.9))
            .accessibilityLabel(Text("Cancel"))
            .accessibilityIdentifier("replay-save-cancel")
            option(choices.original, caption: "Original", primary: false)
                .accessibilityIdentifier("replay-save-original")
            option(choices.faster, caption: "Faster", primary: true)
                .accessibilityIdentifier("replay-save-faster")
        }
        .padding(4)
        .appGlass(in: .capsule)
    }

    private func option(_ choice: ExportChoice, caption: LocalizedStringKey, primary: Bool) -> some View {
        Button { onChoose(choice) } label: {
            VStack(spacing: 0) {
                Text(verbatim: choice.label).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                Text(caption).font(.system(size: 9, weight: .semibold)).opacity(0.75)
            }
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(primary ? lime : Color.white.opacity(0.14), in: .capsule)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .accessibilityElement(children: .combine)
    }

    private var downloadButton: some View {
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
                    .appGlass(in: .capsule)
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
        case .preparing: String(localized: "Preparing download", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .exporting: String(localized: "Saving, \(Int((progress * 100).rounded())) percent", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .saving: String(localized: "Saving to Photos", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .saved: String(localized: "Saved to Photos. Share", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        default: String(localized: "Download", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
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
        Group {
            if failure == nil {
                Button {
                    VideoSaveCompletion.shared.openPhotos()
                } label: {
                    toastContent
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open Photos")
            } else {
                toastContent
            }
        }
        .accessibilityIdentifier("replay-saved-toast")
    }

    private var toastContent: some View {
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
        .appGlass(in: .capsule)
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Share panel

/// After saving: where the replay goes next, and what to do after that.
struct ReplaySharePanel: View {
    let onShare: () -> Void
    let onClose: () -> Void
    var onRecordAnother: (() -> Void)?
    var onDone: (() -> Void)?
    /// The saved replay's edit, when it is worth keeping as My style.
    var myStyleEdit: SessionEditState? = nil
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your replay is ready").font(.system(size: 17, weight: .semibold))
                    .sessionEntrance(appeared, offset: 8)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32)
                }
                .appGlassButtonStyle().buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel("Keep editing")
                .accessibilityIdentifier("replay-share-close")
            }
            Button(action: onShare) {
                Label {
                    Text("Share video")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(SessionStyle.mint)
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(.white.opacity(0.1), in: .capsule)
                .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.7) }
                .contentShape(.capsule)
            }
            .buttonStyle(SessionPressStyle())
            .sessionEntrance(appeared, order: 1, offset: 10)
            .accessibilityHint("Choose an app or action in the share sheet")
            .accessibilityIdentifier("replay-share-video")
            if let myStyleEdit {
                MyStyleShareRow(edit: myStyleEdit)
                    .sessionEntrance(appeared, order: 2, offset: 10)
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
                .sessionEntrance(appeared, order: 3, offset: 10)
            }
        }
        .padding(18)
        .foregroundStyle(.white)
        .appGlass(in: .rect(cornerRadius: 26))
        .onAppear { appeared = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("replay-share-panel")
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

/// Grows a view sideways out of its trailing edge, as the Download circle stretches into its choices:
/// a capsule reveals the content without squashing it, and only the spring's overshoot bulges it.
private struct StretchFromTrailing: ViewModifier, Animatable {
    var amount: Double
    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(alignment: .trailing) {
                GeometryReader { proxy in
                    Capsule()
                        .frame(width: max(proxy.size.height, proxy.size.width * min(amount, 1)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
            }
            .scaleEffect(x: max(1, amount), y: 1, anchor: .trailing)
            .opacity(min(1, amount * 2.5))
    }
}
