import ARKit
import AVFoundation
import Combine
import CoreImage
import SceneKit
import SwiftUI
import UIKit

/// Research capture, opened from Power Shot or --shot-geometry-capture.
/// Raw sensor pixels, frame timestamps, calibration and poses are saved together.
/// Does not replace the normal camera, detector, counter, or speed UI.
@MainActor
final class ShotGeometryCapture: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    @Published private(set) var recording = false
    @Published private(set) var finishing = false
    @Published private(set) var ready = false
    @Published private(set) var status = "Preparing camera"
    @Published private(set) var groundStatus = "Map the ground around the resting ball"
    @Published private(set) var files: [URL] = []
    @Published private(set) var rollDistanceEnabled = true
    @Published private(set) var rollDisplay = ShotRollDisplay()
    @Published private(set) var rollFloors: [ShotRollFloorChoice] = []
    @Published private(set) var selectedRollFloorID: String?
    @Published private(set) var calibrationSnapshot: ShotRollCalibrationSnapshot?
    @Published private(set) var rollCalibration: ShotRollCalibration?
    @Published private(set) var calibrationStatus = "Use two tape-measured paper centres to calibrate this setup."
    @Published private(set) var calibrationNeedsRetry = false
    private var calibrationPNG: Data?
    private var recordingCalibration: ShotRollCalibration?
    private let rollDetector = ShotRollDetector()
    private var rollGeneration = 0
    private var rollBusy = false
    private var lastRollSubmission = -Double.infinity
    private var lastFloorPublish = -Double.infinity
    private var rollTracker = ShotRollTracker()
    private var rollLatest: ShotRollObservation?
    private var lockedRollFloor: ShotRollFloor?
    private var lockedRollCamera: simd_float4x4?
    private var rollLog: FileHandle?
    private var rollEnabledForRecording = false
    private var rollSamples = 0
    private var rollTrial = 0
    private var rollModel = "Not loaded"
    private var rollFloorChosenByUser = false
    private var rollPreviewActive = false
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var log: FileHandle?
    private var directory: URL?
    private var origin: Double?
    private var lastTimestamp = -Double.infinity
    private var saved = 0
    private var dropped = 0
    private var limited = 0
    private var dimensions: [Int] = []
    private var groundReadiness = ShotGeometryReadiness()
    private var groundReadyFrames = 0
    private var preserveFailureStatus = false
    private var recordedAt = Date()
    private var backgroundSave: UIBackgroundTaskIdentifier = .invalid

    func prepare() async {
        rollPreviewActive = false
        ready = false
        groundReadiness.reset()
        resetRollExperiment()
        clearRollCalibration()
        rollFloors = []; selectedRollFloorID = nil
        rollFloorChosenByUser = false; lastFloorPublish = -.infinity
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--roll-distance-ui-review") {
            status = "Interface preview"; groundStatus = "No camera or model is running in this preview"
            if ProcessInfo.processInfo.arguments.contains("--roll-distance-ui-waiting") {
                rollDisplay.status = "Finding the ball — keep it visible"
            } else if ProcessInfo.processInfo.arguments.contains("--roll-distance-ui-ready") {
                ready = true; rollDisplay.canSetStart = true
                rollDisplay.status = "Ball found — record, then tap Set start"
            } else {
                rollDisplay.distanceM = 1.23; rollDisplay.status = "Tracking the roll • scale unverified"
                rollDisplay.isLive = true
            }
            if ProcessInfo.processInfo.arguments.contains("--roll-speed-ui-fixture") {
                rollDisplay.calibrated = true
                rollDisplay.speedKMH = 2.6; rollDisplay.peakRollingSpeedKMH = 2.8
                rollDisplay.speedStatus = "Smoothed rolling estimate"
                if ProcessInfo.processInfo.arguments.contains("--roll-speed-ui-stopped") {
                    rollDisplay.isLive = false; rollDisplay.speedKMH = nil
                    rollDisplay.speedStatus = "Recording stopped"
                }
            }
            rollFloors = [ShotRollFloorChoice(id: "preview-a", cameraHeightM: 0.84),
                          ShotRollFloorChoice(id: "preview-b", cameraHeightM: 1.0)]
            selectedRollFloorID = "preview-a"
            if ProcessInfo.processInfo.arguments.contains("--roll-calibration-ui-fixture") { ready = true }
            if ProcessInfo.processInfo.arguments.contains("--roll-calibration-ui-invalidated") {
                ready = true; calibrationNeedsRetry = true
                calibrationStatus = "Camera angle changed — calibrate again"
                rollDisplay.distanceM = 0.000431
                rollDisplay.markCalibrationLost(calibrationRecoveryMessage)
            }
            return
        }
        #endif
        guard ARWorldTrackingConfiguration.isSupported else {
            status = "World tracking is unavailable on this device"; return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            status = "Camera access is required"; return
        }
        // The menu presentation may close while camera permission is pending.
        guard !Task.isCancelled else { return }
        session.delegate = self
        session.delegateQueue = .main
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        config.planeDetection = [.horizontal]
        // Preserve actual frame timestamps; no frame-rate conversion is applied.
        rollPreviewActive = true
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func begin() {
        guard canBeginRecording, !recording, !finishing else { return }
        do {
            let base = ShotRecordingStore.root
            let folder = base.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let path = folder.appendingPathComponent("frames.jsonl")
            guard FileManager.default.createFile(atPath: path.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            log = try FileHandle(forWritingTo: path)
            directory = folder
            // The preview has already loaded the single detector. Keep it warm
            // so recording does not spend its first seconds loading the model.
            resetRollExperiment(releaseDetector: false)
            rollEnabledForRecording = rollDistanceEnabled
            recordingCalibration = rollEnabledForRecording ? rollCalibration : nil
            if rollEnabledForRecording {
                let distancePath = folder.appendingPathComponent("roll-distance.jsonl")
                guard FileManager.default.createFile(atPath: distancePath.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                rollLog = try FileHandle(forWritingTo: distancePath)
                try writeRollEvent(["event": "begin", "schema": "kicklab.roll-distance.v1",
                    "method": "sphere_tangent_box_ground_contact_displacement",
                    "model_resource": BallDetector.configuredResourceName,
                    "physical_scale_verified": false, "ground_contact_verified": false,
                    "rolling_speed_method": "capture_timestamp_0.6s_contact_linear_fit",
                    "rolling_speed_window_s": ShotRollSpeedEstimator.windowS,
                    "rolling_speed_physical_scale_verified": false,
                    "note": "Experimental distance from start, not path length or launch speed."])
                if let calibration = recordingCalibration, let png = calibrationPNG {
                    try png.write(to: folder.appendingPathComponent("roll-calibration.png"), options: .atomic)
                    try writeRollEvent(calibrationEvent(calibration))
                    rollDisplay.calibrated = true
                }
                rollDisplay.status = "Finding the ball…"
            }
            saved = 0; dropped = 0; limited = 0; groundReadyFrames = 0; origin = nil
            lastTimestamp = -.infinity; dimensions = []; files = []
            preserveFailureStatus = false
            recordedAt = Date()
            recording = true
            status = "Recording — hold the phone steady"
        } catch { abort(); showFailure("Could not start: \(error.localizedDescription)") }
    }

    private func showFailure(_ message: String) {
        status = message
        // Camera callbacks continue after a writer failure. Keep the explanation
        // visible until the user deliberately starts a fresh recording.
        preserveFailureStatus = true
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // This session explicitly delivers callbacks on the main queue.
        MainActor.assumeIsolated { consume(frame) }
    }

    private func consume(_ frame: ARFrame) {
        let normal: Bool
        switch frame.camera.trackingState {
        case .normal: normal = true
        default: normal = false
        }
        let anchors = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }
        let cameraPosition = SIMD3<Float>(frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        let surfaces = anchors.map { plane in
            let transform = plane.transform
            let normal = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y,
                                      transform.columns.1.z)
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y,
                                        transform.columns.3.z)
            let vertices = plane.geometry.boundaryVertices
            var twiceArea: Float = 0
            if vertices.count >= 3 {
                for i in vertices.indices {
                    let a = vertices[i], b = vertices[(i + 1) % vertices.count]
                    twiceArea += a.x * b.z - b.x * a.z
                }
            }
            return ShotGeometryReadiness.Surface(id: plane.identifier.uuidString,
                normal: normal, offset: simd_dot(position, normal),
                cameraHeight: simd_dot(cameraPosition - position, normal),
                area: abs(twiceArea) / 2)
        }
        ready = groundReadiness.update(time: frame.timestamp,
            trackingNormal: normal, surfaces: surfaces)
        updateRollFloors(frame, anchors: anchors)
        validateRollCalibration(frame, anchors: anchors)
        if rollDistanceEnabled, !normal {
            if recording, rollTracker.origin != nil { rollTracker.invalidate() }
            rollDisplay.isLive = false; rollDisplay.canSetStart = false
            rollDisplay.speedKMH = nil; rollDisplay.peakRollingSpeedKMH = nil
            rollDisplay.speedStatus = "Speed paused — camera tracking lost"
            rollDisplay.sensorContact = nil; rollDisplay.sensorBallRect = nil
            rollDisplay.status = recording ? "Camera tracking lost — set start again"
                : "Camera tracking settling — keep the resting ball visible"
        }
        if recording, rollDistanceEnabled,
           let observed = rollDisplay.sampleTimestamp, frame.timestamp - observed > 0.35 {
            rollDisplay.speedKMH = nil
            rollDisplay.speedStatus = "Speed paused — waiting for the ball"
        }
        if rollDistanceEnabled,
           rollDisplay.isLive || rollDisplay.canSetStart,
           let observed = rollDisplay.sampleTimestamp, frame.timestamp - observed > 0.5 {
            rollDisplay.isLive = false; rollDisplay.canSetStart = false
            rollDisplay.sensorContact = nil; rollDisplay.sensorBallRect = nil
            rollDisplay.status = "Waiting for the ball — holding last estimate"
        }
        groundStatus = !normal ? "Move gently until camera tracking settles" :
            ready ? "Ground mapped — keep the resting ball visible" :
            "Slowly scan the ground around the resting ball"
        if !recording {
            if normal, rollPreviewActive, rollDistanceEnabled, !finishing {
                submitRollFrame(frame, anchors: anchors, sourceFrame: nil)
            }
            if !finishing, files.isEmpty, !preserveFailureStatus {
                status = ready ? "Ready — record one shot" : "Preparing ground measurement"
            }
            return
        }
        guard let directory, let log else { return }
        guard frame.timestamp > lastTimestamp else { dropped += 1; return }
        if let origin, frame.timestamp-origin >= 15 { stop(); return }
        do {
            let pixels = frame.capturedImage
            let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
            if writer == nil {
                let next = try AVAssetWriter(outputURL: directory.appendingPathComponent("video.mov"),
                                             fileType: .mov)
                let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width, AVVideoHeightKey: height,
                ])
                track.expectsMediaDataInRealTime = true
                // Identity transform: K and pixel coordinates refer to these raw pixels.
                let bridge = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: track,
                    sourcePixelBufferAttributes: nil)
                guard next.canAdd(track) else { throw CocoaError(.fileWriteUnknown) }
                next.add(track)
                guard next.startWriting() else { throw next.error ?? CocoaError(.fileWriteUnknown) }
                next.startSession(atSourceTime: CMTime(seconds: frame.timestamp,
                                                       preferredTimescale: 1_000_000_000))
                writer = next; input = track; adaptor = bridge
                origin = frame.timestamp; dimensions = [width, height]
            }
            guard dimensions == [width, height] else { throw CocoaError(.fileWriteUnknown) }
            guard let input, input.isReadyForMoreMediaData, let adaptor else {
                dropped += 1; return
            }
            guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: frame.timestamp,
                                  preferredTimescale: 1_000_000_000)) else {
                throw writer?.error ?? CocoaError(.fileWriteUnknown)
            }
            let camera = frame.camera
            guard Int(camera.imageResolution.width) == width,
                  Int(camera.imageResolution.height) == height else {
                throw CocoaError(.fileWriteUnknown)
            }
            // ARKit camera axes: right, up, backward. Convert to right, down, forward.
            var cvToAR = matrix_identity_float4x4
            cvToAR[1][1] = -1; cvToAR[2][2] = -1
            let pose = camera.transform * cvToAR
            let planes: [[String: Any]] = anchors
                .filter { $0.alignment == .horizontal }
                .map { (plane: ARPlaneAnchor) -> [String: Any] in
                    let boundary: [[Float]] = plane.geometry.boundaryVertices.map { point in
                        return [point.x, point.y, point.z]
                    }
                    return ["id": plane.identifier.uuidString,
                     "world_from_plane": Self.rows(plane.transform),
                     "boundary_vertices_local_m": boundary,
                     "center_local_m": [plane.center.x, plane.center.y, plane.center.z],
                     "extent_m": [plane.planeExtent.width, plane.planeExtent.height]]
                }
            let row: [String: Any] = [
                "frame": saved, "time_s": frame.timestamp-(origin ?? frame.timestamp),
                "capture_timestamp_s": frame.timestamp, "image_size": dimensions,
                "intrinsics": (0..<3).map { r in (0..<3).map { Double(camera.intrinsics[$0][r]) } },
                "world_from_camera": Self.rows(pose),
                "tracking_state": normal ? "normal" : "limited_or_unavailable",
                "horizontal_planes": planes,
            ]
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(10)
            try log.write(contentsOf: data)
            lastTimestamp = frame.timestamp; saved += 1
            if !normal { limited += 1 }
            if ready { groundReadyFrames += 1 }
            if normal, rollEnabledForRecording {
                submitRollFrame(frame, anchors: anchors, sourceFrame: saved - 1)
            }
        } catch {
            showFailure("Capture failed: \(error.localizedDescription)")
            abort()
        }
    }

    private static func rows(_ matrix: simd_float4x4) -> [[Double]] {
        (0..<4).map { r in (0..<4).map { Double(matrix[$0][r]) } }
    }

    private func abort() {
        recording = false; finishing = false
        rollGeneration += 1; rollDetector.release()
        try? rollLog?.close(); rollLog = nil
        rollDisplay.isLive = false; rollDisplay.canSetStart = false
        rollDisplay.speedKMH = nil; rollDisplay.peakRollingSpeedKMH = nil
        rollDisplay.speedStatus = "Recording interrupted"
        writer?.cancelWriting(); writer = nil; input = nil; adaptor = nil
        try? log?.close(); log = nil
        // A partial capture has no manifest and is never offered for analysis.
        files = []
        endBackgroundSave()
    }

    private func endBackgroundSave() {
        if backgroundSave != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundSave)
            backgroundSave = .invalid
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        guard let writer, let directory, saved > 0 else {
            abort(); showFailure("No video frames were saved"); return
        }
        finishing = true
        status = "Saving video and measurement data…"
        // Keep this one model warm for another trial in the same preview.
        rollGeneration += 1
        rollDisplay.isLive = false; rollDisplay.canSetStart = false
        rollDisplay.status = calibrationNeedsRetry ? calibrationRecoveryMessage : "Last estimate — test stopped"
        rollDisplay.speedKMH = nil; rollDisplay.speedStatus = "Recording stopped"
        backgroundSave = UIApplication.shared.beginBackgroundTask(withName: "Save Power Shot") { [weak self] in
            Task { @MainActor in self?.endBackgroundSave() }
        }
        input?.markAsFinished()
        do {
            try log?.synchronize(); try log?.close(); log = nil
            if rollEnabledForRecording {
                var event: [String: Any] = ["event": "end", "trial": rollTrial,
                    "sample_count": rollSamples, "physical_scale_verified": false]
                if let distance = rollDisplay.distanceM { event["last_distance_from_start_m"] = distance }
                if let peak = rollDisplay.peakRollingSpeedKMH { event["peak_rolling_speed_kmh"] = peak }
                event["rolling_speed_physical_scale_verified"] = false
                try writeRollEvent(event)
            }
            try rollLog?.synchronize(); try rollLog?.close(); rollLog = nil
        }
        catch { abort(); showFailure("Measurement data could not be saved: \(error.localizedDescription)"); return }
        let count = saved, skipped = dropped, bad = limited, size = dimensions
        let mapped = groundReadyFrames
        let firstTime = origin ?? 0
        let rollFile = rollEnabledForRecording ? directory.appendingPathComponent("roll-distance.jsonl") : nil
        let rollCount = rollSamples, rollTrials = rollTrial, detectorName = rollModel
        let lastRollDistance = rollDisplay.distanceM
        let peakRollingSpeed = rollDisplay.peakRollingSpeedKMH
        let calibration = recordingCalibration
        let calibrationImage = calibration.map { _ in directory.appendingPathComponent("roll-calibration.png") }
        let date = ISO8601DateFormatter().string(from: recordedAt)
        let footprint = DetectorRecordingReview.memory()
        writer.finishWriting { [self] in
            Task { @MainActor in
                defer {
                    self.writer = nil; self.input = nil; self.adaptor = nil
                    self.finishing = false
                    self.endBackgroundSave()
                }
                guard self.writer?.status == .completed else {
                    self.showFailure("Video export failed"); return
                }
                do {
                    let video = directory.appendingPathComponent("video.mov")
                    let frames = directory.appendingPathComponent("frames.jsonl")
                    let manifest = directory.appendingPathComponent("manifest.json")
                    let hashes = try await Task.detached(priority: .userInitiated) {
                        (try ShotRecordingStore.hash(video), try ShotRecordingStore.hash(frames),
                         try rollFile.map { try ShotRecordingStore.hash($0) },
                         try calibrationImage.map { try ShotRecordingStore.hash($0) })
                    }.value
                    var data: [String: Any] = [
                        "schema": "kicklab.shot-geometry.v1", "video": "video.mov",
                        "recorded_at": date,
                        "frames": "frames.jsonl", "recorded_frames": count,
                        "writer_dropped_frames": skipped, "limited_tracking_frames": bad,
                        "ground_ready_frames": mapped,
                        "ground_readiness": "At least one level surface >=1 m2, camera height 0.3-3 m, stable for 0.5 s. Ball contact/coverage unverified.",
                        "image_size": size, "source_origin_s": firstTime,
                        "coordinate_system": "opencv_camera_to_arkit_gravity_world",
                        "gravity_world_m_s2": [0, -9.80665, 0], "video_transform": "identity",
                        "video_sha256": hashes.0,
                        "frames_sha256": hashes.1,
                        "note": "Research capture only. AR geometry and any experimental rolling estimates require physical validation. Launch speed is not measured.",
                    ]
                    if let hash = hashes.2 {
                        data["roll_distance"] = "roll-distance.jsonl"
                        data["roll_distance_sha256"] = hash
                        data["roll_distance_sample_count"] = rollCount
                        data["roll_distance_trial_count"] = rollTrials
                        data["roll_distance_model"] = detectorName
                        data["roll_distance_physical_scale_verified"] = false
                        data["roll_distance_ground_contact_verified"] = false
                        if let lastRollDistance { data["roll_distance_last_estimate_m"] = lastRollDistance }
                        data["roll_speed_method"] = "capture_timestamp_0.6s_contact_linear_fit"
                        data["roll_speed_physical_scale_verified"] = false
                        if let peakRollingSpeed { data["roll_speed_peak_estimate_kmh"] = peakRollingSpeed }
                    }
                    if let hash = hashes.3, let calibration {
                        data["roll_calibration_image"] = "roll-calibration.png"
                        data["roll_calibration_image_sha256"] = hash
                        data["roll_calibration_id"] = calibration.id
                        data["roll_calibration_reference_distance_m"] = calibration.referenceDistanceM
                        data["roll_calibration_independently_verified"] = false
                    }
                    if let footprint {
                        data["stop_app_bytes"] = footprint.current
                        data["kernel_lifetime_peak_bytes"] = footprint.peak
                        data["within_300_MB"] = footprint.peak <= 300_000_000
                        data["memory_note"] = "Kernel lifetime peak at capture stop, before export hashing; not a recording-only delta."
                    }
                    try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
                        .write(to: manifest, options: .atomic)
                    self.files = [video, frames, manifest] + (rollFile.map { [$0] } ?? []) + (calibrationImage.map { [$0] } ?? [])
                    self.status = bad == 0 ? "Saved to Saved shots — video + data" :
                        "Saved to Saved shots. Camera tracking was limited during this shot."
                } catch { self.showFailure("Metadata export failed: \(error.localizedDescription)") }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            showFailure("Camera tracking failed: \(error.localizedDescription)")
            ready = false
            invalidateRollCalibration("Camera tracking failed — calibrate again")
            // A finished movie may still be hashing/writing its manifest.
            // A later camera failure must not cancel or overwrite that save.
            if recording { abort() }
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        MainActor.assumeIsolated {
            ready = false; groundReadiness.reset()
            invalidateRollCalibration("Camera interrupted — calibrate again")
            stop()
        }
    }
}

