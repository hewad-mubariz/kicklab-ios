#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Combine
import ImageIO
import SwiftUI

/// Explicit developer-only component study. Saved images are model/encoder
/// inputs; the live camera remains at the production cadence in every phase.
/// Never forwards synthetic input to scoring, calibration or the training archive.
@MainActor final class WallThermalStudy: ObservableObject {
    static let requested = ProcessInfo.processInfo.arguments.contains("--wall-thermal-study")
    static let shared = WallThermalStudy()
    @Published private(set) var phase = "Preparing comparison"
    @Published private(set) var graphics = false
    @Published private(set) var phaseStarted = Date()
    private let worker = WallThermalStudyWorker()
    private var task: Task<Void, Never>?

    func start() {
        guard Self.requested, task == nil else { return }
        WallTargetsAppDelegate.lock(.landscapeRight)
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                guard await AVCaptureDevice.requestAccess(for: .video) else { throw StudyError.camera }
                try await worker.prepare()
                // Give Instruments time to attach. No model or encoder work yet.
                phase = "Waiting for profiler"
                try await Task.sleep(for: .seconds(15))
                var phases = WallThermalStudyWorker.Phase.all
                if ProcessInfo.processInfo.arguments.contains("--wall-study-reverse") { phases.reverse() }
                for next in phases {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.thermalState.rawValue < 2 else { throw StudyError.hot }
                    phase = next.name; graphics = next.graphics; phaseStarted = Date()
                    WallPowerMonitor.shared.setContext("thermal-study-" + next.name)
                    try await worker.run(next)
                }
                phase = "Comparison saved"
            } catch { phase = "Comparison stopped: \(error)"; await worker.noteFailure(String(describing: error)) }
            graphics = false
            await worker.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
    func cancel() { task?.cancel() }
    nonisolated enum StudyError: Error { case camera, hot, input, writer }
}

struct WallThermalStudyView: View {
    @ObservedObject private var study = WallThermalStudy.shared
    @Environment(\.scenePhase) private var scenePhase
    var external = false
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
            if study.graphics {
                TimelineView(.animation(minimumInterval: 1 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSince(study.phaseStarted).truncatingRemainder(dividingBy: 10)
                    let state = WallMemoryStrike(seed: 17)
                    WallMemoryBoard(state: state, time: t)
                }
                .padding(50)
            }
            Text("THERMAL COMPARISON · \(study.phase)")
                .font(.system(size: 18, weight: .bold)).foregroundStyle(.white).padding(12)
        }
        .ignoresSafeArea().statusBarHidden()
        .task { if !external { study.start() } }
        .onDisappear { if !external { study.cancel() } }
        .onChange(of: scenePhase) { _, state in if !external && state == .background { study.cancel() } }
    }
}

