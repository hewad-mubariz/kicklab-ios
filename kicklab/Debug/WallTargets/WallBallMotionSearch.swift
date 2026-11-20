#if DEBUG
import CoreGraphics
import CoreVideo
import Foundation

/// Conservative wake-up for the accelerated detector, never a ball detector.
/// Unlike the CPU crop finder, any motion (including a player, shadow or flash)
/// wakes inference. Do not require a ball-shaped component before looking for it.
nonisolated struct WallSceneActivity {
    private var previous: [UInt8] = []
    private var lastTime: Double?
    private var dimensions = CGSize.zero

    mutating func reset() { previous = []; lastTime = nil; dimensions = .zero }

    mutating func hasMotion(in pixels: CVPixelBuffer, at time: Double) -> Bool {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { reset(); return true }
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        let width = 320, height = max(1, h * width / max(1, w))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels), w > 0, h > 0 else { reset(); return true }
        let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(h - 1, (2 * y + 1) * h / (2 * height))
            for x in 0..<width {
                let sx = min(w - 1, (2 * x + 1) * w / (2 * width)), p = sy * stride + sx * 4
                luma[y * width + x] = UInt8((Int(bytes[p]) + 2 * Int(bytes[p + 1]) + Int(bytes[p + 2])) / 4)
            }
        }
        return hasMotion(luma: luma, width: width, height: height, at: time)
    }

    mutating func hasMotion(luma: [UInt8], width: Int, height: Int, at time: Double) -> Bool {
        guard width > 0, height > 0, luma.count == width * height, time.isFinite else { reset(); return true }
        let size = CGSize(width: width, height: height)
        defer { previous = luma; dimensions = size; lastTime = time }
        // Fail open after a pause, size change or invalid clock. First recall
        // frames must be analysed immediately, even before a motion baseline.
        guard dimensions == size, previous.count == luma.count, let lastTime,
              time > lastTime, time - lastTime <= 0.30 else { return true }
        // Isolated sensor/projector sparkle must not keep a 200 ms model burst
        // alive. Require spatial support, not a ball shape: players, shadows,
        // incoming balls and broad light changes still wake on this frame.
        var supported = 0
        for i in luma.indices where abs(Int(luma[i]) - Int(previous[i])) >= 12 {
            let x = i % width, y = i / width
            var neighbours = 0
            for yy in max(0, y - 1)...min(height - 1, y + 1) {
                for xx in max(0, x - 1)...min(width - 1, x + 1) {
                    let j = yy * width + xx
                    if abs(Int(luma[j]) - Int(previous[j])) >= 12 { neighbours += 1 }
                }
            }
            if neighbours >= 5 { supported += 1 }
            if supported >= 6 { return true }
        }
        return false
    }
}

/// Choose where to run the ball model on a fixed camera. This is only a search
/// hint: changed pixels never become ball observations or contact evidence.
nonisolated struct WallBallMotionSearch {
    struct Hint {
        let crop: CGRect
        let region: CGRect

        func contains(_ ball: Detection, size: CGSize, minimumDiameter: Double) -> Bool {
            let d = (ball.width * size.width + ball.height * size.height) / 2
            // A projected marker elsewhere inside the larger crop is not the
            // moving object which requested this search.
            return d.isFinite && d >= minimumDiameter
                && region.insetBy(dx: -d / 2, dy: -d / 2)
                    .contains(CGPoint(x: ball.x * size.width, y: ball.y * size.height))
        }
    }

    private var previous: [UInt8] = []
    private var older: [UInt8] = []
    private var lastTime: Double?
    private var dimensions = CGSize.zero

    mutating func reset() { previous = []; older = []; lastTime = nil; dimensions = .zero }

    mutating func crop(in pixels: CVPixelBuffer, at time: Double) -> Hint? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { reset(); return nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        let width = 320, height = max(1, Int(size.height / size.width * Double(width)))
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { reset(); return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
        var luma = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = min(Int(size.height) - 1, Int((Double(y) + 0.5) * size.height / Double(height)))
            for x in 0..<width {
                let sx = min(Int(size.width) - 1, Int((Double(x) + 0.5) * size.width / Double(width)))
                let p = sy * stride + sx * 4
                luma[y * width + x] = UInt8((Int(bytes[p]) + 2 * Int(bytes[p + 1]) + Int(bytes[p + 2])) / 4)
            }
        }
        return crop(luma: luma, width: width, height: height, imageSize: size, at: time)
    }

    /// Two past frames suppress the departed ball's old position. A close crop
    /// helps RF find the approach outside the board without a second model pass.
    mutating func crop(luma: [UInt8], width: Int, height: Int, imageSize: CGSize, at time: Double) -> Hint? {
        guard width > 2, height > 2, luma.count == width * height,
              imageSize.width > 0, imageSize.height > 0, time.isFinite else { reset(); return nil }
        if dimensions != imageSize || lastTime.map({ time <= $0 || time - $0 > 0.30 }) == true { reset() }
        defer { older = previous; previous = luma; lastTime = time; dimensions = imageSize }
        guard previous.count == luma.count, older.count == luma.count else { return nil }
        var changed = [Bool](repeating: false, count: luma.count)
        var amount = [Int](repeating: 0, count: luma.count)
        var total = 0
        for i in luma.indices {
            let difference = min(abs(Int(luma[i]) - Int(previous[i])), abs(Int(luma[i]) - Int(older[i])))
            amount[i] = difference
            if difference >= 16 { changed[i] = true; total += 1 }
        }
        // A camera move or a scene-wide flash is not a compact moving ball.
        guard total >= 8, total < luma.count / 8 else { return nil }
        var mask = changed
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where changed[y * width + x] {
                for dy in -1...1 { for dx in -1...1 { mask[(y + dy) * width + x + dx] = true } }
            }
        }
        var best: (score: Double, rect: CGRect)?
        for seed in mask.indices where mask[seed] {
            var queue = [seed], cursor = 0
            mask[seed] = false
            var left = seed % width, right = left, top = seed / width, bottom = top
            var count = 0, strength = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % width, y = i / width
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                if changed[i] { count += 1; strength += amount[i] }
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny >= 0, ny < height {
                        let n = ny * width + nx
                        if mask[n] { mask[n] = false; queue.append(n) }
                    }
                } }
            }
            let w = Double(right - left + 1), h = Double(bottom - top + 1), aspect = w / h
            guard count >= 8, w >= 4, h >= 4, max(w, h) <= Double(width) * 0.24,
                  (0.45...2.2).contains(aspect), Double(count) / (w * h) >= 0.10 else { continue }
            let score = Double(strength) * min(aspect, 1 / aspect)
            if best == nil || score > best!.score {
                best = (score, CGRect(x: Double(left) / Double(width) * imageSize.width,
                    y: Double(top) / Double(height) * imageSize.height,
                    width: w / Double(width) * imageSize.width, height: h / Double(height) * imageSize.height))
            }
        }
        guard let rect = best?.rect else { return nil }
        let edge = min(imageSize.width, imageSize.height,
                       max(imageSize.width * 0.30, min(imageSize.width * 0.5, max(rect.width, rect.height) * 5)))
        let crop = CGRect(x: max(0, min(imageSize.width - edge, rect.midX - edge / 2)),
                      y: max(0, min(imageSize.height - edge, rect.midY - edge / 2)), width: edge, height: edge)
            .integral.intersection(CGRect(origin: .zero, size: imageSize))
        return Hint(crop: crop, region: rect)
    }
}
#endif
