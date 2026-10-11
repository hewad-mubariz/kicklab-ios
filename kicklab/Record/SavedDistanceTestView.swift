import AVKit
import SwiftUI

/// A temporary review surface; it needs neither AR capture nor model inference.
struct SavedDistanceTestView: View {
    let recording: ShotRecording
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer?
    @State private var observer: Any?
    @State private var timeline: SavedDistanceTestTimeline?
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var error: String?
    @State private var showPhases = false

    private var reading: BallDistanceTimeline.Sample? { timeline?.test?.state(at: time) }
    private var savedReading: BallDistanceTimeline.Sample? { timeline?.saved?.state(at: time) }
    private var detail: String {
        switch reading?.status {
        case .waiting: "Waiting for the saved start"
        case .needsSetup: "Phone or floor changed · test stopped"
        case .paused: "Last position · no new observation"
        case .tracking, .estimate, .finished: "From start · roll cutoffs off"
        case nil: "No compatible saved positions"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            if landscape {
                HStack(spacing: 16) {
                    video
                    information.frame(width: min(280, geometry.size.width * 0.35))
                }.padding(16)
            } else {
                VStack(spacing: 16) {
                    video
                    information
                }.padding(16)
            }
        }
        .background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .navigationTitle("Distance test").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showPhases) {
            SavedShotPhaseTestView(recording: recording)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Replay", systemImage: "arrow.counterclockwise") {
                    time = 0
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    player?.play()
                }.disabled(player == nil).accessibilityIdentifier("saved-distance-replay")
            }
        }
        .task { await open() }
        .onDisappear { close() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
    }

    private var video: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player {
                VideoPlayer(player: player)
                    .accessibilityIdentifier("saved-distance-video")
                BallDistanceReadout(value: reading?.valueLabel ?? "— m", detail: detail,
                    paused: reading?.status == .paused || reading?.status == .needsSetup, compact: true,
                    accessibilityPrefix: "saved-distance-test")
                    .padding(12).background(.black.opacity(0.68), in: .rect(cornerRadius: 14))
                    .padding(12).allowsHitTesting(false)
            } else if let error {
                ContentUnavailableView("Couldn’t open test", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else {
                ProgressView("Opening saved test…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(.rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12)))
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("REPLAY TEST", systemImage: "flask").font(.system(size: 10, weight: .semibold))
                    .tracking(1).foregroundStyle(SessionStyle.mint)
                Spacer()
                Text(String(format: "%.1f / %.1f s", time, duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("saved-distance-time")
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Original reading").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(savedReading?.valueLabel ?? "— m").font(.title3.monospacedDigit().bold())
                    .accessibilityIdentifier("saved-distance-original")
            }
            Text(timeline != nil && timeline?.test == nil
                 ? "This test needs the floor positions from a newer Ball Distance recording. The original video is still available."
                 : "Ground estimate with movement and gap cutoffs off. Airborne shots can jump. This is distance from the start, not flight path or speed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(recording.date.formatted(date: .abbreviated, time: .standard))
                .font(.caption2).foregroundStyle(.secondary)
            Button {
                player?.pause(); showPhases = true
            } label: {
                Label("Flight & roll", systemImage: "timeline.selection")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).tint(SessionStyle.mint).foregroundStyle(.black)
                .disabled(player == nil).accessibilityIdentifier("saved-distance-phases")
        }.padding(16).background(.white.opacity(0.07), in: .rect(cornerRadius: 18))
    }

    private func open() async {
        guard player == nil else { return }
        do {
            let recording = recording
            let data = try await Task.detached(priority: .userInitiated) {
                try SavedDistanceTestTimeline.load(directory: recording.directory)
            }.value
            let asset = try await BallDistanceMedia.playbackComposition(of: recording)
            let length = try await asset.load(.duration)
            try Task.checkCancellation()
            timeline = data; duration = length.seconds; time = 0
            let next = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = next
            observer = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { stamp in
                MainActor.assumeIsolated {
                    if stamp.seconds.isFinite { time = max(0, stamp.seconds) }
                }
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func close() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil; player = nil
    }
}
