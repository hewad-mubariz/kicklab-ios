import AVFoundation
import SwiftUI

/// AVPlayerLayer handles the original's orientation and HDR directly. No
/// frame extraction, Metal effects surface or temporary movie is needed.
struct OriginalReplaySurface: UIViewRepresentable {
    let player: AVPlayer
    var onFailure: (String) -> Void

    func makeUIView(context: Context) -> OriginalReplayView { OriginalReplayView() }
    func updateUIView(_ view: OriginalReplayView, context: Context) {
        view.onFailure = onFailure
        view.configure(player)
    }
    static func dismantleUIView(_ view: OriginalReplayView, coordinator: ()) { view.stop() }
}

final class OriginalReplayView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var onFailure: (String) -> Void = { _ in }
    private var itemObservation: NSKeyValueObservation?
    private var readinessObservation: NSKeyValueObservation?

    func configure(_ player: AVPlayer) {
        guard playerLayer.player !== player else { return }
        stop()
        backgroundColor = .black
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "original-replay-surface"
        accessibilityLabel = "Original video"
        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        readinessObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            let ready = layer.isReadyForDisplay
            Task { @MainActor [weak self] in
                self?.accessibilityValue = ready ? "Ready" : "Opening"
                #if DEBUG
                if ready { ImportFlowAudit.mark("native_replay_ready_s") }
                #endif
            }
        }
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? String(localized: "Couldn’t open this video.", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            Task { @MainActor [weak self] in self?.onFailure(message) }
        }
    }

    func stop() {
        itemObservation = nil
        readinessObservation = nil
        playerLayer.player = nil
    }
}
