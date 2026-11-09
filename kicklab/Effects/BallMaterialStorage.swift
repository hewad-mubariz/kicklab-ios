import Compression
import Foundation

/// Lossless on-disk storage only. The renderer still receives the original 8-bit
/// colour/seam and object-space normal arrays at their original resolution.
nonisolated enum BallMaterialStorage {
    struct Artwork {
        let rgba: [UInt8]
        let normals: [UInt8]
    }

    enum Filter: Int, Codable, CaseIterable {
        case raw, sub, up, paeth
    }

    struct Map: Codable {
        let channels: Int
        let filter: Filter
        let greenDifference: Bool
    }

    struct Material: Codable {
        let color: String
        let seam: String
        let normal: String
    }

    struct Catalog: Codable {
        let version: Int
        let width: Int
        let height: Int
        let materials: [String: Material]
        let maps: [String: Map]
    }

    static func load(resource: String, width: Int, height: Int, directory: URL? = nil) -> Artwork? {
        // Dimensions are bounded before arithmetic, allocation or decompression.
        guard width > 0, width <= 1024, height > 0, height <= 512 else { return nil }
        func url(_ name: String, _ ext: String) -> URL? {
            if let directory {
                let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "BallMaterials")
        }
        if let manifest = url("ball-materials", "json") {
            guard let data = try? Data(contentsOf: manifest),
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
                  catalog.version == 1, catalog.width == width, catalog.height == height,
                  let material = catalog.materials[resource] else { return nil }
            func read(_ key: String, channels: Int, color: Bool = false) -> [UInt8]? {
                // Content keys are filenames, never paths from a manifest.
                guard key.utf8.count == 64,
                      key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      let map = catalog.maps[key], map.channels == channels,
                      !map.greenDifference || color,
                      let file = url("ball-map-" + key, "jdmap"),
                      let packed = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
                return decode(packed, width: width, height: height, map: map)
            }
            guard let color = read(material.color, channels: 3, color: true),
                  let seam = read(material.seam, channels: 1),
                  let normal = read(material.normal, channels: 3) else { return nil }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBufferPointer { destination in
                color.withUnsafeBufferPointer { rgb in
                    seam.withUnsafeBufferPointer { alpha in
                        for pixel in 0..<(width * height) {
                            for channel in 0..<3 { destination[pixel * 4 + channel] = rgb[pixel * 3 + channel] }
                            destination[pixel * 4 + 3] = alpha[pixel]
                        }
                    }
                }
            }
            return Artwork(rgba: rgba, normals: normal)
        }
        // Offline generation/review tools can still read old material files.
        // A corrupt new catalog must fail, not fall back to a different material.
        guard let file = url(resource, "jdmaterial"), let packed = try? Data(contentsOf: file),
              let bytes = decompress(packed, count: width * height * 7) else { return nil }
        let split = width * height * 4
        return Artwork(rgba: Array(bytes[..<split]), normals: Array(bytes[split...]))
    }

    static func decode(_ packed: Data, width: Int, height: Int, map: Map) -> [UInt8]? {
        guard width > 0, width <= 1024, height > 0, height <= 512,
              map.channels == 1 || map.channels == 3,
              !map.greenDifference || map.channels == 3,
              var bytes = decompress(packed, count: width * height * map.channels) else { return nil }
        let channels = map.channels, stride = width * channels
        // Undo spatial prediction first, in the decorrelated colour space.
        // Using original RGB neighbours here would silently change the artwork.
        // The buffers have already been validated to exactly width*height*channels.
        // Mutate through one buffer borrow, avoiding repeated array uniqueness checks.
        bytes.withUnsafeMutableBufferPointer { bytes in
            switch map.filter {
            case .raw: break
            case .sub:
                for row in 0..<height {
                    for i in (row * stride + channels)..<((row + 1) * stride) {
                        bytes[i] = bytes[i] &+ bytes[i - channels]
                    }
                }
            case .up:
                for i in stride..<bytes.count { bytes[i] = bytes[i] &+ bytes[i - stride] }
            case .paeth:
                for row in 0..<height {
                    for column in 0..<stride {
                        let i = row * stride + column
                        let left = column >= channels ? bytes[i - channels] : 0
                        let up = row > 0 ? bytes[i - stride] : 0
                        let corner = row > 0 && column >= channels ? bytes[i - stride - channels] : 0
                        bytes[i] = bytes[i] &+ paeth(left, up, corner)
                    }
                }
            }
            if map.greenDifference {
                for i in Swift.stride(from: 0, to: bytes.count, by: 3) {
                    bytes[i] = bytes[i] &+ bytes[i + 1]
                    bytes[i + 2] = bytes[i + 2] &+ bytes[i + 1]
                }
            }
        }
        return bytes
    }

    static func paeth(_ left: UInt8, _ up: UInt8, _ corner: UInt8) -> UInt8 {
        let a = Int(left), b = Int(up), c = Int(corner), p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? left : (pb <= pc ? up : corner)
    }

    private static func decompress(_ data: Data, count: Int) -> [UInt8]? {
        guard !data.isEmpty, data.count <= count * 2 + 4096 else { return nil }
        // The extra byte detects oversized output instead of accepting a prefix.
        // No decompression allocation can grow beyond the expected map size.
        var bytes = [UInt8](repeating: 0, count: count + 1)
        let length = bytes.withUnsafeMutableBufferPointer { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard length == count else { return nil }
        bytes.removeLast()
        return bytes
    }
}