nonisolated private final class WallThermalStudyWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    nonisolated struct Phase: Sendable {
        let name: String
        var modelFPS = 0.0
        var videoFPS = 0.0
        var graphics = false
        static let all: [Phase] = [
            .init(name: "capture"), .init(name: "video60", videoFPS: 60),
            .init(name: "video15", videoFPS: 15), .init(name: "model30", modelFPS: 30),
            .init(name: "model15", modelFPS: 15),
            .init(name: "model30-video60", modelFPS: 30, videoFPS: 60),
            .init(name: "model30-video15", modelFPS: 30, videoFPS: 15),
            .init(name: "graphics", graphics: true),
            .init(name: "graphics-model30-video15", modelFPS: 30, videoFPS: 15, graphics: true)
        ]
    }
    private let queue = DispatchQueue(label: "com.juggledude.wall-thermal-study", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WallThermalStudy")
    private var output: URL!
    private var images: [CVPixelBuffer] = []
    private var detector: BallDetector?
    private var crop = CGRect.zero
    private var phase: Phase?
    private var start = 0.0
    private var lastModel = -Double.infinity, lastVideo = -Double.infinity
    private var frames = 0, modelCalls = 0, videoFrames = 0
    private var modelMS = 0.0, appendMS = 0.0
    private var samples: [[String: Any]] = [], summaries: [[String: Any]] = []
    private var lastSample = -Double.infinity
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var failure: String?

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    output = root.appendingPathComponent("run-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    let source = root.appendingPathComponent("input")
                    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("input.json"))) as? [String: Any],
                          let names = json["files"] as? [String], names.count <= 12 else { throw WallThermalStudy.StudyError.input }
                    for name in names {
                        guard let imageSource = CGImageSourceCreateWithURL(source.appendingPathComponent(name) as CFURL, nil),
                              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { throw WallThermalStudy.StudyError.input }
                        var pixels: CVPixelBuffer?
                        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
                              let pixels else { throw WallThermalStudy.StudyError.input }
                        CVPixelBufferLockBaseAddress(pixels, [])
                        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                        CVPixelBufferUnlockBaseAddress(pixels, [])
                        images.append(pixels)
                    }
                    guard !images.isEmpty else { throw WallThermalStudy.StudyError.input }
                    guard let points = json["corners"] as? [[Double]], points.count == 4,
                          points.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { throw WallThermalStudy.StudyError.input }
                    let corners = points.map { CGPoint(x: $0[0], y: $0[1]) }
                    guard let boardCrop = WallBallTracker.crop(corners: corners, size: CGSize(width: CVPixelBufferGetWidth(images[0]), height: CVPixelBufferGetHeight(images[0]))) else { throw WallThermalStudy.StudyError.input }
                    crop = boardCrop
                    detector = try BallDetector(resourceName: BallDetector.productionResourceName, useROI: false, useMarginalRetry: false, useDirectConfirmation: false)
                    try detector!.warmUp()
                    try configureCamera()
                    session.startRunning()
                    saveReport(status: "ready")
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
    }

    private func configureCamera() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw WallThermalStudy.StudyError.camera }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw WallThermalStudy.StudyError.camera }
        session.addInput(input)
        let data = AVCaptureVideoDataOutput(); data.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        data.alwaysDiscardsLateVideoFrames = true; data.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(data) else { throw WallThermalStudy.StudyError.camera }
        session.addOutput(data)
        _ = try CaptureFrameRate.configure(camera)
        try camera.lockForConfiguration()
        camera.activeMaxExposureDuration = CMTime(seconds: max(camera.activeFormat.minExposureDuration.seconds, 1 / 240.0), preferredTimescale: 1_000_000)
        camera.unlockForConfiguration()
    }

    func run(_ next: Phase) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    frames = 0; modelCalls = 0; videoFrames = 0; modelMS = 0; appendMS = 0; failure = nil
                    lastModel = -.infinity; lastVideo = -.infinity; lastSample = -.infinity
                    start = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    if next.videoFPS > 0 {
                        let w = try AVAssetWriter(outputURL: output.appendingPathComponent(next.name + ".mov"), fileType: .mov)
                        let i = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: 1280, AVVideoHeightKey: 720, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
                        i.expectsMediaDataInRealTime = true; w.add(i)
                        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
                        guard w.startWriting() else { throw WallThermalStudy.StudyError.writer }
                        w.startSession(atSourceTime: CMTime(seconds: start, preferredTimescale: 1_000_000))
                        writer = w; input = i
                    }
                    phase = next
                    c.resume()
                } catch { c.resume(throwing: error) }
            }
        }
        do { try await Task.sleep(for: .seconds(14)) }
        catch { await finishPhase(); throw error }
        await finishPhase()
        if ProcessInfo.processInfo.thermalState.rawValue >= 2 { throw WallThermalStudy.StudyError.hot }
    }

    private func finishPhase() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let phase {
                    summaries.append(["phase": phase.name, "startUptime": start, "endUptime": ProcessInfo.processInfo.systemUptime,
                        "frames": frames, "modelCalls": modelCalls, "videoFrames": videoFrames, "modelMS": modelMS, "appendMS": appendMS,
                        "thermal": ProcessInfo.processInfo.thermalState.rawValue, "error": failure as Any? ?? NSNull()])
                }
                phase = nil
                let finishing = writer
                input?.markAsFinished(); writer = nil; input = nil; adaptor = nil
                saveReport(status: "running")
                if let finishing { finishing.finishWriting { c.resume() } }
                else { c.resume() }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let phase, let detector, !images.isEmpty else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        // Reuse bounded real image surfaces; their contents never change while an
        // encoder or model owns them. Each phase sees the same repeating sequence.
        let pixels = images[max(0, Int((time - start) * 30)) % images.count]
        frames += 1
        if ProcessInfo.processInfo.thermalState.rawValue >= 2 { return }
        if phase.modelFPS > 0, time - lastModel >= 1 / phase.modelFPS - 0.001 {
            lastModel = time
            let began = ProcessInfo.processInfo.systemUptime
            do { _ = try autoreleasepool { try detector.wallTargetCandidates(in: pixels, crop: crop) }; modelCalls += 1 }
            catch { failure = String(describing: error) }
            modelMS += (ProcessInfo.processInfo.systemUptime - began) * 1000
        }
        if phase.videoFPS > 0, time - lastVideo >= 1 / phase.videoFPS - 0.001, input?.isReadyForMoreMediaData == true {
            let began = ProcessInfo.processInfo.systemUptime
            if adaptor?.append(pixels, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) == true { videoFrames += 1; lastVideo = time }
            appendMS += (ProcessInfo.processInfo.systemUptime - began) * 1000
        }
        if time - lastSample >= 1 {
            lastSample = time
            samples.append(["phase": phase.name, "uptime": time, "wallTime": Date().timeIntervalSince1970,
                "elapsed": time - start, "frames": frames, "modelCalls": modelCalls, "videoFrames": videoFrames,
                "modelMS": modelMS, "appendMS": appendMS, "memoryMiB": DetectorPerformance.memoryMB(),
                "thermal": ProcessInfo.processInfo.thermalState.rawValue])
        }
    }

    func noteFailure(_ message: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in failure = message; saveReport(status: "stopped"); c.resume() }
        }
    }
    func stop() async {
        await finishPhase()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { [self] in session.stopRunning(); images = []; detector = nil; saveReport(status: failure == nil ? "completed" : "stopped"); c.resume() }
        }
    }
    private func saveReport(status: String) {
        guard let output else { return }
        let report: [String: Any] = ["status": status, "summaries": summaries, "samples": samples,
            "build": Bundle.main.object(forInfoDictionaryKey: "WallEnduranceBuild") as Any? ?? NSNull(),
            "error": failure as Any? ?? NSNull(), "method": "Component comparison: live 720p60 camera, bounded repeatable saved-image inputs, production RF board-crop model calls and H264 12Mbps encoder. Model-only includes crop and decoding, not hand pose, alignment, full-frame recovery or hit logic. Graphics uses production Memory Strike views. No scoring/training output. Ignore first 3s of each phase; use profiler for GPU/power, elapsed timers are not watts."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
        }
    }
}
#endif
