//
//  ReviewView.swift
//  kicklab
//
//  Watch the run back, full screen, with every touch explained.
//
//  This is the proof. A count of 32 tells you nothing about *which* 32, and
//  nearly every counting bug in this project was found by watching one specific
//  moment rather than by staring at a total.
//
//  The video fills the screen and the annotations sit on it; the numbers live in
//  a sheet that pulls up over the bottom, so reading the detail never shrinks the
//  thing being explained.
//

import AVKit
import SwiftUI

struct ReviewView: View {
    let url: URL
    let touches: [RecordedTouch]
    var track: [RecordedFrame] = []
    var onDone: () -> Void = {}

    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var observer: Any?
    @State private var reportURL: URL?
    @State private var showDetail = true
    @State private var isPlaying = true
    @StateObject private var exporter = AnnotationExporter()

    private let highlightWindow = 0.28

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

            // Annotations, drawn over the video and put through a bloom shader.
            //
            // The glow is not decoration: its strength follows the detector's
            // confidence, so a confidently tracked ball burns brighter than a
            // marginal one, and you can see the model losing conviction.
            GeometryReader { geo in
                AnnotationCanvas(track: track, touches: touches, time: currentTime)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .layerEffect(
                        ShaderLibrary.neonBloom(
                            .float(3.0),
                            .float(Float(0.55 + 0.85 * currentConfidence))
                        ),
                        maxSampleOffset: CGSize(width: 8, height: 8)
                    )
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Shockwaves, drawn per-pixel by a fragment shader.
            ShockwaveLayer(waves: activeWaves)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .blendMode(.plusLighter)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomControls
            }
        }
        .statusBarHidden()
        .onAppear {
            setUp()
            reportURL = writeReport()
        }
        .onDisappear {
            if let observer { player?.removeTimeObserver(observer) }
            player?.pause()
        }
        .sheet(isPresented: $showDetail) {
            detailSheet
                .presentationDetents([.height(150), .medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Over the video

    private var topBar: some View {
        HStack {
            Button {
                onDone()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.bold())
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.5), in: Circle())
            }
            Spacer()
            HStack(spacing: 6) {
                Text("\(countedSoFar)")
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .monospacedDigit()
                Text("/ \(touches.count)")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomControls: some View {
        VStack(spacing: 0) {
            // The run as a wave: arches, with a marker in each trough.
            TrajectoryStrip(track: track, touches: touches, time: currentTime)

            HStack(spacing: 18) {
                Button { step(-1) } label: {
                    Image(systemName: "gobackward.5")
                }
                Button {
                    isPlaying.toggle()
                    isPlaying ? player?.play() : player?.pause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Button { step(1) } label: {
                    Image(systemName: "goforward.5")
                }
                Spacer()
                Button { showDetail.toggle() } label: {
                    Image(systemName: "list.bullet")
                }
            }
            .font(.title3)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.black.opacity(0.45))
        }
        .padding(.bottom, 150)
    }

    // MARK: - Detail sheet

    private var detailSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    stats
                    ForEach(touches) { touch in
                        Button { seek(to: max(0, touch.time - 0.45)) } label: {
                            HStack(spacing: 12) {
                                Text("\(touch.index + 1)")
                                    .font(.system(.footnote, design: .rounded).bold())
                                    .monospacedDigit()
                                    .frame(width: 28, height: 28)
                                    .background(isNow(touch) ? AnyShapeStyle(Theme.accent)
                                                             : AnyShapeStyle(.quaternary),
                                                in: Circle())
                                    .foregroundStyle(isNow(touch) ? .black : .secondary)
                                Text(String(format: "%.2fs", touch.time))
                                    .font(.system(.subheadline, design: .monospaced))
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 18)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(isNow(touch) ? Theme.accent.opacity(0.14) : .clear)
                    }
                }
            }
            .navigationTitle("\(touches.count) touches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let report = reportURL {
                        ShareLink(item: report) { Image(systemName: "doc.text") }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // The annotated file is the one worth sharing: the
                        // overlay is burned in, so it plays anywhere without the
                        // app or a screen recording.
                        if let annotated = exporter.outputURL {
                            ShareLink(item: annotated) {
                                Label("Share annotated video", systemImage: "sparkles.tv")
                            }
                        } else {
                            Button {
                                exporter.export(source: url, track: track, touches: touches)
                            } label: {
                                Label(exporter.isExporting
                                      ? "Rendering…" : "Export annotated video",
                                      systemImage: "wand.and.stars")
                            }
                            .disabled(exporter.isExporting)
                        }
                        ShareLink(item: url) {
                            Label("Share original", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if exporter.isExporting {
                    VStack(spacing: 4) {
                        ProgressView(value: exporter.progress)
                        Text("Rendering annotated video…")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.bar)
                } else if exporter.outputURL != nil {
                    Label("Annotated video ready — share it from the menu",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(.vertical, 6)
                }
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat("\(touches.count)", "touches", Theme.accent)
            Rectangle().fill(.quaternary).frame(width: 1, height: 26)
            stat(String(format: "%.0fs", duration), "length", .secondary)
            Rectangle().fill(.quaternary).frame(width: 1, height: 26)
            stat(rateText, "per min", .secondary)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - State

    private var rateText: String {
        guard duration > 0.5 else { return "-" }
        return String(format: "%.0f", Double(touches.count) / duration * 60)
    }

    private var countedSoFar: Int { touches.filter { $0.time <= currentTime }.count }

    /// Detector confidence at the playhead, which drives the bloom.
    private var currentConfidence: Double {
        guard let nearest = track.min(by: {
            abs($0.time - currentTime) < abs($1.time - currentTime)
        }), abs(nearest.time - currentTime) < 0.12 else { return 0 }
        return nearest.score
    }

    /// Touches near the playhead become waves. Keyed by index so scrubbing
    /// backwards replays them rather than firing a burst of stale ones.
    private var activeWaves: [Shockwave] {
        touches.compactMap { touch in
            let age = currentTime - touch.time
            guard age >= 0, age <= 0.8 else { return nil }
            return Shockwave(id: touch.index,
                             position: CGPoint(x: touch.x, y: touch.y),
                             born: Date().addingTimeInterval(-age))
        }
    }

    private func isNow(_ touch: RecordedTouch) -> Bool {
        abs(touch.time - currentTime) < highlightWindow
    }

    private func setUp() {
        let player = AVPlayer(url: url)
        self.player = player
        if let item = player.currentItem {
            Task {
                if let d = try? await item.asset.load(.duration) {
                    duration = max(0.01, CMTimeGetSeconds(d))
                }
            }
        }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { time in
            currentTime = CMTimeGetSeconds(time)
        }
        player.play()
    }

    private func step(_ seconds: Double) {
        seek(to: max(0, min(duration, currentTime + seconds * 5)))
    }

    private func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// What the app saw, so it can be diffed against the lab on the same footage.
    private func writeReport() -> URL? {
        var lines = ["# Juggle Dude run report",
                     "video: \(url.lastPathComponent)",
                     "touches: \(touches.count)",
                     "ball detected on frames: \(track.count)",
                     "",
                     "## touches (index, seconds, x, y)"]
        for t in touches {
            lines.append(String(format: "%d, %.3f, %.4f, %.4f", t.index + 1, t.time, t.x, t.y))
        }
        lines.append("")
        lines.append("## track (seconds, x, y, width, height, score)")
        for f in track {
            lines.append(String(format: "%.3f, %.4f, %.4f, %.4f, %.4f, %.4f",
                                f.time, f.x, f.y, f.width, f.height, f.score))
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-report.txt")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
