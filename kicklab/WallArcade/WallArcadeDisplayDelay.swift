#if WALL_GAMES_PREVIEW
import Combine
import QuartzCore
import SwiftUI

/// One source clock for both windows. These are submitted UI values, never an
/// acknowledgement from the projector or a measurement of its photon latency.
@MainActor final class WallArcadeDisplayDelay: NSObject, ObservableObject {
    static let shared = WallArcadeDisplayDelay()
    enum Mode { case tap, sequence }
    struct Frame: Equatable {
        var run = 0
        var milliseconds = 0
        var pulse = 0
        var lit = false
    }
    @Published private(set) var presented = false
    @Published private(set) var running = false
    @Published private(set) var frame = Frame()
    private var mode = Mode.tap
    private var startTime: CFTimeInterval = 0
    private var link: CADisplayLink?

    func open() {
        stop()
        frame = Frame()
        presented = true
    }

    func close() {
        stop()
        WallDisplayBenchmark.shared.close()
        presented = false
    }

    func start(_ mode: Mode, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard presented else { return }
        stop()
        self.mode = mode
        startTime = time
        frame = Frame(run: frame.run + 1, milliseconds: 0, pulse: 1, lit: true)
        running = true
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) { advance(to: CACurrentMediaTime()) }

    /// Use elapsed monotonic time, not frame count: dropped frames must not make
    /// either window's source clock run slow or turn into an apparent measurement.
    func advance(to time: CFTimeInterval) {
        guard running else { return }
        let duration: Double = mode == .tap ? 3 : 10
        let elapsed = min(duration, max(0, time - startTime))
        let milliseconds = max(frame.milliseconds, Int((elapsed * 1_000).rounded(.down)))
        let pulse = mode == .tap ? 1 : min(10, milliseconds / 1_000 + 1)
        let lit = elapsed < duration && (mode == .tap ? elapsed < 0.4 : milliseconds % 1_000 < 250)
        frame = Frame(run: frame.run, milliseconds: milliseconds, pulse: pulse, lit: lit)
        if elapsed >= duration { stop() }
    }

    func stop() {
        WallDisplayBenchmark.shared.stop()
        link?.invalidate()
        link = nil
        running = false
        if frame.lit { frame.lit = false }
    }
}

/// Shared on the phone and external window; mirroring also carries these exact
/// rendered values. Never give the external window its own TimelineView/clock.
struct WallArcadeDelaySurface: View {
    @ObservedObject var test: WallArcadeDisplayDelay
    @ObservedObject private var benchmark = WallDisplayBenchmark.shared
    var body: some View {
        if benchmark.presented {
            WallDelayOpticalPatch(benchmark: benchmark)
        } else {
        GeometryReader { geo in
            let h = geo.size.height
            VStack(spacing: h * 0.035) {
                Text(test.frame.run == 0 ? "READY" : "TEST \(test.frame.run) · FLASH \(test.frame.pulse)")
                    .font(.system(size: h * 0.09, weight: .bold, design: .monospaced))
                Text(String(format: "%05d", test.frame.milliseconds))
                    .font(.system(size: h * 0.34, weight: .black, design: .monospaced))
                    .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                    .accessibilityIdentifier("arcade-delay-clock")
                Text("TEST CLOCK · MILLISECONDS")
                    .font(.system(size: h * 0.065, weight: .bold, design: .monospaced))
            }.padding(h * 0.08).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(test.frame.lit ? Color.black : Color.white)
                .background(test.frame.lit ? Color.white : Color.black)
        }
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("arcade-delay-surface")
        }
    }
}

struct WallArcadeDelayControls: View {
    @ObservedObject var test: WallArcadeDisplayDelay
    @ObservedObject var camera: WallTargetsCamera
    @ObservedObject private var benchmark = WallDisplayBenchmark.shared
    let separateDisplay: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if benchmark.presented {
            WallDisplayBenchmarkView(benchmark: benchmark, camera: camera) { benchmark.close() }
        } else {
        GeometryReader { geo in
            ScrollView {
                if geo.size.width >= 650 && !typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 24) {
                        signal.frame(width: (geo.size.width - 68) * 0.51)
                        controls.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(22)
                } else {
                    VStack(alignment: .leading, spacing: 20) { signal; controls }.padding(22)
                }
            }
        }.background(WallArcadeStyle.background).foregroundStyle(.white)
            .accessibilityIdentifier("arcade-delay-test")
        }
    }

    private var signal: some View {
        VStack(alignment: .leading, spacing: 10) {
            WallArcadeDelaySurface(test: test).aspectRatio(16/9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.35)))
            Text(separateDisplay ? "Compare this clock with the wall." : "Connect Screen Mirroring or a cable to compare with the wall.")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            Text("The clock is not a measured delay.").font(.caption.bold()).foregroundStyle(WallArcadeStyle.lime)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW QUICK IS YOUR WALL?").font(WallArcadeStyle.display(28))
            Button("Measure with camera", systemImage: "camera.metering.center.weighted") {
                test.stop()
                benchmark.open(camera: camera)
            }.buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                .accessibilityIdentifier("arcade-benchmark-open")
            Text("Get 12 measured flashes and saved timing evidence using this phone’s rear camera.")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 12) {
                Button("Tap to flash", systemImage: "hand.tap") { test.start(.tap) }
                    .buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                    .accessibilityIdentifier("arcade-delay-flash")
                Button(test.running ? "Stop" : "Run 10 seconds", systemImage: test.running ? "stop.fill" : "play.fill") {
                    if test.running { test.stop() } else { test.start(.sequence) }
                }.buttonStyle(.glass).tint(.white).accessibilityIdentifier("arcade-delay-run")
            }
            Text("Tap and watch both screens flash. For a closer comparison, run the 10-second test and film both screens together with another phone.")
            Text("Pause that video while the clocks are running. Phone time minus wall time estimates the wall’s extra delay. Repeat with the cable.")
                .foregroundStyle(.white.opacity(0.75))
            Text("Example: phone 01200 − wall 01000 ≈ 200 ms. Readings update roughly every 17–33 ms. This checks display delay; ball detection is paused.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
        }.font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
