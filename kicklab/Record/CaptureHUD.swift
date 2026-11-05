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
    static func label(_ number: Int) -> String {
        String(localized: "SESSION \(String(format: "%02d", max(1, number)))", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }
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
        .appGlass(in: .capsule)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: recording)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: preparing)
        .accessibilityElement(children: .combine).accessibilityIdentifier("capture-session-name")
    }
}

/// Big enough to read from where the player stands, because they can't come to the phone to check.
struct CaptureStreakWarning: View {
    let warning: LiveAbsenceWarning

    private var title: String {
        switch warning.subject {
        case .player: String(localized: "Player out of view", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .ball: String(localized: "Ball out of view", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
    private var detail: String {
        warning.secondsLeft > 0
            ? String(localized: "Streak is about to end", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
            : String(localized: "New streak when you continue", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if warning.secondsLeft > 0 {
                    Text(warning.secondsLeft, format: .number).font(.system(size: 44, weight: .bold)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                } else {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 28, weight: .bold))
                }
            }
            .foregroundStyle(Theme.warn).frame(minWidth: 40, minHeight: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 18, weight: .semibold))
                Text(detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
            }
            .lineLimit(2).minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 8)
        // Glass alone washes out against bright sky or a white shirt.
        .background(.black.opacity(0.45), in: .capsule)
        .appGlass(in: .capsule)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine).accessibilityIdentifier("capture-streak-warning")
    }
}

struct CaptureTouchCounter: View {
    let count: Int
    var warn = false
    @State private var incrementCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                Text(NormalCounterAppearance.label(count))
                    .font(.custom(NormalCounterAppearance.fontName, size: NormalCounterAppearance.fontSize(count, base: 84)))
                    .monospacedDigit().foregroundStyle(warn ? Theme.warn : Color(cgColor: NormalCounterAppearance.white))
                // The free Normal counter flashes +1 beside its unchanged digits.
                Text("+1").font(.custom("HelveticaNeue-Medium", size: 13))
                    .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                    .keyframeAnimator(initialValue: 0.0, trigger: incrementCount) { [showIncrement = incrementCount == count] label, opacity in
                        label.opacity(showIncrement ? opacity : 0)
                    } keyframes: { _ in
                        LinearKeyframe(1, duration: 0.01)
                        LinearKeyframe(0, duration: 0.3)
                    }
            }
            Text("TOUCHES").font(.system(size: 10, weight: .medium)).tracking(1.7).foregroundStyle(.white)
        }
        // Confirmed counts update immediately, including during an animated HUD change.
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) touches").accessibilityIdentifier("capture-touch-counter")
        .onChange(of: count) { old, new in
            incrementCount = new > old ? new : nil
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
    var motionStyle: MotionStyle = .ballMotion
    var motionTimeline: MotionStyleTimeline? = nil
    var sourceAspect: CGFloat = 9.0 / 16.0
    var showsTouchMetrics = true

    var body: some View {
        // Replay brings the session's timeline, so a long session scrolls; live keeps its last six seconds.
        let timeline = motionTimeline ?? (motionStyle == .ballMotion ? nil : MotionStyleTimeline(points: points, touchTimes: touchTimes))
        let snapshot = motionStyle == .ballMotion ? nil : timeline?.snapshot(at: time, duration: duration)
        let graph = snapshot?.graph ?? timeline?.graph(at: time, duration: duration)
            ?? CaptureGraphLayout(points: points, time: time, duration: duration)
        VStack(alignment: .leading, spacing: 12) {
            if showGraph {
                MotionGraphHeader(style: motionStyle, graph: graph)
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
                if showsTouchMetrics { CaptureRhythmMetrics(rhythm: rhythm) }
                if showTime {
                    CaptureMetricValue(title: "TIME", id: "time", value: ExportPreviewTime.label(at: time), alignment: .trailing)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

/// What a motion graph plots, and which way the ball is moving when it plots height.
struct MotionGraphHeader: View {
    let style: MotionStyle
    let graph: CaptureGraphLayout

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(style.title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1)
                Text(style.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let status = style.status(graph) {
                    Text(status).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(cgColor: NormalCounterAppearance.lime))
                }
                Text(style.measure).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}

/// Rhythm and touch interval, the same under the replay and inside a saved video.
struct CaptureRhythmMetrics: View {
    let rhythm: CaptureRhythm

    var body: some View {
        CaptureMetricValue(title: "RHYTHM", id: "rhythm", value: rhythm.perMinute.map { String(format: "%.0f", $0) } ?? "—",
                           unit: rhythm.perMinute == nil ? nil : "/ min", alignment: .leading)
        CaptureMetricValue(title: "TOUCH INTERVAL", id: "touch-interval", value: rhythm.intervalLabel, alignment: .leading)
    }
}

struct CaptureMetricValue: View {
    let title: LocalizedStringKey
    let id: String
    let value: String
    var unit: LocalizedStringKey? = nil
    let alignment: HorizontalAlignment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isTime = id == "time"
        VStack(alignment: alignment, spacing: 6) {
            Text(title).font(.system(size: 9, weight: .medium)).tracking(0.5)
                .foregroundStyle(.white.opacity(0.72)).lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: isTime ? 21 : 24, weight: isTime ? .semibold : .bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
                if let unit { Text(unit).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.65)) }
            }
        }.frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(isTime ? "capture-elapsed-time" : "capture-\(id)")
    }

}
