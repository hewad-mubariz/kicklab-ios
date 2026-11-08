// xcrun swift scripts/pack-lab-assets.swift pack <input.bin> <output.bin.lzfse>
// xcrun swift scripts/pack-lab-assets.swift unpack <input.bin.lzfse> <output.bin>
// No format/resolution changes: packing must round-trip to the exact original bytes.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, ["pack", "unpack"].contains(arguments[1]) else {
    fatalError("Usage: pack-lab-assets.swift pack|unpack input output")
}
let input = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
let output: Data
if arguments[1] == "pack" {
    output = try (input as NSData).compressed(using: .lzfse) as Data
    guard try (output as NSData).decompressed(using: .lzfse) as Data == input else {
        fatalError("Lossless round-trip failed")
    }
} else {
    output = try (input as NSData).decompressed(using: .lzfse) as Data
}
try output.write(to: URL(fileURLWithPath: arguments[3]), options: .atomic)
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
print("\(input.count) -> \(output.count) bytes")
print("Input SHA256: \(hash(input))")
print("Output SHA256: \(hash(output))")