nonisolated struct ShotRollFloorChoice: Identifiable, Equatable, Sendable {
    let id: String
    let cameraHeightM: Float
}

private struct ShotRollObservation {
    let sourceFrame: Int
    let timestamp: Double
    let camera: simd_float4x4
    let floor: ShotRollFloor
    let projection: ShotRollGeometry.Projection
}

extension ShotGeometryCapture {
    var canCalibrateRoll: Bool {
        rollDistanceEnabled && !recording && !finishing && ready && selectedRollFloorID != nil
    }

    func beginRollCalibration() {
        guard canCalibrateRoll else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--roll-calibration-ui-fixture") {
            calibrationSnapshot = calibrationInterfaceFixture()
            return
        }
        #endif
        guard let frame = session.currentFrame, case .normal = frame.camera.trackingState,
              let anchor = frame.anchors.compactMap({ $0 as? ARPlaneAnchor })
                .first(where: { $0.identifier.uuidString == selectedRollFloorID }) else {
            calibrationStatus = "Wait for the floor and camera tracking to settle"; return
        }
        var cvToAR = matrix_identity_float4x4
        cvToAR[1][1] = -1; cvToAR[2][2] = -1
        let camera = frame.camera.transform * cvToAR
        let rotation = ShotRollRotation.upright(worldFromCamera: camera)
        let pixels = CIImage(cvPixelBuffer: frame.capturedImage)
        guard let image = CIContext().createCGImage(pixels, from: pixels.extent),
              let png = UIImage(cgImage: image).pngData() else {
            calibrationStatus = "Could not freeze the photo — try again"; return
        }
        let orientation: UIImage.Orientation
        switch rotation {
        case .up: orientation = .up
        case .right: orientation = .right
        case .down: orientation = .down
        case .left: orientation = .left
        }
        rollGeneration += 1
        rollFloorChosenByUser = true
        calibrationSnapshot = ShotRollCalibrationSnapshot(
            image: UIImage(cgImage: image, scale: 1, orientation: orientation), png: png,
            imageSize: frame.camera.imageResolution, rotation: rotation,
            intrinsics: frame.camera.intrinsics, camera: camera,
            floor: rollFloor(anchor), timestamp: frame.timestamp)
    }

    func cancelRollCalibration() { calibrationSnapshot = nil }

    func applyRollCalibration(_ calibration: ShotRollCalibration) throws {
        guard calibration.independentSpanCheck?.withinTolerance != false else {
            throw NSError(domain: "Kicklab.RollCalibration", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Scale mismatch in the measured gap. Retap the centres or scan the floor again."
            ])
        }
        guard let snapshot = calibrationSnapshot, !recording, !finishing else {
            throw ShotRollCalibration.FitError.correction
        }
        var valid = false
        #if DEBUG
        valid = ProcessInfo.processInfo.arguments.contains("--roll-calibration-ui-fixture")
        #endif
        if let frame = session.currentFrame, case .normal = frame.camera.trackingState,
           let anchor = frame.anchors.compactMap({ $0 as? ARPlaneAnchor })
            .first(where: { $0.identifier.uuidString == calibration.sourceFloor.id }) {
            var cvToAR = matrix_identity_float4x4
            cvToAR[1][1] = -1; cvToAR[2][2] = -1
            valid = calibration.matches(camera: frame.camera.transform * cvToAR, floor: rollFloor(anchor))
        }
        guard valid, selectedRollFloorID == calibration.sourceFloor.id else {
            throw NSError(domain: "Kicklab.RollCalibration", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Phone or floor changed while choosing points. Cancel and freeze a new photo."
            ])
        }
        rollGeneration += 1
        rollTracker.reset(); rollLatest = nil; lockedRollFloor = nil; lockedRollCamera = nil
        rollCalibration = calibration; calibrationPNG = snapshot.png; calibrationNeedsRetry = false
        rollFloorChosenByUser = true
        calibrationStatus = String(format: "%.2f m spacing applied • check separate 1 m and 2 m marks", calibration.referenceDistanceM)
        rollDisplay = ShotRollDisplay(); rollDisplay.calibrated = true
        calibrationSnapshot = nil
    }

    func clearRollCalibration() {
        guard !recording, !finishing else { return }
        rollGeneration += 1
        rollCalibration = nil; calibrationPNG = nil; calibrationSnapshot = nil; calibrationNeedsRetry = false
        calibrationStatus = "Use two tape-measured paper centres to calibrate this setup."
        rollDisplay = ShotRollDisplay(); rollTracker.reset(); rollLatest = nil
        lockedRollFloor = nil; lockedRollCamera = nil
    }

    private func invalidateRollCalibration(_ reason: String) {
        guard let calibration = rollCalibration else { return }
        rollCalibration = nil; calibrationPNG = nil; calibrationNeedsRetry = true
        calibrationStatus = reason
        rollTracker.invalidate(); rollLatest = nil
        rollDisplay.markCalibrationLost(calibrationRecoveryMessage)
        if recording {
            do {
                try writeRollEvent(["event": "calibration_invalidated", "calibration_id": calibration.id,
                    "capture_timestamp_s": session.currentFrame?.timestamp ?? calibration.timestamp,
                    "reason": reason, "physical_scale_verified": false])
            } catch { abort(); showFailure("Calibration change could not be saved") }
        }
    }

    private func validateRollCalibration(_ frame: ARFrame, anchors: [ARPlaneAnchor]) {
        guard let calibration = rollCalibration else { return }
        guard case .normal = frame.camera.trackingState,
              let anchor = anchors.first(where: { $0.identifier.uuidString == calibration.sourceFloor.id }) else {
            invalidateRollCalibration("Floor or camera tracking lost — calibrate again"); return
        }
        var cvToAR = matrix_identity_float4x4
        cvToAR[1][1] = -1; cvToAR[2][2] = -1
        if let change = calibration.change(camera: frame.camera.transform * cvToAR, floor: rollFloor(anchor)) {
            invalidateRollCalibration(change.message)
        }
    }

    private var calibrationRecoveryMessage: String {
        calibrationStatus + (recording ? ". Stop & save, then tap Recalibrate." : ". Tap Recalibrate before recording again.")
    }

    private func calibrationEvent(_ value: ShotRollCalibration) -> [String: Any] {
        var event: [String: Any] = ["event": "calibration", "schema": "kicklab.roll-calibration.v1", "calibration_id": value.id,
         "method": "measured_span_floor_offset", "capture_timestamp_s": value.timestamp,
         "reference_distance_m": value.referenceDistanceM, "uncalibrated_span_m": value.originalSpanM,
         "height_factor": value.heightFactor, "image": "roll-calibration.png",
         "image_size": [value.imageSize.width, value.imageSize.height],
         "sensor_points_normalized": value.sensorPoints.map { [$0.x, $0.y] },
         "intrinsics": (0..<3).map { r in (0..<3).map { Double(value.intrinsics[$0][r]) } },
         "world_from_camera": Self.rows(value.camera), "plane_id": value.sourceFloor.id,
         "source_world_from_plane": Self.rows(value.sourceFloor.worldFromPlane),
         "effective_world_from_plane": Self.rows(value.floor.worldFromPlane),
         "source_boundary_vertices_local_m": value.sourceFloor.boundary.map { [$0.x, $0.y, $0.z] },
         "camera_height_before_m": value.sourceFloor.cameraHeight(value.camera),
         "camera_height_after_m": value.floor.cameraHeight(value.camera),
         "physical_scale_verified": false, "ground_contact_verified": false,
         "independently_verified": false,
         "note": "Fitted using these two marks. Requires separate held-out distances; assumes a level floor and fixed camera."]
        if let check = value.independentSpanCheck {
            event["independent_span_check"] = [
                "sensor_points_normalized": check.sensorPoints.map { [$0.x, $0.y] },
                "reference_distance_m": check.referenceDistanceM, "estimated_distance_m": check.estimatedDistanceM,
                "error_m": check.errorM, "tolerance_m": check.toleranceM,
                "within_experimental_tolerance": check.withinTolerance, "physical_speed_accuracy_verified": false
            ] as [String: Any]
        }
        return event
    }

    #if DEBUG
    private func calibrationInterfaceFixture() -> ShotRollCalibrationSnapshot {
        let size = CGSize(width: 1920, height: 1440)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.darkGray.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 905, y: 1060, width: 110, height: 40))
            context.fill(CGRect(x: 920, y: 844, width: 80, height: 40))
        }
        var camera = matrix_identity_float4x4
        camera[1][1] = -1; camera[2][2] = -1; camera.columns.3.y = 0.84
        let floor = ShotRollFloor(id: "preview-a", worldFromPlane: matrix_identity_float4x4,
            boundary: [SIMD3(-5, 0, -10), SIMD3(5, 0, -10), SIMD3(5, 0, 1), SIMD3(-5, 0, 1)])
        let portraitPhoto = ProcessInfo.processInfo.arguments.contains("--roll-calibration-ui-portrait-photo")
        let shownImage = portraitPhoto ? UIImage(cgImage: image.cgImage!, scale: 1, orientation: .right) : image
        return ShotRollCalibrationSnapshot(image: shownImage, png: image.pngData()!, imageSize: size,
            rotation: portraitPhoto ? .right : .up,
            intrinsics: simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1))),
            camera: camera, floor: floor, timestamp: 100)
    }
    #endif

    var canChooseRollFloor: Bool { !recording || rollTracker.origin == nil || rollTracker.needsNewStart }
    var canBeginRecording: Bool {
        ready && calibrationSnapshot == nil &&
            (!rollDistanceEnabled || (!calibrationNeedsRetry && rollDisplay.canSetStart))
    }

    func pause() {
        calibrationSnapshot = nil
        rollPreviewActive = false
        stop()
        rollGeneration += 1; rollDetector.release()
        rollLatest = nil; rollDisplay.canSetStart = false; rollDisplay.isLive = false
        session.pause()
    }
    func setRollMode(_ enabled: Bool) {
        guard !recording, !finishing else { return }
        rollDistanceEnabled = enabled
        clearRollCalibration()
        resetRollExperiment()
    }

    func selectRollFloor(_ id: String) {
        guard !finishing, canChooseRollFloor else { return }
        if rollCalibration != nil { invalidateRollCalibration("Floor changed — calibrate again") }
        selectedRollFloorID = id; rollFloorChosenByUser = true
        rollLatest = nil; lockedRollFloor = nil; lockedRollCamera = nil
        rollDisplay.canSetStart = false
        rollDisplay.status = calibrationNeedsRetry ? calibrationRecoveryMessage : "Finding the ball on this floor…"
    }

    private func resetRollExperiment(releaseDetector: Bool = true) {
        rollGeneration += 1; lastRollSubmission = -.infinity
        // An outstanding request owns the slot until its callback, even when a
        // new recording invalidates its result. Never queue another frame here.
        if releaseDetector { rollDetector.release() }
        rollTracker.reset(); rollLatest = nil
        lockedRollFloor = nil; lockedRollCamera = nil
        rollDisplay = ShotRollDisplay(); rollSamples = 0; rollTrial = 0
        rollDisplay.calibrated = rollCalibration != nil
        if calibrationNeedsRetry { rollDisplay.markCalibrationLost(calibrationRecoveryMessage) }
        rollModel = "Not loaded"
    }

    private func rollFloor(_ anchor: ARPlaneAnchor) -> ShotRollFloor {
        ShotRollFloor(id: anchor.identifier.uuidString, worldFromPlane: anchor.transform,
            boundary: Array(anchor.geometry.boundaryVertices))
    }

    private func updateRollFloors(_ frame: ARFrame, anchors: [ARPlaneAnchor]) {
        guard rollDistanceEnabled, frame.timestamp - lastFloorPublish >= 0.25 else { return }
        lastFloorPublish = frame.timestamp
        var cvToAR = matrix_identity_float4x4
        cvToAR[1][1] = -1; cvToAR[2][2] = -1
        let camera = frame.camera.transform * cvToAR
        let floors = anchors.map(rollFloor).filter {
            $0.normal.y >= 0.98 && (0.3...3).contains($0.cameraHeight(camera)) && $0.boundary.count >= 3
        }
        rollFloors = floors.sorted { $0.id < $1.id }.map {
            ShotRollFloorChoice(id: $0.id, cameraHeightM: $0.cameraHeight(camera))
        }
        if let selectedRollFloorID, !floors.contains(where: { $0.id == selectedRollFloorID }) {
            self.selectedRollFloorID = nil; rollFloorChosenByUser = false
            if rollTracker.origin != nil { rollTracker.invalidate() }
        }
        if floors.count > 1, !rollFloorChosenByUser {
            selectedRollFloorID = nil
            if rollTracker.origin != nil { rollTracker.invalidate() }
        } else if floors.count == 1, selectedRollFloorID == nil {
            selectedRollFloorID = floors[0].id
        }
    }

    private func submitRollFrame(_ frame: ARFrame, anchors: [ARPlaneAnchor], sourceFrame: Int?) {
        guard calibrationSnapshot == nil, !rollBusy,
              frame.timestamp - lastRollSubmission >= (recording ? 0.1 : 0.25) else { return }
        rollBusy = true; lastRollSubmission = frame.timestamp
        let generation = rollGeneration
        var cvToAR = matrix_identity_float4x4
        cvToAR[1][1] = -1; cvToAR[2][2] = -1
        let camera = frame.camera.transform * cvToAR
        let rotation = ShotRollRotation.upright(worldFromCamera: camera)
        let intrinsics = frame.camera.intrinsics
        let size = frame.camera.imageResolution
        let floors = anchors.map(rollFloor)
        let timestamp = frame.timestamp
        rollDetector.detect(pixels: frame.capturedImage, resource: BallDetector.configuredResourceName,
            rotation: rotation, timestamp: timestamp) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                self.rollBusy = false
                guard self.rollGeneration == generation else { return }
                guard self.rollPreviewActive, self.rollDistanceEnabled, !self.finishing,
                      sourceFrame == nil || (self.recording && self.rollEnabledForRecording) else { return }
                self.receiveRoll(result, sourceFrame: sourceFrame, timestamp: timestamp,
                    camera: camera, intrinsics: intrinsics, size: size, rotation: rotation, floors: floors)
            }
        }
    }

    private func receiveRoll(_ result: ShotRollDetector.Result, sourceFrame: Int?, timestamp: Double,
                             camera: simd_float4x4, intrinsics: simd_float3x3, size: CGSize,
                             rotation: ShotRollRotation, floors: [ShotRollFloor]) {
        var event: [String: Any] = ["event": "sample",
            "capture_timestamp_s": timestamp, "time_s": timestamp - (origin ?? timestamp),
            "trial": rollTrial, "rotation_clockwise": rotation.rawValue,
            "model": result.model, "confidence": result.confidence,
            "threshold": result.threshold, "detector_ms": result.milliseconds,
            "physical_scale_verified": false, "ground_contact_verified": false]
        if let sourceFrame { event["source_frame"] = sourceFrame; rollSamples += 1 }
        rollModel = result.model
        rollDisplay.isLive = false; rollDisplay.canSetStart = false
        rollDisplay.sensorContact = nil; rollDisplay.sensorBallRect = nil
        rollDisplay.speedKMH = nil
        if recording {
            rollDisplay.speedStatus = rollCalibration == nil ? "Calibrate distance to estimate speed" : "Speed paused — waiting for the ball"
        }
        rollLatest = nil
        defer {
            if calibrationNeedsRetry { rollDisplay.markCalibrationLost(calibrationRecoveryMessage) }
            event["status"] = rollDisplay.status
            event["live"] = rollDisplay.isLive
            if rollTracker.needsNewStart {
                rollDisplay.peakRollingSpeedKMH = nil
                if !calibrationNeedsRetry { rollDisplay.speedStatus = "Set start again to estimate speed" }
            }
            event["rolling_speed_status"] = rollDisplay.speedStatus
            if let speed = rollDisplay.speedKMH { event["rolling_speed_kmh"] = speed }
            if let peak = rollDisplay.peakRollingSpeedKMH { event["peak_rolling_speed_kmh"] = peak }
            if let distance = rollDisplay.distanceM { event["last_display_distance_m"] = distance }
            if sourceFrame != nil {
                do { try writeRollEvent(event) }
                catch { abort(); showFailure("Roll measurement data could not be saved") }
            }
        }
        guard let current = session.currentFrame, case .normal = current.camera.trackingState,
              current.timestamp - timestamp <= 0.7 else {
            rollDisplay.status = "Waiting for a fresh ball observation…"; return
        }
        if let error = result.error {
            event["detector_error"] = error
            rollDisplay.status = "Ball tracker unavailable: \(error)"; return
        }
        guard let upright = result.uprightBallRect else {
            rollDisplay.status = rollDisplay.distanceM == nil
                ? "Ball not found — keep it fully in view"
                : "Ball not visible — holding last estimate"
            return
        }
        let sensor = rotation.sensorRect(upright)
        rollDisplay.sensorBallRect = sensor
        event["sensor_box_normalized"] = [sensor.minX, sensor.minY, sensor.maxX, sensor.maxY]
        guard !calibrationNeedsRetry else {
            rollDisplay.status = calibrationRecoveryMessage; return
        }
        guard let selectedRollFloorID,
              let mapped = floors.first(where: { $0.id == selectedRollFloorID }) else {
            rollDisplay.status = rollFloors.count > 1 ? "Choose a floor for this test" : "Scan the floor around the ball"; return
        }
        if let lockedRollFloor, !mapped.stableRelative(to: lockedRollFloor) {
            rollTracker.invalidate(); self.lockedRollFloor = nil; lockedRollCamera = nil
        }
        if let reference = lockedRollCamera {
            let movement = simd_distance(reference.columns.3, camera.columns.3)
            let alignment = simd_dot(reference.columns.2, camera.columns.2)
            if movement > 0.05 || alignment < cos(Float(3) * .pi / 180) {
                rollTracker.invalidate(); lockedRollCamera = nil; lockedRollFloor = nil
            }
        }
        let sourceFloor = lockedRollFloor ?? mapped
        let floor = rollCalibration?.floor ?? sourceFloor
        let bounds = CGRect(x: sensor.minX * size.width, y: sensor.minY * size.height,
            width: sensor.width * size.width, height: sensor.height * size.height)
        guard let projection = ShotRollGeometry.project(sensorBounds: bounds, imageSize: size,
                intrinsics: intrinsics, worldFromCamera: camera, floor: floor) else {
            rollDisplay.status = "Ball shape unclear — keep it fully visible"; return
        }
        // Coverage remains in AR's original map. A fitted floor offset must
        // not make an unscanned region appear mapped by moving its projection.
        let rawProjection = rollCalibration == nil ? projection : ShotRollGeometry.project(
            sensorBounds: bounds, imageSize: size, intrinsics: intrinsics,
            worldFromCamera: camera, floor: sourceFloor)
        let inside = rawProjection.map { mapped.contains($0.worldContact) } ?? false
        if let sourceFrame {
            rollLatest = ShotRollObservation(sourceFrame: sourceFrame, timestamp: timestamp,
                camera: camera, floor: mapped, projection: projection)
        }
        rollDisplay.sensorContact = CGPoint(x: projection.sensorContact.x / size.width,
                                            y: projection.sensorContact.y / size.height)
        rollDisplay.sampleTimestamp = timestamp
        rollDisplay.outsideMappedFloor = !inside
        rollDisplay.canSetStart = inside && current.timestamp - timestamp <= 0.35
        event["plane_id"] = floor.id
        event["floor_frozen_at_start"] = lockedRollFloor != nil
        event["distance_calibration"] = rollCalibration == nil ? "uncalibrated_ar_floor" : "measured_span_floor_offset"
        if let calibration = rollCalibration {
            event["calibration_id"] = calibration.id
            event["effective_world_from_plane"] = Self.rows(floor.worldFromPlane)
            event["uncalibrated_camera_height_m"] = sourceFloor.cameraHeight(camera)
            if let rawProjection {
                event["uncalibrated_world_contact_m"] = [rawProjection.worldContact.x, rawProjection.worldContact.y, rawProjection.worldContact.z]
            }
        }
        event["world_contact_m"] = [projection.worldContact.x, projection.worldContact.y, projection.worldContact.z]
        event["camera_height_m"] = projection.cameraHeightM
        event["radius_estimate_m"] = projection.radiusM
        event["silhouette_edge_rms_px"] = projection.edgeRMSPixels
        event["inside_current_mapped_boundary"] = inside
        if sourceFrame == nil {
            rollDisplay.status = inside
                ? "Ball found — record, then tap Set start"
                : "Ball found — scan more floor around it"
            return
        }
        if rollTracker.needsNewStart {
            rollDisplay.status = "Tracking changed — set start again"
        } else if rollTracker.origin == nil {
            if rollCalibration != nil { rollDisplay.speedStatus = "Set start to estimate speed" }
            rollDisplay.status = inside ? "Ball found — tap Set start, then roll" : "Scan more floor around the starting ball"
        } else if rollTracker.observe(point: projection.worldContact, time: timestamp) {
            rollDisplay.distanceM = rollTracker.distanceM; rollDisplay.isLive = true
            if let gap = rollTracker.recoveredPreRollGapS {
                event["pre_roll_gap_recovered_s"] = gap
            }
            if rollCalibration != nil {
                // The fit uses capture time. A delayed callback may update the
                // historical peak, but must not present old motion as live.
                let fresh = current.timestamp - timestamp <= 0.35
                rollDisplay.speedKMH = fresh ? rollTracker.speed.speedKMH : nil
                rollDisplay.peakRollingSpeedKMH = rollTracker.speed.peakKMH
                rollDisplay.speedStatus = fresh ? rollTracker.speed.status : "Speed paused — waiting for the ball"
                event["rolling_speed_window_s"] = rollTracker.speed.spanS
                event["rolling_speed_window_samples"] = rollTracker.speed.sampleCount
                if let rms = rollTracker.speed.fitRMSM { event["rolling_speed_fit_rms_m"] = rms }
            }
            rollDisplay.status = inside
                ? rollCalibration == nil ? "Tracking the roll • scale unverified" : "Tracking the roll • calibrated setup, checks pending"
                : "Beyond scanned floor • estimate only"
            if let distance = rollTracker.distanceM { event["distance_from_start_m"] = distance }
        } else {
            rollDisplay.status = "Ball track interrupted — set start again"
        }
    }

    func setRollStart() {
        guard recording, rollEnabledForRecording, !calibrationNeedsRetry, rollDisplay.canSetStart,
              let latest = rollLatest, let current = session.currentFrame,
              current.timestamp - latest.timestamp <= 0.35,
              selectedRollFloorID == latest.floor.id else { return }
        // Set start accepts the displayed floor. Additional plane discoveries
        // must not clear that choice halfway through an otherwise valid roll.
        rollFloorChosenByUser = true
        lockedRollFloor = latest.floor; lockedRollCamera = latest.camera
        rollTracker.arm(point: latest.projection.worldContact, time: latest.timestamp)
        rollTrial += 1; rollDisplay.trial = rollTrial
        rollDisplay.distanceM = 0; rollDisplay.isLive = true
        rollDisplay.speedKMH = nil; rollDisplay.peakRollingSpeedKMH = nil
        rollDisplay.speedStatus = rollCalibration == nil ? "Calibrate distance to estimate speed" : "Collecting motion…"
        rollDisplay.status = "Start set — gently roll the ball"
        do {
            try writeRollEvent(["event": "set_start", "trial": rollTrial,
                "source_frame": latest.sourceFrame, "capture_timestamp_s": latest.timestamp,
                "time_s": latest.timestamp - (origin ?? latest.timestamp),
                "plane_id": latest.floor.id, "world_from_plane": Self.rows(latest.floor.worldFromPlane),
                "effective_world_from_plane": Self.rows(rollCalibration?.floor.worldFromPlane ?? latest.floor.worldFromPlane),
                "distance_calibration": rollCalibration == nil ? "uncalibrated_ar_floor" : "measured_span_floor_offset",
                "boundary_vertices_local_m": latest.floor.boundary.map { [$0.x, $0.y, $0.z] },
                "world_contact_m": [latest.projection.worldContact.x,
                    latest.projection.worldContact.y, latest.projection.worldContact.z],
                "physical_scale_verified": false, "ground_contact_verified": false])
        } catch { abort(); showFailure("The roll starting point could not be saved") }
    }

    private func writeRollEvent(_ event: [String: Any]) throws {
        guard let rollLog else { return }
        var bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        bytes.append(10); try rollLog.write(contentsOf: bytes)
    }
}

