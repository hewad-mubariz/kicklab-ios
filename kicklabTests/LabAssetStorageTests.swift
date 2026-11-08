import CryptoKit
import Foundation
import Metal
import simd
import UIKit
import XCTest
@testable import kicklab

final class LabAssetStorageTests: XCTestCase {
    /// Hashes of the raw resources in the shipped build 77 archive, before compression.
    func testBundledAssetsRestoreTheOriginalRenderingDataWithoutShippingRawDuplicates() throws {
        let originals: [(String, Int, String)] = [
            ("gold-environment", 5_592_408, "a0196bc4e7722fb0a79c8c7368ec306d67bf9329b0b115e678fe8cbb04a4b852"),
            ("studio-environment", 5_592_408, "f2c76c99ebc2a8d01314a5473b797a079b4297b451be3709411dc42ab1d30783"),
            ("ice-fracture-triangles", 2_764_800, "82f8d787850936079dd041958f0c398ec346d2b08f6c6044c18cb1071173cef7"),
            ("ice-fracture-bvh", 687_792, "93c9624e1893a78a1cbd339c76c6f4081f87b82e44ea7ea6322a467b29917cb6")
        ]
        for (name, count, hash) in originals {
            XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "bin.lzfse"), name)
            XCTAssertNil(Bundle.main.url(forResource: name, withExtension: "bin"), name)
            let start = ProcessInfo.processInfo.systemUptime
            let data = try LabAssetData.load(name)
            print("LAB_ASSET_DECODE \(name): \((ProcessInfo.processInfo.systemUptime - start) * 1000) ms")
            XCTAssertEqual(data.count, count, name)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), hash, name)
        }
    }

    func testExternalRawAssetsStillLoadAndCorruptPackedDataFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = Data([1, 2, 3, 4])
        try raw.write(to: directory.appendingPathComponent("sample.bin"))
        XCTAssertEqual(try LabAssetData.load("sample", directory: directory), raw)
        // A broken packed asset must report failure, not silently hide it with a raw fallback.
        try Data([0xff, 0x01, 0x55]).write(to: directory.appendingPathComponent("sample.bin.lzfse"))
        XCTAssertThrowsError(try LabAssetData.load("sample", directory: directory))
        XCTAssertThrowsError(try LabAssetData.load("missing", directory: directory))
    }

    func testBundledGoldAndSurfaceSkinsStillRender() throws {
        let renderer = try XCTUnwrap(LabSkinRenderer.shared)
        for skin: BallSkin in [.goldPolish, .prism, .wave, .nightPulse] {
            let image = try XCTUnwrap(renderer.image(skin: skin,
                orientation: simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))), size: 128))
            let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertTrue(bytes.contains { $0 != 0 }, skin.rawValue)
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "Packed assets - \(skin.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
