//
//  MotionCompensator.swift
//  kicklab
//
//  Cancel camera movement by measuring the background, not the phone.
//
//  A camera that moves makes a stationary ball appear to bounce, and the counter
//  reads vertical reversals in frame coordinates. Measured in the lab on a clip
//  of a motionless ball with the phone waved up and down: 20 touches, where the
//  answer is zero. With this compensation: 0, while a 33-touch handheld clip
//  still reads 33 and the eight-clip corpus improved from 13 errors to 8.
//
//  This replaces a gyroscope version. The gyroscope measures rotation accurately
//  and cheaply, but the motion that caused the problem was bodily up-and-down -
//  translation - which it cannot see at all. Two other references were measured
//  and rejected in the lab: ball position relative to the person box (the box
//  jitters more than the motion it cancels, 15 -> 24 errors), and a smoothed
//  person position (free, but a one-second average smooths away the 2-5Hz shake
//  it is meant to cancel). On the shake clip the person box barely moved at all,
//  because the player filled the frame and the box clipped at the edges.
//
//  The background has none of those problems: if the whole scene shifted, the
//  camera moved. `VNTranslationalImageRegistrationRequest` measures that shift
//  with hardware acceleration; the lab uses phase correlation for the same job.
//

import CoreImage
import CoreVideo
import Foundation
import Vision

final class MotionCompensator {
    /// Frames are reduced to this square before registering. Cheap, and still
    /// resolves what matters: a touch is ~0.02 of frame height, three pixels here.
    private let workSize = 160

    /// Movement slower than this window is a deliberate pan, and left alone.
    ///
    /// Without it the accumulated offset drifts without bound - every frame's
    /// small error is added forever. A touch lasts a few frames; a pan lasts
    /// seconds, and compensating one does not require compensating the other.
    private let highPassFrames = 60

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var previous: CVPixelBuffer?
    private var scratchA: CVPixelBuffer?
    private var scratchB: CVPixelBuffer?
    private var useA = true
    private var offset: Double = 0
    private var recent: [Double] = []

    /// Last measured shift, for display. Positive means the view moved down.
    private(set) var lastShift: Double = 0

    /// Recent per-frame movement, used to tell when the camera is moving too
    /// much to count reliably.
    private var recentSteps: [Double] = []

    /// True when the camera is moving faster than compensation can follow.
    ///
    /// Compensation handles ordinary handheld movement well - a clip that
    /// produced 20 phantom touches now produces none, and the lab corpus
    /// improved from 13 errors to 8. It breaks down under deliberate fast
    /// shaking: measured at about 3.5Hz the frames blur, registration between
    /// them degrades, and a ball filling 40% of the frame leaves too little
    /// background to measure against.
    ///
    /// Rather than silently miscount, say so. A counter that admits it cannot
    /// see is worth more than one that invents touches.
    var isTooShaky: Bool {
        guard recentSteps.count >= 10 else { return false }
        let motion = recentSteps.reduce(0) { $0 + abs($1) } / Double(recentSteps.count)
        return motion > 0.02
    }

    func reset() {
        previous = nil
        offset = 0
        recent.removeAll()
        recentSteps.removeAll()
        lastShift = 0
    }

    /// Where the ball was last seen, normalised, so it can be excluded.
    ///
    /// Registration measures how the whole frame moved, which assumes the frame
    /// is mostly background. A ball close to the camera breaks that assumption -
    /// measured at 0.35 of frame width on a run where compensation only partly
    /// worked - because the correlation starts tracking the ball instead of the
    /// scene behind it, and then cancels the ball's own motion along with the
    /// camera's. Painting it out leaves the background to speak for itself.
    var excludeBall: CGRect?

    /// Feed one frame; returns the offset to subtract from a ball's `y`.
    func update(_ pixelBuffer: CVPixelBuffer) -> Double {
        guard let small = downscale(pixelBuffer) else { return corrected() }
        defer { previous = small }

        guard let reference = previous else { return corrected() }

        let request = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: small)
        let handler = VNImageRequestHandler(cvPixelBuffer: reference, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return corrected()
        }
        guard let result = request.results?.first as? VNImageTranslationAlignmentObservation
        else {
            return corrected()
        }

        // alignmentTransform maps the new frame back onto the reference, so its
        // translation is the NEGATIVE of how far the content moved. Negating it
        // gives the same sign convention as the lab's phase correlation, where a
        // positive value means the scene moved down the frame.
        //
        // If compensation ever makes shake worse rather than better, this sign is
        // the first thing to check: the wrong one doubles the motion instead of
        // removing it.
        let shift = -Double(result.alignmentTransform.ty) / Double(workSize)

        // A wild value means the frames had little in common - a cut, sudden
        // blur - and the measurement is a guess. Acting on it would inject
        // motion rather than remove it.
        if abs(shift) < 0.25 {
            offset += shift
            recentSteps.append(shift)
            if recentSteps.count > 30 { recentSteps.removeFirst(recentSteps.count - 30) }
        }

        recent.append(offset)
        if recent.count > highPassFrames { recent.removeFirst(recent.count - highPassFrames) }
        lastShift = corrected()
        return lastShift
    }

    /// Offset with slow drift removed, so only recent movement is cancelled.
    private func corrected() -> Double {
        guard !recent.isEmpty else { return 0 }
        let baseline = recent.reduce(0, +) / Double(recent.count)
        return offset - baseline
    }

    /// Two scratch buffers, alternating: the previous frame must stay valid while
    /// the next one is written.
    private func downscale(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        if scratchA == nil { scratchA = makeBuffer() }
        if scratchB == nil { scratchB = makeBuffer() }
        guard let target = useA ? scratchA : scratchB else { return nil }
        useA.toggle()

        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if image.extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(
                translationX: -image.extent.origin.x, y: -image.extent.origin.y))
        }
        let sx = CGFloat(workSize) / image.extent.width
        let sy = CGFloat(workSize) / image.extent.height
        var scaled = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // Paint the ball out with flat grey, generously. A featureless patch
        // contributes nothing to the correlation, so the shift is measured from
        // the background alone.
        if let ball = excludeBall {
            let pad: CGFloat = 1.35
            let w = ball.width * CGFloat(workSize) * pad
            let h = ball.height * CGFloat(workSize) * pad
            // CoreImage's origin is bottom-left; the detector's is top-left.
            let cx = ball.midX * CGFloat(workSize)
            let cy = CGFloat(workSize) - ball.midY * CGFloat(workSize)
            let patch = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                .cropped(to: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
            scaled = patch.composited(over: scaled)
        }

        ciContext.render(scaled, to: target)
        return target
    }

    private func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, workSize, workSize,
                            kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                            &buffer)
        return buffer
    }
}
