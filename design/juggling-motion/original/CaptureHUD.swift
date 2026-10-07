import SwiftUI

nonisolated struct CaptureMotionPoint: Equatable {
    let time: Double
    let y: Double?
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

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(recording ? .red : SessionStyle.mint).frame(width: 7, height: 7)
            Text((recording ? "REC · " : preparing ? "STARTING · " : "") + JugglingSessionIdentity.label(number))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit().lineLimit(1)
        }
        .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine).accessibilityIdentifier("capture-session-name")
    }
}

struct CaptureTouchCounter: View {
    let count: Int
    var warn = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previousCount: Int?
    @State private var showIncrement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(NormalCounterAppearance.label(count))
                    .font(.custom(NormalCounterAppearance.fontName, size: NormalCounterAppearance.fontSize(count, base: 84)))
                    .monospacedDigit().foregroundStyle(warn ? Theme.warn : Color(cgColor: NormalCounterAppearance.white))
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: count)
                Text("+1").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime)).opacity(showIncrement ? 1 : 0)
            }
            Text("TOUCHES").font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) touches").accessibilityIdentifier("capture-touch-counter")
        .task(id: count) {
            let increased = previousCount.map { count > $0 } ?? false
            previousCount = count
            showIncrement = increased
            guard increased else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { showIncrement = false }
        }
    }
}

struct CaptureMetrics: View {
    let points: [CaptureMotionPoint]
    let touchTimes: [Double]
    let time: Double
    var duration: Double? = nil
    var showGraph = true
    var showTime = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let graph = CaptureGraphLayout(points: points, time: time, duration: duration)
        VStack(alignment: .leading, spacing: 12) {
            if showGraph {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BALL MOTION").font(.system(size: 10, weight: .medium)).tracking(1)
                        Text("Vertical position").font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(graph.status).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                        Text("RELATIVE").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    }
                }
                CaptureMotionGraph(layout: graph, touchTimes: touchTimes).frame(height: 62)
                    .accessibilityLabel(duration == nil ? "Relative ball motion over the last six seconds" : "Relative ball motion through the session")
                    .accessibilityIdentifier("capture-motion-graph")
                Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
            }
            let rhythm = CaptureRhythm(touchTimes: touchTimes, at: time)
            HStack(spacing: 12) {
                metric("RHYTHM", value: rhythm.perMinute.map { String(format: "%.0f", $0) } ?? "—",
                       unit: rhythm.perMinute == nil ? nil : "/ min", alignment: .leading)
                metric("TOUCH INTERVAL", value: rhythm.intervalLabel, alignment: .leading)
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
