// BEFORE_FOLDER AFTER_FOLDER OUTPUT.json
// Compare every numeric alpha value, frame timestamp and crop/camera record.
import Compression
import Foundation

private struct AlphaFrame: Decodable {
    let time: Double
    let offset: Int
    let length: Int
    let compressed: Bool
}
private struct AlphaIndex: Decodable {
    let version: Int
    let width: Int
    let height: Int
    let frames: [AlphaFrame]
}
private struct Cache {
    let index: AlphaIndex
    let data: Data
    init(_ folder: URL) throws {
        index = try JSONDecoder().decode(AlphaIndex.self, from: Data(contentsOf: folder.appendingPathComponent("alpha-index.json")))
        data = try Data(contentsOf: folder.appendingPathComponent("alpha.lzfse"), options: .mappedIfSafe)
    }
    func pixels(_ frame: AlphaFrame) throws -> [UInt8] {
        guard frame.offset >= 0, frame.length > 0, frame.offset + frame.length <= data.count else { throw CheckError.invalidCache }
        var pixels = [UInt8](repeating: 0, count: index.width * index.height)
        if frame.compressed {
            let count = pixels.withUnsafeMutableBufferPointer { destination in
                data.withUnsafeBytes { source in
                    compression_decode_buffer(destination.baseAddress!, destination.count,
                        source.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: frame.offset),
                        frame.length, nil, COMPRESSION_LZFSE)
                }
            }
            guard count == pixels.count else { throw CheckError.invalidCache }
        } else {
            guard frame.length == pixels.count else { throw CheckError.invalidCache }
            data.copyBytes(to: &pixels, from: frame.offset..<(frame.offset + frame.length))
        }
        return pixels
    }
}
private enum CheckError: Error { case invalidCache, incompatibleCaches }

@main struct ComparePreparedCutouts {
    static func main() throws {
        let args = CommandLine.arguments
        let before = URL(fileURLWithPath: args[1]), after = URL(fileURLWithPath: args[2])
        let a = try Cache(before), b = try Cache(after)
        guard a.index.version == b.index.version, a.index.width == b.index.width, a.index.height == b.index.height,
              a.index.frames.map(\.time) == b.index.frames.map(\.time) else { throw CheckError.incompatibleCaches }
        var changedPixels = 0, changedFrames = 0, totalDifference: UInt64 = 0, maxDifference = 0
        for (old, new) in zip(a.index.frames, b.index.frames) {
            let x = try a.pixels(old), y = try b.pixels(new)
            var changed = false
            for i in x.indices {
                let difference = abs(Int(x[i]) - Int(y[i]))
                if difference != 0 { changedPixels += 1; changed = true }
                totalDifference += UInt64(difference)
                maxDifference = max(maxDifference, difference)
            }
            if changed { changedFrames += 1 }
        }
        func recordsMatch(_ name: String) throws -> Bool {
            let x = try JSONSerialization.jsonObject(with: Data(contentsOf: before.appendingPathComponent(name)))
            let y = try JSONSerialization.jsonObject(with: Data(contentsOf: after.appendingPathComponent(name)))
            return (x as AnyObject).isEqual(y)
        }
        let pixels = a.index.width * a.index.height * a.index.frames.count
        let report: [String: Any] = ["frames": a.index.frames.count,
            "maskWidth": a.index.width, "maskHeight": a.index.height, "comparedPixels": pixels,
            "changedPixels": changedPixels, "changedFrames": changedFrames,
            "maxAlphaDifference": maxDifference, "meanAlphaDifference": Double(totalDifference) / Double(pixels),
            "frameTimesIdentical": true, "cropAndCameraIdentical": try recordsMatch("scene.json"),
            "cutoutDiagnosticsIdentical": try recordsMatch("cutout-frames.json")]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: URL(fileURLWithPath: args[3]))
        print(String(decoding: json, as: UTF8.self))
    }
}
