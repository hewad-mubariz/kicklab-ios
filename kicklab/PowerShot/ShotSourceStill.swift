import AVFoundation
import SwiftUI

/// AVPlayer's display cadence may resample a VFR source. While choosing a frame, display an
/// exact source still instead; never let a neighbouring playback frame impersonate it.
struct ShotSourceStill: View {
    let source: URL
    let time: Double
    @State private var picture: CGImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.black
            if let picture { Image(decorative: picture, scale: 1).resizable().scaledToFit() }
            else if failed { Text("This frame couldn’t be displayed. Choose a nearby frame.").font(.footnote).padding(20) }
            else { ProgressView().tint(SessionStyle.mint) }
        }
        .accessibilityIdentifier("shot-source-preview")
        .task(id: source.absoluteString + String(time)) {
            picture = nil; failed = false
            let owner = ShotSourceImageGenerator(source: source)
            let generator = owner.generator
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1080, height: 1080)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            await withTaskCancellationHandler {
                let image = try? await generator.image(at: CMTime(seconds: time + 0.000001, preferredTimescale: 1_800_000_000)).image
                guard !Task.isCancelled else { return }
                picture = image; failed = image == nil
            } onCancel: { Task { @MainActor in owner.cancel() } }
        }
    }
}

/// Image generation and cancellation stay on the same actor. Cancellation
/// callbacks may arrive on any executor, so capture this owner, not AVFoundation's
/// non-Sendable generator, when hopping back to the main actor.
@MainActor
private final class ShotSourceImageGenerator {
    let generator: AVAssetImageGenerator

    init(source: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
    }

    func cancel() { generator.cancelAllCGImageGeneration() }
}
