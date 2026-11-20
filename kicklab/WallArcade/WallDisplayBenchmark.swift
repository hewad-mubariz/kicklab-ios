#if WALL_GAMES_PREVIEW
import AVFoundation
import Combine
import SwiftUI

nonisolated struct WallDelayReport: Codable, Sendable {
    private(set) var schema = 1
    let id: UUID
    let date: Date
    let connection: String
    let device: String
    let os: String
    let build: String
    let thermalStart: Int
    let thermalEnd: Int
    let roi: [Double]
    let exposureLocked: Bool
    let valid: Bool
    let outcome: String
    let dark: Double?
    let bright: Double?
    let commands: [WallDisplayBenchmarkEngine.Command]
    let samples: [WallDisplayBenchmarkEngine.Sample]
    let observations: [WallDelayObservation]
    private(set) var method = "App UI state submission to first camera frame above 65% of calibrated contrast, confirmed by a second frame. Capture PTS converted from AVCaptureSession.synchronizationClock to CMClockGetHostTimeClock. Not pure network latency or photon onset."
    private(set) var uncertainty = "Includes app presentation, transmission, projector processing, camera exposure, rolling shutter and frame sampling. lastDark/firstBright bracket the sampled threshold transition, not exact photon onset. Compare the same projector, ROI, camera settings and load. Ball inference is paused."

    var values: [Double] { samples.compactMap(\.milliseconds) }
    var median: Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return (sorted[(sorted.count-1)/2]+sorted[sorted.count/2])/2
    }
    var p95: Double? { WallDisplayBenchmarkEngine.percentile(values, 0.95) }
    var frameInterval: Double? {
        WallDisplayBenchmarkEngine.percentile(zip(observations.dropFirst(), observations).map {
            ($0.captureTime-$1.captureTime)*1000
        }, 0.5)
    }
}

@MainActor final class WallDisplayBenchmark: ObservableObject {
    static let shared = WallDisplayBenchmark()
    @Published private(set) var presented = false
    @Published private(set) var running = false
    @Published private(set) var cameraChecking = false
    @Published private(set) var lit = true
    @Published private(set) var message = "Tap the projected white patch in the camera view."
    @Published private(set) var report: WallDelayReport?
    @Published private(set) var savedURL: URL?
    @Published private(set) var saveError: String?
    @Published var point = CGPoint(x: 0.5, y: 0.5)
    @Published var pointSelected = false
    @Published var connection = "Wireless"
    private weak var camera: WallTargetsCamera?
    private var engine: WallDisplayBenchmarkEngine?
    private var watchdog: Task<Void, Never>?
    private var identity = UUID()
    private var locked = false
    private var thermalStart = 0
    private var latestCapture: Double?
    private var started = Date()
    private var startedConnection = "Wireless"
    private var startedPoint = CGPoint.zero
    private static var now: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func open(camera: WallTargetsCamera) {
        close()
        self.camera = camera
        presented = true; lit = true; pointSelected = false
        report = nil; savedURL = nil; saveError = nil
        message = "Tap the projected white patch in the camera view."
        preview()
    }

    func select(_ point: CGPoint) {
        guard !running else { return }
        self.point = CGPoint(x: min(0.96, max(0.04, point.x)), y: min(0.96, max(0.04, point.y)))
        pointSelected = true
        preview()
    }

    func preview() {
        guard presented, !running, let camera else { return }
        cameraChecking = true
        lit = true
        let id = identity
        camera.setDelayProbe(at: point) { [weak self] frame in
            guard let self, self.presented, self.identity == id else { return }
            self.latestCapture = frame.captureTime
            guard self.running, self.engine != nil else { return }
            self.engine?.receive(frame, now: Self.now)
            self.publish()
        }
        camera.setFramingPreview(true)
    }

    func start() {
        guard presented, !running, pointSelected, let camera else { return }
        guard let latestCapture, Self.now-latestCapture < 0.3 else {
            message = "No live camera frames. Wait for the camera, then try again."; return
        }
        engine = nil
        running = true; report = nil; savedURL = nil; saveError = nil
        started = Date(); startedConnection = connection; startedPoint = point
        thermalStart = ProcessInfo.processInfo.thermalState.rawValue
        message = "Locking exposure…"
        let id = identity
        watchdog = Task { [weak self] in
            let locked = await camera.lockDelayExposure()
            guard let self, !Task.isCancelled, self.identity == id, self.running else { return }
            self.locked = locked
            guard locked else {
                self.message = "Could not lock camera exposure. Close this test and retry."
                self.running = false; self.stopCamera(); return
            }
            self.engine = WallDisplayBenchmarkEngine(at: Self.now)
            self.publish()
            while !Task.isCancelled, self.running {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, self.identity == id, self.running else { break }
                self.engine?.advance(to: Self.now)
                self.publish()
            }
        }
    }

