// Build: xcrun swiftc -O kicklab/Effects/BallMaterialStorage.swift scripts/pack-ball-materials.swift -o /tmp/pack-ball-materials
// Usage: pack-ball-materials pack|unpack <input-directory> <new-output-directory>
// A complete catalog is packed together so shared maps are stored only once.
import CryptoKit
import Foundation

@main enum PackBallMaterials {
    static let width = 1024, height = 512
    static let pixels = width * height
    static func hash(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
    static func compressed(_ bytes: [UInt8]) throws -> Data {
        try (Data(bytes) as NSData).compressed(using: .lzfse) as Data
    }
    static func filtered(_ source: [UInt8], map: BallMaterialStorage.Map) -> [UInt8] {
        var bytes = source
        if map.greenDifference {
            for i in stride(from: 0, to: bytes.count, by: 3) {
                bytes[i] = bytes[i] &- bytes[i + 1]
                bytes[i + 2] = bytes[i + 2] &- bytes[i + 1]
            }
        }
        guard map.filter != .raw else { return bytes }
        let original = bytes, channels = map.channels, rowSize = width * channels
        for row in 0..<height { for column in 0..<rowSize {
            let i = row * rowSize + column
            let left = column >= channels ? original[i - channels] : 0
            let up = row > 0 ? original[i - rowSize] : 0
            let corner = row > 0 && column >= channels ? original[i - rowSize - channels] : 0
            let prediction: UInt8
            switch map.filter {
            case .raw: prediction = 0
            case .sub: prediction = left
            case .up: prediction = up
            case .paeth: prediction = BallMaterialStorage.paeth(left, up, corner)
            }
            bytes[i] = original[i] &- prediction
        } }
        return bytes
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, ["pack", "unpack"].contains(args[1]) else {
            fatalError("Usage: pack-ball-materials pack|unpack input-directory new-output-directory")
        }
        let input = URL(fileURLWithPath: args[2]), output = URL(fileURLWithPath: args[3])
        // Never overwrite source art or silently leave obsolete maps in a pack.
        guard !FileManager.default.fileExists(atPath: output.path) else {
            fatalError("Output must be a new directory")
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if args[1] == "unpack" {
            let catalog = try JSONDecoder().decode(BallMaterialStorage.Catalog.self,
                from: Data(contentsOf: input.appendingPathComponent("ball-materials.json")))
            for name in catalog.materials.keys.sorted() {
                guard let artwork = BallMaterialStorage.load(resource: name, width: width, height: height, directory: input) else {
                    fatalError("Could not decode \(name)")
                }
                try compressed(artwork.rgba + artwork.normals).write(to: output.appendingPathComponent(name + ".jdmaterial"))
            }
            print("Restored \(catalog.materials.count) lossless legacy materials")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jdmaterial" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { fatalError("No source .jdmaterial files found") }
        var maps: [String: BallMaterialStorage.Map] = [:]
        var materials: [String: BallMaterialStorage.Material] = [:]
        var originalHashes: [String: String] = [:]
        var packedBytes = 0, originalBytes = 0
        func store(_ bytes: [UInt8], channels: Int, isColor: Bool = false) throws -> String {
            let key = hash(bytes)
            if maps[key] != nil { return key }
            var best: (BallMaterialStorage.Map, Data)?
            for green in isColor ? [false, true] : [false] {
                for filter in BallMaterialStorage.Filter.allCases {
                    let map = BallMaterialStorage.Map(channels: channels, filter: filter, greenDifference: green)
                    let data = try compressed(filtered(bytes, map: map))
                    // Verify every candidate, including filters not selected this time.
                    guard BallMaterialStorage.decode(data, width: width, height: height, map: map) == bytes else {
                        fatalError("Round-trip mismatch: \(key), \(filter), green \(green)")
                    }
                    if best == nil || data.count < best!.1.count { best = (map, data) }
                }
            }
            let (map, data) = best!
            maps[key] = map
            packedBytes += data.count
            try data.write(to: output.appendingPathComponent("ball-map-\(key).jdmap"), options: .atomic)
            return key
        }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let artwork = BallMaterialStorage.load(resource: name, width: width, height: height, directory: input) else {
                fatalError("Could not decode \(name)")
            }
            originalBytes += try Data(contentsOf: file).count
            originalHashes[name] = hash(artwork.rgba + artwork.normals)
            var color = [UInt8](repeating: 0, count: pixels * 3), seam = [UInt8](repeating: 0, count: pixels)
            for pixel in 0..<pixels {
                for c in 0..<3 { color[pixel * 3 + c] = artwork.rgba[pixel * 4 + c] }
                seam[pixel] = artwork.rgba[pixel * 4 + 3]
            }
            materials[name] = try BallMaterialStorage.Material(color: store(color, channels: 3, isColor: true),
                seam: store(seam, channels: 1), normal: store(artwork.normals, channels: 3))
        }
        let catalog = BallMaterialStorage.Catalog(version: 1, width: width, height: height, materials: materials, maps: maps)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifest = try encoder.encode(catalog)
        try manifest.write(to: output.appendingPathComponent("ball-materials.json"), options: .atomic)
        // Exercise the production loader and the manifest, not only the codec.
        for name in materials.keys.sorted() {
            guard let artwork = BallMaterialStorage.load(resource: name, width: width, height: height, directory: output),
                  hash(artwork.rgba + artwork.normals) == originalHashes[name] else {
                fatalError("Production loader mismatch: \(name)")
            }
        }
        print("\(materials.count) materials, \(maps.count) unique maps; all decoded bytes identical")
        print("\(originalBytes) -> \(packedBytes + manifest.count) bytes including manifest")
    }
}
