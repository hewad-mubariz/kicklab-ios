import SwiftUI

nonisolated struct CaptureMotionPoint: Equatable {
    let time: Double
    let y: Double?
    var x: Double? = nil
}

/// Shared live/review readouts, calculated from confirmed touch timestamps.
nonisolated struct CaptureRhythm: Equatable {
    let interval: Double?
    let perMinute: Double?

    init(touchTimes: [Double], at time: Double) {
        let times = touchTimes.filter { $0.isFinite && $0 >= 0 && $0 <= time }.sorted().suffix(5)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0.05 }
        interval = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        perMinute = interval.map { 60 / $0 }
    }
    var intervalLabel: String { interval.map { String(format: "%.2fs", $0) } ?? "—" }
    var rhythmLabel: String { perMinute.map { String(format: "%.0f / min", $0) } ?? "—" }
}

enum JugglingSessionIdentity {
    private static let key = "kicklab.juggling.sessionNumber"
    static func next(in defaults: UserDefaults = .standard) -> Int { max(1, defaults.integer(forKey: key) + 1) }
    @discardableResult static func begin(in defaults: UserDefaults = .standard) -> Int {
        let number = next(in: defaults); defaults.set(number, forKey: key); return number
    }
    static func label(_ number: Int) -> String { String(format: "SESSION %02d", max(1, number)) }
}

struct CaptureSessionBadge: View {
    let number: Int
    var recording = false
    var preparing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "circle.fill").font(.system(size: 7))
                .foregroundStyle(recording ? .red : SessionStyle.mint)
                .symbolEffect(.pulse, options: .repeat(.continuous), isActive: recording && !reduceMotion)
            // The state word slides in ahead of the name; the glass capsule grows to fit.
            if recording || preparing {
                Text(recording ? "REC ·" : "STARTING ·")
                    .contentTransition(.interpolate)
                    .transition(.sessionTuck(.leading))
            }
            Text(JugglingSessionIdentity.label(number))
        }
        .font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1)
        .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: recording)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: preparing)
        .accessibilityElement(children: .combine).accessibilityIdentifier("capture-session-name")
    }
}

struct CaptureTouchCounter: View {
    let count: Int
    var warn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var increments = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(NormalCounterAppearance.label(count))
                    .font(.custom(NormalCounterAppearance.fontName, size: NormalCounterAppearance.fontSize(count, base: 84)))
                    .monospacedDigit().foregroundStyle(warn ? Theme.warn : Color(cgColor: NormalCounterAppearance.white))
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: count)
                    .sessionKick(increments, amount: 0.08, anchor: .leading)
                // Each counted touch floats a +1 up and away.
                Text("+1").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                    .keyframeAnimator(initialValue: FloatingIncrement(), trigger: increments) { [reduceMotion] label, value in
                        label.offset(y: reduceMotion ? 0 : value.rise).opacity(value.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.rise) {
                            LinearKeyframe(8, duration: 0.01)
                            SpringKeyframe(-4, duration: 0.24, spring: .snappy)
                            CubicKeyframe(-16, duration: 0.36)
                        }
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.06)
                            LinearKeyframe(1, duration: 0.26)
                            CubicKeyframe(0, duration: 0.29)
                        }
                    }
            }
            Text("TOUCHES").font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) touches").accessibilityIdentifier("capture-touch-counter")
        .onChange(of: count) { old, new in
            if new > old { increments += 1 }
        }
    }
}

private struct FloatingIncrement {
    var rise: CGFloat = 0
    var opacity: Double = 0
}

struct CaptureMetrics: View {
    let points: [CaptureMotionPoint]
    let touchTimes: [Double]
    let time: Double
    var duration: Double? = nil
    var showGraph = true
    var showTime = true
    var motionStyle: MotionStyle = .ballMotion
    var motionTimeline: MotionStyleTimeline? = nil
    var sourceAspect: CGFloat = 9.0 / 16.0
    var showsTouchMetrics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let snapshot = motionStyle == .ballMotion ? nil
            : (motionTimeline ?? MotionStyleTimeline(points: points, touchTimes: touchTimes)).snapshot(at: time, duration: duration)
        let graph = snapshot?.graph ?? CaptureGraphLayout(points: points, time: time, duration: duration)
        VStack(alignment: .leading, spacing: 12) {
            if showGraph {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(motionStyle.title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1)
                        Text(motionStyle.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(graph.status).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                        Text(motionStyle.measure).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                Group {
                    if motionStyle == .ballMotion {
                        CaptureMotionGraph(layout: graph, touchTimes: touchTimes)
                    } else if let snapshot {
                        MotionStyleGraph(style: motionStyle, snapshot: snapshot, sourceAspect: sourceAspect)
                    }
                }.frame(height: motionStyle.height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(motionStyle.title + ": " + motionStyle.subtitle)
                    .accessibilityValue(motionStyle.rawValue)
                    .accessibilityIdentifier("capture-motion-graph")
                Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            }
            let rhythm = CaptureRhythm(touchTimes: touchTimes, at: time)
            HStack(spacing: 12) {
                if showsTouchMetrics {
                metric("RHYTHM", value: rhythm.perMinute.map { String(format: "%.0f", $0) } ?? "—",
                       unit: rhythm.perMinute == nil ? nil : "/ min", alignment: .leading)
                metric("TOUCH INTERVAL", value: rhythm.intervalLabel, alignment: .leading)
                }
                if showTime {
                    metric("TIME", value: ExportPreviewTime.label(at: time), alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func metric(_ title: String, value: String, unit: String? = nil, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .medium)).tracking(0.5)
                .foregroundStyle(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: title == "TIME" ? 21 : 24, weight: title == "TIME" ? .semibold : .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
                if let unit { Text(unit).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65)) }
            }
        }.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(title == "TIME" ? "capture-elapsed-time" : "capture-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

}
