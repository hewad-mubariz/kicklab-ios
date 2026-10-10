import AVFoundation
import SwiftUI

struct ShotSourceFramePicker: View {
    let source: URL?
    let frames: ShotSourceFrames
    let title: String
    @Binding var cursor: Double
    var range: Binding<ShotSourceRange>?
    var minimum = 0.0
    let onSeek: (Double) -> Void
    let onCancel: () -> Void
    let onDone: () -> Void
    @State private var editingEnd = false
    @State private var zoom = 1.0
    @State private var center = 0.0
    @State private var pinchZoom = 1.0
    @State private var pictures: [CGImage?] = []
    private var span: Double { max(0.05, frames.duration / zoom) }
    private var start: Double { min(max(0, frames.last - span), max(0, center - span / 2)) }
    private var end: Double { min(frames.last, start + span) }
    private var stamps: [Double] { (0..<9).map { frames.nearest(start + (end - start) * Double($0) / 8) } }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Cancel", action: onCancel).accessibilityIdentifier("shot-frame-cancel")
                Spacer()
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Done", action: onDone).tint(SessionStyle.mint).accessibilityIdentifier("shot-frame-done")
            }.buttonStyle(.glass).font(.system(size: 11, weight: .medium))
            if let range {
                HStack(spacing: 8) {
                    endpoint("Start", time: range.wrappedValue.start, selected: !editingEnd) {
                        editingEnd = false; cursor = range.wrappedValue.start; center = cursor; onSeek(cursor)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.white.opacity(0.4))
                    endpoint("End", time: range.wrappedValue.end, selected: editingEnd) {
                        editingEnd = true; cursor = range.wrappedValue.end; center = cursor; onSeek(cursor)
                    }
                }
            } else {
                Text(ShotSourceFrames.label(cursor)).font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    .accessibilityIdentifier("shot-frame-time")
            }
            timeline.frame(height: 62)
            HStack(spacing: 8) {
                Text(ShotSourceFrames.label(start)).monospacedDigit()
                Spacer()
                Button { changeZoom(zoom / 2) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out timeline").accessibilityIdentifier("shot-timeline-zoom-out").disabled(zoom <= 1)
                Text(String(format: "%g×", zoom)).monospacedDigit().frame(width: 30)
                Button { changeZoom(zoom * 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in timeline").accessibilityIdentifier("shot-timeline-zoom-in").disabled(zoom >= 32)
                Spacer()
                Text(ShotSourceFrames.label(end)).monospacedDigit()
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).buttonStyle(.plain)
            HStack(spacing: 12) {
                stepButton(-1)
                VStack(spacing: 2) {
                    Text("SOURCE FRAME \(frames.index(at: cursor) + 1)").font(.system(size: 10, weight: .medium)).tracking(0.7)
                    Text(range == nil ? "Drag to scrub · pinch to zoom" : "Drag a handle · step to refine")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                }.frame(maxWidth: .infinity)
                stepButton(1)
            }
        }
        .onAppear { center = cursor }
        .task(id: (source?.absoluteString ?? "") + stamps.description) { await thumbnails() }
    }

    private var timeline: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 24)
            let visible = max(0.001, end - start)
            let x: (Double) -> CGFloat = { 12 + CGFloat(($0 - start) / visible) * width }
            ZStack(alignment: .topLeading) {
                HStack(spacing: 1) {
                    ForEach(0..<9) { i in
                        Group {
                            if pictures.indices.contains(i), let picture = pictures[i] {
                                Image(decorative: picture, scale: 1).resizable().scaledToFill()
                            } else { Rectangle().fill(.white.opacity(0.08)) }
                        }.frame(width: geometry.size.width / 9 - 1, height: 56).clipped()
                    }
                }.clipShape(.rect(cornerRadius: 9)).padding(.top, 3)
                if let selected = range?.wrappedValue {
                    let left = max(12, x(selected.start)), right = min(geometry.size.width - 12, x(selected.end))
                    if right > left {
                        Rectangle().fill(SessionStyle.mint.opacity(0.16)).frame(width: right - left, height: 56)
                            .overlay { Rectangle().strokeBorder(SessionStyle.mint.opacity(0.65), lineWidth: 1) }
                            .offset(x: left, y: 3).allowsHitTesting(false)
                    }
                    if selected.start >= start && selected.start <= end {
                        handle(x: x(selected.start), isEnd: false, width: width, visible: visible)
                    }
                    if selected.end >= start && selected.end <= end {
                        handle(x: x(selected.end), isEnd: true, width: width, visible: visible)
                    }
                }
                Rectangle().fill(.white).frame(width: 2, height: 62).position(x: min(geometry.size.width - 12, max(12, x(cursor))), y: 31)
                    .shadow(color: .black.opacity(0.7), radius: 2).allowsHitTesting(false)
            }
            .contentShape(.rect)
            .coordinateSpace(name: "shot-frame-timeline")
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                set(start + Double(min(1, max(0, (value.location.x - 12) / width))) * visible)
            })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoom = min(32, max(1, pinchZoom * value.magnification))
            }.onEnded { _ in pinchZoom = zoom; center = cursor })
            .accessibilityElement(children: .contain).accessibilityIdentifier("shot-source-timeline")
        }
    }
    private func handle(x: CGFloat, isEnd: Bool, width: CGFloat, visible: Double) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(SessionStyle.mint).frame(width: 10, height: 62)
            .overlay { Capsule().fill(.black.opacity(0.4)).frame(width: 2, height: 22) }
            .frame(width: 44, height: 62).contentShape(.rect).position(x: x, y: 31)
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("shot-frame-timeline")).onChanged { value in
                editingEnd = isEnd
                set(start + Double(min(1, max(0, (value.location.x - 12) / width))) * visible)
            })
            .accessibilityLabel(isEnd ? "End handle" : "Start handle")
            .accessibilityElement(children: .ignore)
            .accessibilityValue(ShotSourceFrames.label(isEnd ? range?.wrappedValue.end ?? cursor : range?.wrappedValue.start ?? cursor))
            .accessibilityAdjustableAction { direction in
                editingEnd = isEnd
                cursor = isEnd ? range?.wrappedValue.end ?? cursor : range?.wrappedValue.start ?? cursor
                if direction == .increment { set(frames.adjacent(to: cursor, by: 1)) }
                if direction == .decrement { set(frames.adjacent(to: cursor, by: -1)) }
                keepVisible()
            }
            .accessibilityIdentifier(isEnd ? "shot-range-end-handle" : "shot-range-start-handle")
    }
    private func endpoint(_ label: String, time: Double, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label).font(.system(size: 10)).foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.6))
                Text(ShotSourceFrames.label(time)).font(.system(size: 12, weight: .medium)).monospacedDigit()
            }.frame(maxWidth: .infinity).padding(9)
                .background(selected ? SessionStyle.mint.opacity(0.09) : .white.opacity(0.04), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? SessionStyle.mint.opacity(0.6) : .clear, lineWidth: 1) }
        }.buttonStyle(.plain).accessibilityIdentifier("shot-range-" + label.lowercased())
    }
    private func stepButton(_ delta: Int) -> some View {
        Button { set(frames.adjacent(to: cursor, by: delta)); keepVisible() } label: {
            Label(delta < 0 ? "−1 frame" : "+1 frame", systemImage: delta < 0 ? "backward.end" : "forward.end")
                .font(.system(size: 11, weight: .medium)).frame(minHeight: 32)
        }.buttonStyle(.glass).accessibilityIdentifier(delta < 0 ? "shot-frame-previous" : "shot-frame-next")
            .disabled(delta < 0 ? cursor <= frames.nearest(minimum) : cursor >= frames.last)
    }
    private func set(_ requested: Double) {
        var t = frames.nearest(max(minimum, requested))
        if t < minimum { t = frames.adjacent(to: t, by: 1) }
        if let range {
            var value = range.wrappedValue
            if editingEnd { t = max(frames.adjacent(to: value.start, by: 1), t); value.end = t }
            else { t = min(frames.adjacent(to: value.end, by: -1), t); value.start = t }
            range.wrappedValue = value
        }
        cursor = t; onSeek(t)
    }
    private func keepVisible() { if cursor < start || cursor > end { center = cursor } }
    private func changeZoom(_ value: Double) { zoom = min(32, max(1, value)); pinchZoom = zoom; center = cursor }
    private func thumbnails() async {
        let requested = stamps
        pictures = Array(repeating: nil, count: requested.count)
        guard let source else { return }
        let owner = ShotSourceImageGenerator(source: source)
        let generator = owner.generator
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 120, height: 120)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        await withTaskCancellationHandler {
            for (i, stamp) in requested.enumerated() {
                guard !Task.isCancelled else { return }
                let image = try? await generator.image(at: CMTime(seconds: stamp + 0.000001, preferredTimescale: 1_800_000_000)).image
                guard !Task.isCancelled else { return }
                pictures[i] = image
            }
        } onCancel: { Task { @MainActor in owner.cancel() } }
    }
}

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

