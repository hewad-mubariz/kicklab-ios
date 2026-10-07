//
//  AnnotationExporter.swift
//  kicklab
//
//  Burn the annotations into a new video file.
//
//  Screen-recording the review works but is lossy, captures the UI chrome, and
//  is locked to the phone's screen size. This reads the recorded frames back,
//  draws the overlay into each one with Core Graphics, and writes a clean file -
//  the same thing the Python lab produces with `--render`.
//
//  It does not need to be real time. Export runs as fast as it can and reports
//  progress; a 30 second run takes a few seconds.
//

import AVFoundation
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AnnotationExporter: ObservableObject {
    @Published private(set) var isExporting = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var outputURL: URL?
    @Published private(set) var status = ""

    private let rising = UIColor(red: 0.24, green: 0.92, blue: 0.48, alpha: 1)
    private let falling = UIColor(red: 1.00, green: 0.62, blue: 0.20, alpha: 1)
    private let touchColor = UIColor(red: 1.0, green: 0.28, blue: 0.32, alpha: 1)
    private let personColor = UIColor(white: 1, alpha: 0.5)
    private let groundColor = UIColor(red: 0.90, green: 0.27, blue: 0.27, alpha: 0.9)

    func export(source: URL, track: [RecordedFrame], touches: [RecordedTouch]) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        outputURL = nil
        status = "preparing…"

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let url = try await self?.run(source: source, track: track, touches: touches)
                await MainActor.run {
                    self?.outputURL = url
                    self?.status = "done"
                    self?.progress = 1
                }
            } catch {
                await MainActor.run { self?.status = "failed: \(error.localizedDescription)" }
            }
            await MainActor.run { self?.isExporting = false }
        }
    }

    private nonisolated func run(source: URL, track: [RecordedFrame],
                                 touches: [RecordedTouch]) async throws -> URL {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "KickLab", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "no video track"])
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let fps = try await videoTrack.load(.nominalFrameRate)
        let total = max(1.0, duration * Double(fps > 0 ? fps : 30))

        // Draw in the video's displayed orientation, not its stored one, so the
        // annotations line up with a portrait recording.
        let upright = naturalSize.applying(transform)
        let size = CGSize(width: abs(upright.width), height: abs(upright.height))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = true
        reader.add(output)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("kicklab-annotated-\(Int(Date().timeIntervalSince1970)).mov")
        try? FileManager.default.removeItem(at: out)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                // Generous, because the overlay has thin bright lines that a low
                // bitrate turns to mush - and this file is the thing people see.
                AVVideoAverageBitRateKey: 12_000_000,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var index = 0
        var started: Double?

        while let sample = output.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            let stamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if started == nil { started = stamp }
            let t = stamp - (started ?? 0)

            guard let pool = adaptor.pixelBufferPool else { break }
            var target: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target)
            guard let target else { break }

            CVPixelBufferLockBaseAddress(target, [])
            CVPixelBufferLockBaseAddress(source, .readOnly)

            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(target),
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(target),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue) {

                // The frame itself, uprighted.
                let ci = CIImage(cvPixelBuffer: source).transformed(by: transform)
                let ciContext = CIContext(options: [.useSoftwareRenderer: false])
                if let cg = ciContext.createCGImage(
                    ci, from: CGRect(origin: .zero, size: size)) {
                    context.draw(cg, in: CGRect(origin: .zero, size: size))
                }

                // Core Graphics has y up; the track is in top-left coordinates.
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                draw(in: context, size: size, at: t, track: track, touches: touches)
            }

            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(target, [])

            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            adaptor.append(target, withPresentationTime:
                            CMSampleBufferGetPresentationTimeStamp(sample))

            index += 1
            if index % 10 == 0 {
                let p = min(1.0, Double(index) / total)
                await MainActor.run {
                    self.progress = p
                    self.status = "rendering…"
                }
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw writer.error ?? NSError(domain: "KickLab", code: 41)
        }
        return out
    }

    // MARK: - Drawing

    private nonisolated func draw(in ctx: CGContext, size: CGSize, at time: Double,
                                  track: [RecordedFrame], touches: [RecordedTouch]) {
        let now = track.min { abs($0.time - time) < abs($1.time - time) }
        guard let now, abs(now.time - time) < 0.12 else { return }

        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x * size.width, y: y * size.height)
        }

        // Ground line.
        if let person = now.person {
            let y = person.bottom * size.height
            ctx.setStrokeColor(groundColor.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [10, 7])
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // Person box.
            ctx.setStrokeColor(personColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(CGRect(x: (person.x - person.width / 2) * size.width,
                              y: (person.y - person.height / 2) * size.height,
                              width: person.width * size.width,
                              height: person.height * size.height))
        }

        // Trail, fading and coloured by direction of travel.
        let trail = track.filter { $0.time <= time && $0.time > time - 0.9 }
        if trail.count > 1 {
            ctx.setLineCap(.round)
            for i in 1..<trail.count {
                let a = trail[i - 1], b = trail[i]
                let fade = Double(i) / Double(trail.count)
                let colour = (b.vy > 0 ? falling : rising).withAlphaComponent(0.15 + 0.85 * fade)
                ctx.setStrokeColor(colour.cgColor)
                ctx.setLineWidth(3)
                ctx.move(to: point(a.smoothedX, a.smoothedY))
                ctx.addLine(to: point(b.smoothedX, b.smoothedY))
                ctx.strokePath()
            }
        }

        // The ball, with a glow so it reads over a busy background.
        let centre = point(now.x, now.y)
        let radius = max(now.width * size.width, now.height * size.height) * 0.62
        ctx.setShadow(offset: .zero, blur: 18, color: rising.withAlphaComponent(0.9).cgColor)
        ctx.setStrokeColor(rising.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                     width: radius * 2, height: radius * 2))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Touch flashes: expanding rings, then a quiet dot that persists.
        for touch in touches where touch.time <= time {
            let at = point(touch.x, touch.y)
            let age = time - touch.time
            if age <= 0.55 {
                let progress = age / 0.55
                let r = 18 + 70 * progress
                ctx.setStrokeColor(touchColor.withAlphaComponent(1 - progress).cgColor)
                ctx.setLineWidth(4 * (1 - progress) + 1)
                ctx.strokeEllipse(in: CGRect(x: at.x - r, y: at.y - r,
                                             width: r * 2, height: r * 2))
            } else {
                ctx.setFillColor(touchColor.withAlphaComponent(0.4).cgColor)
                ctx.fillEllipse(in: CGRect(x: at.x - 4, y: at.y - 4, width: 8, height: 8))
            }
        }

        drawChart(in: ctx, size: size, at: time, track: track, touches: touches)
        drawCount(in: ctx, size: size, count: touches.filter { $0.time <= time }.count)
    }

    /// The run as a row of arcs, along the bottom. Height is up.
    private nonisolated func drawChart(in ctx: CGContext, size: CGSize, at time: Double,
                                       track: [RecordedFrame], touches: [RecordedTouch]) {
        let h: CGFloat = size.height * 0.13
        let top = size.height - h
        let window = 5.0
        let from = time - window * 0.72, to = time + window * 0.28

        ctx.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: size.width, height: h))

        func cx(_ t: Double) -> CGFloat { CGFloat((t - from) / (to - from)) * size.width }
        func cy(_ y: Double) -> CGFloat { top + CGFloat(min(max(y, 0), 1)) * (h - 16) + 8 }

        let visible = track.filter { $0.time >= from && $0.time <= to }
        if visible.count > 1 {
            ctx.setStrokeColor(rising.cgColor)
            ctx.setLineWidth(2.5)
            ctx.move(to: CGPoint(x: cx(visible[0].time), y: cy(visible[0].smoothedY)))
            for f in visible.dropFirst() {
                ctx.addLine(to: CGPoint(x: cx(f.time), y: cy(f.smoothedY)))
            }
            ctx.strokePath()
        }

        for t in touches where t.time >= from && t.time <= to {
            ctx.setFillColor(touchColor.cgColor)
            let x = cx(t.time), y = cy(t.y)
            ctx.fillEllipse(in: CGRect(x: x - 4, y: y - 4, width: 8, height: 8))
            ctx.setStrokeColor(touchColor.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x, y: top + h))
            ctx.strokePath()
        }

        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: cx(time), y: top))
        ctx.addLine(to: CGPoint(x: cx(time), y: top + h))
        ctx.strokePath()
    }

    private nonisolated func drawCount(in ctx: CGContext, size: CGSize, count: Int) {
        let text = "\(count)"
        let font = UIFont.systemFont(ofSize: size.height * 0.075, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black.withAlphaComponent(0.7),
            .strokeWidth: -3.0,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()

        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        // Undo the flip for text, which would otherwise draw upside down.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        string.draw(at: CGPoint(x: size.width - bounds.width - 26, y: 26))
        ctx.restoreGState()
        UIGraphicsPopContext()
    }
}