private final class ShotGeometryPreviewSurface: ARSCNView {
    private let ballOverlay = CAShapeLayer()
    var rollState = ShotRollDisplay()

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        ballOverlay.fillColor = UIColor.clear.cgColor
        ballOverlay.strokeColor = UIColor.systemYellow.cgColor
        ballOverlay.lineWidth = 2
        layer.addSublayer(ballOverlay)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() { super.layoutSubviews(); updateRollOverlay() }

    func updateRollOverlay() {
        guard bounds.width > 0, bounds.height > 0, let frame = session.currentFrame else {
            ballOverlay.path = nil; return
        }
        let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        let display = frame.displayTransform(for: orientation, viewportSize: bounds.size)
        let pixels = CGAffineTransform(scaleX: bounds.width, y: bounds.height)
        let path = UIBezierPath()
        if let rect = rollState.sensorBallRect {
            let shown = rect.applying(display).applying(pixels)
            path.append(UIBezierPath(roundedRect: shown, cornerRadius: 5))
        }
        if let contact = rollState.sensorContact {
            let point = contact.applying(display).applying(pixels)
            path.append(UIBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ballOverlay.frame = bounds; ballOverlay.path = path.cgPath
        ballOverlay.strokeColor = (rollState.isLive || rollState.canSetStart
            ? UIColor.systemYellow : UIColor.systemGray).cgColor
        CATransaction.commit()
    }
}

private struct ShotGeometryPreview: UIViewRepresentable {
    let capture: ShotGeometryCapture
    func makeUIView(context: Context) -> ShotGeometryPreviewSurface {
        let view = ShotGeometryPreviewSurface(frame: .zero)
        view.session = capture.session
        view.backgroundColor = .black
        view.automaticallyUpdatesLighting = false
        return view
    }
    func updateUIView(_ view: ShotGeometryPreviewSurface, context: Context) {
        view.rollState = capture.rollDistanceEnabled ? capture.rollDisplay : ShotRollDisplay()
        view.updateRollOverlay()
    }
}

struct ShotGeometryCaptureView: View {
    var showsCloseButton = false
    @StateObject private var capture = ShotGeometryCapture()
    @State private var showLibrary = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 12) {
                header
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 16) {
                        preview
                        VStack(spacing: 6) {
                            ScrollView { controls(compact: true, includesActions: false) }
                            recordingActions
                        }.frame(width: min(330, geometry.size.width * 0.4))
                    }
                } else {
                    preview
                    controls(compact: false).layoutPriority(1)
                }
            }.padding(16)
        }
            .sheet(isPresented: $showLibrary) { ShotRecordingsView() }
            .sheet(item: Binding(get: { capture.calibrationSnapshot }, set: { _ in capture.cancelRollCalibration() })) { snapshot in
                ShotRollCalibrationView(snapshot: snapshot, apply: capture.applyRollCalibration,
                    cancel: capture.cancelRollCalibration)
            }
            .task(id: scenePhase == .active && !showLibrary) {
                if scenePhase == .active && !showLibrary { await capture.prepare() }
                else { capture.pause() }
            }
            .onDisappear { capture.pause() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Power Shot").font(.title2.bold())
                    .accessibilityIdentifier("power-shot-title")
                Text(capture.rollDistanceEnabled ? "Roll distance experiment" : "Recording test")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showLibrary = true } label: {
                Image(systemName: "play.rectangle.on.rectangle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Saved shots").accessibilityIdentifier("power-shot-saved-shots")
            .disabled(capture.recording || capture.finishing).tint(.primary)
            if showsCloseButton {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                }.accessibilityLabel("Close Power Shot").accessibilityIdentifier("power-shot-close")
                    .disabled(capture.recording || capture.finishing).tint(.primary)
            }
        }
    }

    private var preview: some View {
        ShotGeometryPreview(capture: capture)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("Live camera with experimental ball tracking")
    }

    private func controls(compact: Bool, includesActions: Bool = true) -> some View {
        VStack(spacing: compact ? 6 : 10) {
            Toggle("Live roll distance", isOn: Binding(get: { capture.rollDistanceEnabled },
                                                       set: { capture.setRollMode($0) }))
                .font(.subheadline.weight(.semibold)).disabled(capture.recording || capture.finishing)
                .accessibilityIdentifier("roll-distance-toggle")
            if capture.rollDistanceEnabled {
                ShotRollDistanceCard(state: capture.rollDisplay, compact: compact)
                if capture.rollFloors.count > 1 {
                    Picker("Floor for this test", selection: Binding(get: { capture.selectedRollFloorID ?? "" },
                        set: { capture.selectRollFloor($0) })) {
                        Text("Choose a floor").tag("")
                        ForEach(Array(capture.rollFloors.enumerated()), id: \.element.id) { index, floor in
                            Text(String(format: "Floor %d · camera %.0f cm", index + 1, floor.cameraHeightM * 100))
                                .tag(floor.id)
                        }
                    }.pickerStyle(.menu).disabled(!capture.canChooseRollFloor || capture.finishing)
                        .accessibilityIdentifier("roll-floor-picker")
                } else if let floor = capture.rollFloors.first {
                    Text(String(format: "Camera above scanned floor: %.0f cm", floor.cameraHeightM * 100))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !capture.recording {
                    HStack {
                        Button(capture.rollCalibration != nil || capture.calibrationNeedsRetry ? "Recalibrate" : "Calibrate distance") {
                            capture.beginRollCalibration()
                        }.buttonStyle(.bordered).disabled(!capture.canCalibrateRoll)
                            .accessibilityIdentifier("roll-calibrate")
                        if capture.rollCalibration != nil || capture.calibrationNeedsRetry {
                            Button("Clear") { capture.clearRollCalibration() }
                                .disabled(capture.finishing).accessibilityIdentifier("roll-clear-calibration")
                        }
                    }
                    Text(capture.calibrationStatus).font(.caption)
                        .foregroundStyle(capture.calibrationNeedsRetry ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("roll-calibration-status")
                }
            }
            if includesActions { recordingActions }
            if !compact || capture.finishing || !capture.files.isEmpty {
                Text(capture.status).font(.caption).multilineTextAlignment(.center)
            }
            if !capture.recording && (!compact || !capture.ready) {
                Text(capture.groundStatus).font(.caption).multilineTextAlignment(.center)
            }
            if !compact {
                Text(capture.rollDistanceEnabled
                    ? "Calibrate with the paper centres while the phone is fixed. Rest the ball centred over A, wait for Ball found, record, tap Set start, then gently roll. Check separate 1 m and 2 m marks. Up to 15 seconds."
                    : "Map the ground briefly, then keep the phone steady. Record one shot, up to 15 seconds.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recordingActions: some View {
        HStack(spacing: 12) {
            Button(capture.recording ? "Stop & save" : capture.rollDistanceEnabled ? "Record test" : "Record") {
                if capture.recording { capture.stop() } else { capture.begin() }
            }.buttonStyle(.borderedProminent)
                .disabled(capture.finishing || (!capture.recording && !capture.canBeginRecording))
                .accessibilityIdentifier("power-shot-record")
            if capture.rollDistanceEnabled {
                Button("Set start") { capture.setRollStart() }
                    .buttonStyle(.bordered)
                    .disabled(!capture.recording || !capture.rollDisplay.canSetStart || capture.finishing)
                    .accessibilityIdentifier("roll-set-start")
            }
        }
    }
}
