//
//  Recorder.swift
//  kicklab
//
//  Writes the camera frames to a file while they are being counted, so a run can
//  be reviewed afterwards with the touches marked - the same thing the Python
//  lab does when it renders an annotated video, which is how nearly every
//  counting bug in this project was actually found.
//
//  The frames written are the ones the counter saw, so what you review is what
//  was judged, not a second capture that might differ.
//

import AVFoundation
import CoreVideo
import Foundation

/// Where the ball was on one frame, for drawing the track during review.
///
/// The Python lab's annotated render draws the ball on every frame, not just at
/// touches, and that is what makes a miscount legible: you can see the track go
/// wrong before the count does.
nonisolated struct RecordedFrame {
    /// Seconds from the start of the recording.
    let time: Double
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let score: Double
    /// Smoothed position the counter actually judged, which is not quite the raw
    /// detection - the difference is worth seeing when a count looks wrong.
    let smoothedX: Double
    let smoothedY: Double
    /// Vertical velocity in frame-heights per second, and the state derived from
    /// it. This is what the counter keys on, so showing it explains a count.
    let vy: Double
    let motion: MotionState
    /// Whether this frame had a real detection or was filled in.
    let detected: Bool
    /// The person box, for the body region and the ground line.
    let person: PersonBox?
    var ballMask: BallMask? = nil
    var usesBallMasks: Bool = false
}

/// A touch, as it happened, for marking up the recording afterwards.
nonisolated struct RecordedTouch: Identifiable, Hashable {
    let id = UUID()
    let index: Int
    /// Seconds from the start of the recording.
    let time: Double
    /// Where the ball was, normalised, when the touch was confirmed.
    let x: Double
    let y: Double
}

final class Recorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startedAt: CMTime?
    private(set) var url: URL?

    var isRecording: Bool { writer != nil }

    /// Begin a recording sized to the frames that will be appended.
    ///
    /// `cameraPosition` tags the file's preferred transform so replay stays
    /// portrait for both back and front lenses (front also mirrored).
    func start(width: Int, height: Int,
               cameraPosition: AVCaptureDevice.Position = .back) throws {
        stop(completion: nil)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("kicklab-run-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: file)

        let writer = try AVAssetWriter(outputURL: file, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = Self.displayTransform(
            width: width, height: height, position: cameraPosition)
        // Frames arrive in capture order at capture rate; this lets the writer
        // pull them without buffering the whole run in memory.
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "KickLab", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "cannot add writer input"])
        }
        writer.add(input)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.startedAt = nil
        self.url = file
    }

    /// Preferred transform so AVPlayer shows the clip upright.
    ///
    /// Mirroring is already baked into front-camera pixels via the capture
    /// connection — do not mirror again here or replay ends up wrong.
    private static func displayTransform(
        width: Int, height: Int, position _: AVCaptureDevice.Position
    ) -> CGAffineTransform {
        let h = CGFloat(height)
        // Landscape sensor buffer → tag as portrait for playback.
        if width > height {
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        }
        // Connection already rotated buffers to portrait.
        return .identity
    }

    /// Append one frame. Silently ignores frames the writer is not ready for -
    /// dropping a frame from the recording is better than stalling capture.
    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let writer, let input, let adaptor else { return }
        if startedAt == nil {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: time)
            startedAt = time
        }
        guard input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    /// Seconds since the first appended frame.
    func elapsed(at time: CMTime) -> Double {
        guard let startedAt else { return 0 }
        return max(0, CMTimeGetSeconds(time) - CMTimeGetSeconds(startedAt))
    }

    func stop(completion: ((URL?) -> Void)?) {
        guard let writer, let input else {
            completion?(nil)
            return
        }
        let file = url
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        self.startedAt = nil

        guard writer.status == .writing else {
            completion?(nil)
            return
        }
        input.markAsFinished()
        writer.finishWriting { completion?(file) }
    }
}
