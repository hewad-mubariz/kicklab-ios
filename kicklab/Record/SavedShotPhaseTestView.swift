import AVFoundation
import SwiftUI

struct SavedShotPhaseTestView: View {
    let recording: ShotRecording
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = SavedShotPhasePlayer()
    @State private var marks = SavedShotPhaseMarks()
    @State private var timeline: SavedDistanceTestTimeline?
    @State private var evidence: SavedShotPhaseStore.Evidence?
    @State private var error: String?
    @State private var saveMessage = "Choose the kick frame, then the first landing."
    @State private var loaded = false

    private var span: SavedShotPhaseMarks.GroundSpan? { marks.groundSpan(positions: timeline?.positions ?? []) }

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height {
                HStack(spacing: 16) {
                    VStack(spacing: 8) { video; transport }
                    ScrollView { controls }.frame(width: min(310, geometry.size.width * 0.39))
                        .accessibilityIdentifier("phase-controls")
                }.padding(12)
            } else {
                VStack(spacing: 10) {
                    video
                    transport
                    ScrollView { controls }.frame(maxHeight: marks.flightSeconds == nil ? 210 : 275)
                        .accessibilityIdentifier("phase-controls")
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .background(.black).foregroundStyle(.white).preferredColorScheme(.dark)
        .navigationTitle("Flight & roll").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Clear marks", role: .destructive) { update(SavedShotPhaseMarks()) }
                } label: { Image(systemName: "ellipsis") }
                    .disabled(evidence == nil).accessibilityIdentifier("phase-options")
            }
        }
        .task { await open() }
        .onDisappear { playback.close() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.pause() } }
    }

    private var video: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let player = playback.player {
                SavedShotPhaseVideo(player: player)
                Text(marks.phase(at: playback.time)).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: .capsule).padding(12)
                    .accessibilityIdentifier("phase-current")
            } else if let error {
                ContentUnavailableView("Couldn’t open frames", systemImage: "exclamationmark.triangle",
                    description: Text(error))
            } else { ProgressView("Opening frames…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.clipShape(.rect(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
    }

    private var transport: some View {
        VStack(spacing: 5) {
            HStack {
                Text(String(format: "%.3f s", playback.time)).monospacedDigit()
                    .accessibilityIdentifier("phase-time")
                Spacer()
                Text("Frame \(playback.index + 1) / \(playback.frameTimes.count)").monospacedDigit()
                    .accessibilityIdentifier("phase-frame")
            }.font(.caption).foregroundStyle(.secondary)
            SavedShotPhaseScrubber(time: Binding(get: { playback.time }, set: { playback.seek(time: $0) }),
                duration: max(playback.frameTimes.last ?? 0, 0.001))
                .frame(height: 31).disabled(!loaded)
            HStack(spacing: 14) {
                Button { playback.step(-1) } label: { Image(systemName: "backward.end.fill").frame(width: 40, height: 36) }
                    .disabled(!loaded || playback.seeking || playback.index == 0)
                    .accessibilityLabel("Previous frame").accessibilityIdentifier("phase-previous-frame")
                Button { playback.togglePlay() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 40, height: 36)
                }.disabled(!loaded || playback.seeking)
                    .accessibilityLabel(playback.playing ? "Pause" : "Play").accessibilityIdentifier("phase-play")
                Button { playback.step(1) } label: { Image(systemName: "forward.end.fill").frame(width: 40, height: 36) }
                    .disabled(!loaded || playback.seeking || playback.index >= playback.frameTimes.count - 1)
                    .accessibilityLabel("Next frame").accessibilityIdentifier("phase-next-frame")
                Spacer(minLength: 0)
                Button { playback.pause(); playback.slow.toggle() } label: {
                    Text(playback.slow ? "¼×" : "1×").font(.subheadline.bold()).frame(width: 42, height: 36)
                }.accessibilityLabel(playback.slow ? "Quarter speed" : "Normal speed")
                    .accessibilityIdentifier("phase-rate")
            }.buttonStyle(.bordered).tint(SessionStyle.mint)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pause, then use the arrows to choose the exact frame.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                markButton("1 · Kick", subtitle: "Ball leaves the foot", identifier: "phase-set-kick") {
                    var next = marks; next.setKick(playback.time); update(next)
                }
                markButton("2 · First landing", subtitle: "First ground contact", identifier: "phase-set-landing") {
                    var next = marks; next.landing = playback.time; update(next)
                }.disabled(marks.kick == nil || playback.time <= (marks.kick ?? 0))
            }.disabled(!loaded || !playback.canMark)
            HStack(spacing: 12) {
                jump("Kick", time: marks.kick, identifier: "phase-jump-kick")
                Spacer()
                jump("Landing", time: marks.landing, identifier: "phase-jump-landing")
            }
            Text(saveMessage).font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("phase-save-status")
            if let seconds = marks.flightSeconds {
                result(seconds: seconds)
            } else {
                Text("Mark the first touchdown even if the ball bounces or rolls on afterwards. Leave a ground roll unmarked.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).background(.white.opacity(0.07), in: .rect(cornerRadius: 16))
    }

    private func markButton(_ title: String, subtitle: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(subtitle).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered).tint(SessionStyle.mint).accessibilityIdentifier(identifier)
    }

    private func jump(_ title: String, time: Double?, identifier: String) -> some View {
        Button { if let time { playback.seek(time: time) } } label: {
            Text(time.map { String(format: "%@ %.3f s ↗", title, $0) } ?? "\(title) —")
                .font(.caption.monospacedDigit())
        }.disabled(time == nil || !loaded).tint(SessionStyle.mint).accessibilityIdentifier(identifier)
    }

    private func result(seconds: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Marked flight time").font(.subheadline)
                Spacer()
                Text(String(format: "%.3f s", seconds)).font(.title3.monospacedDigit().bold())
                    .accessibilityIdentifier("phase-flight-time")
            }
            HStack {
                Text("Ground span · unverified").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(span.map { String(format: "%.2f m", $0.distanceM) } ?? "Unavailable")
                    .font(.subheadline.monospacedDigit().bold()).accessibilityIdentifier("phase-ground-span")
            }
            if let span, let kick = marks.kick, let landing = marks.landing {
                Text(String(format: "Ball observations: %.0f ms before kick · %.0f ms after landing.",
                    max(0, kick - span.start.time) * 1_000, max(0, span.end.time - landing) * 1_000))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(span == nil
                 ? "No matching ball positions close enough to both marks. The marked time is still saved."
                 : "Span stays fixed at these marks. Ground projection can be wrong at contact; speed stays pending while we check it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Play flight") {
                    if let kick = marks.kick, let landing = marks.landing { playback.play(from: kick, through: landing) }
                }.accessibilityIdentifier("phase-play-flight")
                Button("After landing") {
                    if let landing = marks.landing { playback.play(from: landing, through: playback.duration) }
                }.accessibilityIdentifier("phase-play-after")
            }.font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(SessionStyle.mint)
                .disabled(!loaded || playback.seeking)
        }
    }

    private func update(_ next: SavedShotPhaseMarks) {
        guard let evidence else { return }
        do {
            try SavedShotPhaseStore.save(next, directory: recording.directory, evidence: evidence, frameTimes: playback.frameTimes)
            marks = next; saveMessage = "Marks saved on this iPhone"
        } catch { saveMessage = "Couldn’t save: \(error.localizedDescription)" }
    }

    private func open() async {
        guard playback.player == nil else { return }
        do {
            try await playback.open(recording: recording)
            let directory = recording.directory, frameTimes = playback.frameTimes
            let values = try await Task.detached(priority: .userInitiated) {
                let timeline = try SavedDistanceTestTimeline.load(directory: directory)
                let evidence = try SavedShotPhaseStore.evidence(directory: directory)
                return (timeline, evidence)
            }.value
            try Task.checkCancellation()
            timeline = values.0; evidence = values.1
            do {
                marks = try SavedShotPhaseStore.load(directory: directory, evidence: values.1, frameTimes: frameTimes)
                if marks.kick != nil { saveMessage = "Saved marks restored · tap a time to review" }
            } catch { saveMessage = error.localizedDescription }
            loaded = true
        } catch is CancellationError { playback.close() }
        catch { playback.close(); self.error = error.localizedDescription }
    }
}

/// Keep an active drag independent of asynchronous player seeks. UIKit owns
/// the thumb until touch-up; a delayed time observer cannot move it backwards.
private struct SavedShotPhaseScrubber: UIViewRepresentable {
    @Binding var time: Double
    let duration: Double
    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = 0; slider.maximumValue = 1
        slider.minimumTrackTintColor = UIColor(SessionStyle.mint)
        slider.accessibilityLabel = "Video position"
        slider.accessibilityIdentifier = "phase-scrubber"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)),
            for: [.valueChanged, .touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.time = $time; context.coordinator.duration = duration
        slider.isEnabled = context.environment.isEnabled
        if !slider.isTracking { slider.value = Float(time / duration) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(time: $time, duration: duration) }
    final class Coordinator: NSObject {
        var time: Binding<Double>
        var duration: Double
        init(time: Binding<Double>, duration: Double) { self.time = time; self.duration = duration }
        @objc func changed(_ slider: UISlider) { time.wrappedValue = Double(slider.value) * duration }
    }
}

private struct SavedShotPhaseVideo: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) { view.video.player = player }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.video.player = nil }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var video: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) {
            super.init(frame: frame); video.videoGravity = .resizeAspect; backgroundColor = .black
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}
