import Foundation

/// Lossless storage for the lab's original GPU data. Decode once during resource preparation;
/// the shaders still receive the same texture mip levels, triangles and acceleration structures.
nonisolated enum LabAssetData {
    static func load(_ name: String, directory: URL? = nil) throws -> Data {
        let compressed: URL?
        let raw: URL?
        if let directory {
            let candidate = directory.appendingPathComponent(name + ".bin.lzfse")
            compressed = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
            raw = directory.appendingPathComponent(name + ".bin")
        } else {
            compressed = Bundle.main.url(forResource: name, withExtension: "bin.lzfse")
            raw = Bundle.main.url(forResource: name, withExtension: "bin")
        }
        if let compressed {
            return try (Data(contentsOf: compressed) as NSData).decompressed(using: .lzfse) as Data
        }
        // Tiny assets and the external Effects Lab's source files remain uncompressed.
        guard let raw else {
            throw NSError(domain: "EffectLab", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Missing effect asset: \(name)"])
        }
        return try Data(contentsOf: raw)
    }
}