    private func publish() {
        guard let engine else { return }
        if lit != engine.lit { lit = engine.lit }
        if message != engine.message { message = engine.message }
        if engine.finished { finish(engine) }
    }

    func stop() {
        if var engine, !engine.finished {
            engine.cancel(at: Self.now)
            self.engine = engine
            message = engine.message
            finish(engine)
        } else {
            running = false; watchdog?.cancel(); watchdog = nil
            stopCamera()
            if presented { message = "Camera paused. Reopen the camera check to measure." }
        }
        lit = false
    }

    func close() { stop(); presented = false; camera = nil; pointSelected = false }

    private func stopCamera() {
        cameraChecking = false
        identity = UUID() // Ignore any main-queue observations already in flight.
        latestCapture = nil
        camera?.setDelayProbe(at: point, receive: nil)
        camera?.setFramingPreview(false)
    }

    func retry() {
        guard presented, !running else { return }
        engine = nil; message = "Check the patch, then run another test."
        preview()
    }

    private func finish(_ engine: WallDisplayBenchmarkEngine) {
        guard running else { return }
        running = false; watchdog?.cancel(); watchdog = nil
        stopCamera()
        let report = WallDelayReport(id: UUID(), date: started, connection: startedConnection,
            device: UIDevice.current.model, os: UIDevice.current.systemVersion,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            thermalStart: thermalStart, thermalEnd: ProcessInfo.processInfo.thermalState.rawValue,
            roi: [startedPoint.x, startedPoint.y, 0.04, 0.04], exposureLocked: locked,
            valid: engine.valid, outcome: engine.message, dark: engine.dark, bright: engine.bright,
            commands: engine.commands, samples: engine.samples, observations: engine.observations)
        self.report = report
        Task { [weak self] in
            do {
                let url = try await Task.detached(priority: .utility) {
                    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("DisplayBenchmarks", isDirectory: true)
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let stamp = ISO8601DateFormatter().string(from: report.date).replacingOccurrences(of: ":", with: "-")
                    let url = root.appendingPathComponent("\(stamp)-\(report.id.uuidString.prefix(8)).json")
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(to: url, options: .atomic)
                    return url
                }.value
                if self?.report?.id == report.id { self?.savedURL = url }
            } catch {
                if self?.report?.id == report.id { self?.saveError = "Could not save evidence: \(error.localizedDescription)" }
            }
        }
    }
}

struct WallDelayOpticalPatch: View {
    @ObservedObject var benchmark: WallDisplayBenchmark
    var body: some View {
        ZStack {
            Color.black
            Rectangle().fill(benchmark.lit ? Color.white : Color.black)
                .padding(20)
            Rectangle().stroke(.gray, lineWidth: 1).padding(19)
        }.transaction { $0.animation = nil }
            .accessibilityLabel(benchmark.lit ? "Measurement patch white" : "Measurement patch dark")
    }
}

