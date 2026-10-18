#if DEBUG && BALL_DETECTION_DEBUG
import AVFoundation
import Combine
import SwiftUI

/// Separate entry point: opening this build starts only the camera diagnostic.
@main
struct BallDetectionDebugApp: App {
    /// Projector window and landscape lock for the wall-targets experiment.
    @UIApplicationDelegateAdaptor(WallTargetsAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            #if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--wall-targets-preview") {
                WallTargetsPreviewScene()
            } else {
                BallDetectionDebugView()
            }
            #else
            BallDetectionDebugView()
            #endif
        }
    }
}

struct BallDetectionDebugView: View {
    @StateObject private var camera = BallDetectionDebugCamera()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showWallTargets = ProcessInfo.processInfo.arguments.contains("--wall-targets")

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ball Detection Debug")
                    .font(.headline)
                Spacer()
                Button("Wall targets") { showWallTargets = true }
                    .buttonStyle(.bordered)
            }
            .padding()
            BallDetectionDebugPreview(session: camera.session)
                .accessibilityLabel("Live camera preview")
            Text(camera.status)
                .font(.title3.weight(.semibold))
                .foregroundStyle(camera.ballDetected ? Color.green : Color.white)
                .multilineTextAlignment(.center)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: 100)
                .accessibilityIdentifier("ball-detection-status")
        }
        .background(.black)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active && !showWallTargets { camera.start() } else { camera.stop() }
        }
        // Only one capture session can run; the wall screen owns the camera while open.
        .onChange(of: showWallTargets) { _, showing in
            if showing { camera.stop() } else if scenePhase == .active { camera.start() }
        }
        .fullScreenCover(isPresented: $showWallTargets) { WallTargetsView() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification,
                                                         object: camera.session)) { _ in
            camera.stop(message: "Camera interrupted")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification,
                                                         object: camera.session)) { _ in
            if scenePhase == .active && !showWallTargets { camera.start() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification,
                                                         object: camera.session)) { _ in
            camera.stop(message: "Camera unavailable")
        }
        .onDisappear { camera.stop() }
    }
}

/// Configuration and inference share one serial queue. AVCapture drops late
/// frames instead of queuing predictions; UI publications belong to MainActor.
/// Sendability is checked through that ownership: mutable capture/detector state
/// stays on queue, and lifecycle requests crossing queues are lock-protected.
nonisolated private final class BallDetectionDebugCamera: NSObject, ObservableObject,
    AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    @MainActor @Published private(set) var status = "Starting camera…"
    @MainActor @Published private(set) var ballDetected = false
    @MainActor private var request: CaptureRequest?

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.juggledude.ball-detection-debug", qos: .userInitiated)
    // Accessed only on queue.
    private var activeRequest: CaptureRequest?
    private var detector: BallDetector?
    private var configured = false

    @MainActor
    func start() {
        guard request == nil else { return }
        let next = CaptureRequest()
        request = next
        ballDetected = false
        status = "Starting camera…"
        Task {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
            default: allowed = false
            }
            guard request === next, !next.isCancelled else { return }
            guard allowed else {
                status = "Allow camera access in Settings to detect a ball."
                request = nil
                return
            }
            queue.async { [self] in
                guard !next.isCancelled else { return }
                activeRequest = next
                do {
                    if !configured { try configure() }
                    guard !next.isCancelled else { return }
                    publish("Loading detector…", request: next)
                    session.startRunning()
                    guard session.isRunning else { throw CameraError.unavailable }
                    if detector == nil {
                        detector = try BallDetector(resourceName: BallDetector.productionResourceName,
                            useROI: false, useMarginalRetry: false, useDirectConfirmation: false)
                    }
                    publish("No ball detected", request: next)
                } catch {
                    session.stopRunning()
                    activeRequest = nil
                    publish(error is CameraError ? "Camera unavailable" : "Unable to load the ball detector",
                            request: next)
                }
            }
        }
    }

    @MainActor
    func stop(message: String = "Camera paused") {
        request?.cancel()
        request = nil
        ballDetected = false
        status = message
        queue.async { [self] in
            session.stopRunning()
            activeRequest = nil
            detector = nil
        }
    }

    private enum CameraError: Error { case unavailable }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // A failed setup can be retried when the app becomes active again.
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CameraError.unavailable }
        guard let input = try? AVCaptureDeviceInput(device: device) else { throw CameraError.unavailable }
        guard session.canAddInput(input) else { throw CameraError.unavailable }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.unavailable }
        session.addOutput(output)
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90)
        else { throw CameraError.unavailable }
        connection.videoRotationAngle = 90
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let current = activeRequest, !current.isCancelled, let detector,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            do {
                let detected = try detector.detectsBall(in: pixels)
                publish(detected ? "Ball is detected" : "No ball detected", detected: detected, request: current)
            } catch {
                publish("Ball detection unavailable", request: current)
            }
        }
    }

    private func publish(_ message: String, detected: Bool = false, request current: CaptureRequest) {
        Task { @MainActor [weak self] in
            guard let self, self.request === current, !current.isCancelled else { return }
            if self.status != message { self.status = message }
            if self.ballDetected != detected { self.ballDetected = detected }
        }
    }
}

private struct BallDetectionDebugPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        // Show the entire analysed frame, including its edges.
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) { view.setNeedsLayout() }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
#endif
