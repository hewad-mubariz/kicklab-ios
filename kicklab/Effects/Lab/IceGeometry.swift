// Copied from the Effects Lab (Crystal, accepted 1 November 2026); only isolation is added for the app.
import Foundation
import Metal

/// Closed triangle solids and their CPU-authored BVH. The same buffers are used
/// by the Simulator app and the offline Metal screenshot tool.
nonisolated final class IceGeometry {
    let triangles: MTLBuffer
    let nodes: MTLBuffer
    let roots: MTLBuffer

    init(device: MTLDevice, directory: URL? = nil, prefix: String = "ice") throws {
        func load(_ name: String, stride: Int) throws -> MTLBuffer {
            guard let url = directory?.appendingPathComponent(name + ".bin") ?? Bundle.main.url(forResource: name, withExtension: "bin") else {
                throw NSError(domain: "EffectLab", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing ice geometry: \(name)"])
            }
            let data = try Data(contentsOf: url)
            guard !data.isEmpty, data.count.isMultiple(of: stride),
                  let buffer = data.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                throw NSError(domain: "EffectLab", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid ice geometry: \(name)"])
            }
            buffer.label = name
            return buffer
        }
        triangles = try load(prefix + "-triangles", stride: 96)
        nodes = try load(prefix + "-bvh", stride: 48)
        roots = try load(prefix + "-roots", stride: 16)
    }

    func bind(_ encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentBuffer(triangles, offset: 0, index: 2)
        encoder.setFragmentBuffer(nodes, offset: 0, index: 3)
        encoder.setFragmentBuffer(roots, offset: 0, index: 4)
    }
}