struct WallDisplayBenchmarkView: View {
    @ObservedObject var benchmark: WallDisplayBenchmark
    @ObservedObject var camera: WallTargetsCamera
    let onBack: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        GeometryReader { geo in
                if geo.size.width > 650 && !typeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 24) {
                        signal(height: geo.size.height*0.53).frame(width: (geo.size.width-68)*0.48)
                        ScrollView { controls.frame(maxWidth: .infinity) }
                    }.padding(22)
                } else {
                    VStack(spacing: 12) {
                        signal(height: geo.size.height*0.24)
                        ScrollView { controls }
                    }.padding(16)
                }
        }.foregroundStyle(.white).background(WallArcadeStyle.background)
            .accessibilityIdentifier("arcade-optical-benchmark")
    }
    private func signal(height: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Keep the patch fixed even when controls scroll or results appear.
            // Otherwise a mirrored projector would move out of the selected ROI.
            WallDelayOpticalPatch(benchmark: benchmark).frame(height: height)
            Text("APP → WALL · CAMERA MEASURED").font(.caption.bold()).foregroundStyle(WallArcadeStyle.lime)
            Text("12 flashes · usually 20–40 seconds. Keep the phone still and the wall clear.")
                .font(.caption).foregroundStyle(.white.opacity(0.75))
            Button("Back to visual test", action: onBack).buttonStyle(.glass).tint(.white)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if benchmark.running {
                Text("MEASURING YOUR WALL").font(WallArcadeStyle.display(26))
                ProgressView().tint(WallArcadeStyle.lime)
                Text(benchmark.message).font(.headline)
                Text("Camera preview hidden while measuring. Ball detection is paused.").font(.caption)
                Button("Stop test", systemImage: "stop.fill") { benchmark.stop() }.buttonStyle(.glass).tint(.white)
            } else if let report = benchmark.report {
                results(report)
            } else {
                Text("MEASURE DISPLAY DELAY").font(WallArcadeStyle.display(26))
                Picker("Connection used", selection: $benchmark.connection) {
                    Text("Wireless").tag("Wireless"); Text("Cable").tag("Cable")
                }.pickerStyle(.segmented)
                cameraPicker.frame(maxWidth: 230)
                Text(benchmark.message).font(.caption)
                if !benchmark.cameraChecking {
                    Button("Reopen camera check") { benchmark.retry() }
                        .buttonStyle(.glass).tint(.white).font(.caption)
                }
#if targetEnvironment(simulator)
                Text("Measurement needs the iPhone camera and a real projector.")
                    .font(.caption.bold()).foregroundStyle(.orange)
#else
                Button("Measure 12 flashes", systemImage: "waveform.path") { benchmark.start() }
                    .buttonStyle(.glassProminent).tint(WallArcadeStyle.lime).foregroundStyle(TrainingHomeStyle.buttonInk)
                    .disabled(!benchmark.pointSelected || !camera.isReady)
                    .accessibilityIdentifier("arcade-benchmark-start")
#endif
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cameraPicker: some View {
        GeometryReader { geo in
            WallArcadeCameraView(camera: camera)
                .overlay {
                    Rectangle().stroke(WallArcadeStyle.lime, lineWidth: 2)
                        .frame(width: geo.size.width*0.04, height: geo.size.height*0.04)
                        .position(x: benchmark.point.x*geo.size.width, y: benchmark.point.y*geo.size.height)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard camera.isReady else { return }
                    benchmark.select(CGPoint(x: location.x/geo.size.width, y: location.y/geo.size.height))
                }
        }.aspectRatio(16/9, contentMode: .fit)
    }
    private func results(_ report: WallDelayReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(report.valid ? "\(Int((report.median ?? 0).rounded())) ms" : "CHECK THE PATCH")
                .font(WallArcadeStyle.display(46)).foregroundStyle(WallArcadeStyle.lime)
            Text(report.valid ? "Median app-to-wall response · \(report.connection)" : report.outcome).font(.headline)
            if report.valid, let p95 = report.p95, let low = report.values.min(), let high = report.values.max() {
                Text("Range \(Int(low.rounded()))–\(Int(high.rounded())) ms · p95 \(Int(p95.rounded())) ms").font(.subheadline)
            }
            Text("\(report.values.count) / 12 detected · \(report.samples.filter { $0.status != "detected" }.count) rejected or missed")
                .font(.caption)
            if let interval = report.frameInterval {
                Text("Camera samples ≈ every \(Int(interval.rounded())) ms. Exposure and rolling shutter add uncertainty.")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            Text("Includes rendering, transmission, projector and camera timing. Run 3 times per connection with the same setup. This is a display-only test, not kick-to-hit latency.")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            HStack {
                Button("New measurement") { benchmark.clearForRetry() }.buttonStyle(.glass).tint(.white)
                if let url = benchmark.savedURL {
                    ShareLink(item: url) { Label("Evidence", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glass).tint(.white)
                }
            }
            Text(benchmark.saveError ?? (benchmark.savedURL == nil ? "Saving evidence…" : "Evidence saved on this iPhone."))
                .font(.caption2).foregroundStyle(benchmark.saveError == nil ? .white.opacity(0.6) : .orange)
        }
    }
}

extension WallDisplayBenchmark {
    func clearForRetry() {
        report = nil; savedURL = nil; saveError = nil
        retry()
    }
}
#endif
