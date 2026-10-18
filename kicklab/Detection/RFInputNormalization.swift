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