struct ShotCameraTargetEditor: View {
    let edit: ShotCameraSpatialEdit
    @Binding var point: ShotCameraPoint
    @Binding var zoom: Double
    let lensRadius: Double
    @State private var initialZoom: Double?
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let lens = edit == .lensPosition
            let radius = min(size.width, size.height) * lensRadius
            ZStack {
                Color.clear.contentShape(.rect)
                if lens {
                    Circle().strokeBorder(SessionStyle.mint, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: point.x * size.width, y: point.y * size.height)
                } else {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(SessionStyle.mint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: edit == .lensArea ? 60 : size.width / max(1, zoom), height: edit == .lensArea ? 60 : size.height / max(1, zoom))
                        .position(x: point.x * size.width, y: point.y * size.height)
                    Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(SessionStyle.mint)
                        .position(x: point.x * size.width, y: point.y * size.height)
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let rx = lens ? radius / max(1, size.width) : 0
                let ry = lens ? radius / max(1, size.height) : 0
                point = ShotCameraPoint(x: min(1 - rx, max(rx, value.location.x / max(1, size.width))),
                                        y: min(1 - ry, max(ry, value.location.y / max(1, size.height))))
            })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if initialZoom == nil { initialZoom = zoom }
                zoom = min(edit == .lensArea || lens ? 6 : 3, max(1, (initialZoom ?? zoom) * value.magnification))
            }.onEnded { _ in initialZoom = nil })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(edit.title).accessibilityIdentifier("shot-target-preview")
            .accessibilityAction(named: Text("Move left")) { point.x = max(0, point.x - 0.03) }
            .accessibilityAction(named: Text("Move right")) { point.x = min(1, point.x + 0.03) }
            .accessibilityAction(named: Text("Move up")) { point.y = max(0, point.y - 0.03) }
            .accessibilityAction(named: Text("Move down")) { point.y = min(1, point.y + 0.03) }
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
