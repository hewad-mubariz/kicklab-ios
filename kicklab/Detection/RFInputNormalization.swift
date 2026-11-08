import Foundation
nonisolated enum RFInputNormalization {
    static let edge = 384
    static func normalizeBGRA(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                              into dest: UnsafeMutablePointer<Float>, edge n: Int = edge) {
        let plane = n * n
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        let sx = Float(width) / Float(n), sy = Float(height) / Float(n)
        for y in 0..<n {
            let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
            let y0 = min(height - 1, Int(fy)), y1 = min(height - 1, y0 + 1), wy = fy - Float(y0)
            for x in 0..<n {
                let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                let x0 = min(width - 1, Int(fx)), x1 = min(width - 1, x0 + 1), wx = fx - Float(x0)
                for c in 0..<3 {
                    let channel = 2 - c
                    // Normalize source samples to 0...1 before interpolation, as in the training transform.
                    let a = Float(bytes[y0 * rowBytes + x0 * 4 + channel]) / 255
                    let b = Float(bytes[y0 * rowBytes + x1 * 4 + channel]) / 255
                    let d = Float(bytes[y1 * rowBytes + x0 * 4 + channel]) / 255
                    let e = Float(bytes[y1 * rowBytes + x1 * 4 + channel]) / 255
                    let value = (a * (1 - wx) + b * wx) * (1 - wy) + (d * (1 - wx) + e * wx) * wy
                    dest[c * plane + y * n + x] = (value - mean[c]) / std[c]
                }
            }
        }
    }
}

/// Reusable interpolation geometry for one detector input size and row stride.
/// Keep the baseline's interpolation and normalization operation order.
nonisolated struct RFNormalizationPlan {
    let width: Int, height: Int, rowBytes: Int, edge: Int
    private let left: [Int], right: [Int], top: [Int], bottom: [Int]
    private let horizontal: [Float], vertical: [Float]

    init(width: Int, height: Int, rowBytes: Int, edge: Int) {
        self.width = width; self.height = height; self.rowBytes = rowBytes; self.edge = edge
        let sx = Float(width) / Float(edge), sy = Float(height) / Float(edge)
        let xs = (0..<edge).map { max(0, (Float($0) + 0.5) * sx - 0.5) }
        let ys = (0..<edge).map { max(0, (Float($0) + 0.5) * sy - 0.5) }
        let x0 = xs.map { min(width - 1, Int($0)) }
        let y0 = ys.map { min(height - 1, Int($0)) }
        left = x0.map { $0 * 4 }; right = x0.map { min(width - 1, $0 + 1) * 4 }
        top = y0.map { $0 * rowBytes }; bottom = y0.map { min(height - 1, $0 + 1) * rowBytes }
        horizontal = zip(xs, x0).map { $0.0 - Float($0.1) }
        vertical = zip(ys, y0).map { $0.0 - Float($0.1) }
    }

    func apply(_ bytes: UnsafePointer<UInt8>, into dest: UnsafeMutablePointer<Float>) {
        let plane = edge * edge
        let mean: [Float] = [0.485, 0.456, 0.406], std: [Float] = [0.229, 0.224, 0.225]
        for y in 0..<edge {
            let aRow = bytes.advanced(by: top[y]), bRow = bytes.advanced(by: bottom[y])
            let wy = vertical[y]
            for x in 0..<edge {
                let x0 = left[x], x1 = right[x], wx = horizontal[x]
                for c in 0..<3 {
                    let channel = 2 - c
                    let a = Float(aRow[x0 + channel]) / 255
                    let b = Float(aRow[x1 + channel]) / 255
                    let d = Float(bRow[x0 + channel]) / 255
                    let e = Float(bRow[x1 + channel]) / 255
                    let value = (a * (1 - wx) + b * wx) * (1 - wy) + (d * (1 - wx) + e * wx) * wy
                    dest[c * plane + y * edge + x] = (value - mean[c]) / std[c]
                }
            }
        }
    }
}
