import CryptoKit
import Foundation
import XCTest
@testable import kicklab

final class BallMaterialStorageTests: XCTestCase {
    private func packed(_ bytes: [UInt8]) throws -> Data {
        try (Data(bytes) as NSData).compressed(using: .lzfse) as Data
    }

    func testEveryBundledMaterialRestoresOriginalBytesWithoutLegacyDuplicates() throws {
        // SHA256 of complete RGBA+normal arrays from the original build 77 materials.
        let originals: [(String, String)] = [
            ("arctic", "0cfc5a56262e53972b960d63d3b193b92b5f90aa1481840a2c5bbba3cd0a7d26"),
            ("aurora", "ea7baa1bef3e2986ad8f4e7340d4efa64fb6d72031fdf6f597f127a284e22f96"),
            ("chrome", "44857dd39affc0f1e955e3c368ad38fcf5c14c9582984e9ffeba9f375ad5fcb9"),
            ("classic", "91d67f71a7652b1342080c4079c607583bc206c3a9a67ebb7b798816a16c3b5c"),
            ("crimson", "704118e1a0e76a5dc8bf80ab26b3dbb60125a5deaed6541cf819485851677269"),
            ("galaxy", "59155730d1831ef6973c131543a1ff459d8e96ef86541ece9181f6c249e695a3"),
            ("gold", "3a4910b6b610b01b8a3f6c4d1fb49302a1c7a8aebd7cfda83708bc9ed02d63c5"),
            ("graffiti", "4364f0ed1bf27581a35439f5e1b2a48c1facdc7245e93036e7e234acdb136427"),
            ("lava", "aed2c95d63aaca61a4bae3e108fcb57d67c7cf720495e5ec3924432d160d432e"),
            ("matrix", "e90e54bfa75f35812b15188149801648f4d29ebeea460bed32124999bc07d1fb"),
            ("metal", "855e1f8f07085904ab94b9f32c6e7808a2dbe6d9e5c44adcc02bc41c88762bd8"),
            ("pearl", "e836f15ba260f7acd6fecc46791af4523d686707c52d4c07a4578d92f8c25b01"),
            ("stealth", "9843c2cc78585cb5013c184a71cd36b72f9fec783f1dcdf6a1b3c500a19464fb"),
            ("volt", "d6eba85df361869e9b251dce61ea93e409e882599b67c8dd17a75340e335d113"),
        ]
        XCTAssertEqual(originals.count, BallSkin.allCases.filter { $0 != .original && !$0.isLabSkin }.count)
        for (name, expected) in originals {
            let skin = try XCTUnwrap(BallSkin(rawValue: name))
            let artwork = try XCTUnwrap(BallCollectionMaterial.artwork(skin: skin,
                width: 1024, height: 512, panelSites: []), name)
            let bytes = Data(artwork.rgba + artwork.normals)
            XCTAssertEqual(bytes.count, 1024 * 512 * 7, name)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected, name)
            XCTAssertNil(Bundle.main.url(forResource: skin.materialResource, withExtension: "jdmaterial"))
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ball-materials", withExtension: "json"))
        let catalog = try JSONDecoder().decode(BallMaterialStorage.Catalog.self, from: Data(contentsOf: url))
        XCTAssertEqual(catalog.materials.count, originals.count)
        XCTAssertEqual(catalog.maps.count, 29, "The 42 source maps contain 13 exact duplicates")
    }

    func testPredictorsRestoreKnownBytesIncludingWrappingAndRowBoundaries() throws {
        let original: [UInt8] = [20, 250, 5, 40]
        let cases: [(BallMaterialStorage.Filter, [UInt8])] = [
            (.raw, original), (.sub, [20, 230, 5, 35]),
            (.up, [20, 250, 241, 46]), (.paeth, [20, 230, 241, 46])
        ]
        for (filter, bytes) in cases {
            let map = BallMaterialStorage.Map(channels: 1, filter: filter, greenDifference: false)
            XCTAssertEqual(BallMaterialStorage.decode(try packed(bytes), width: 2, height: 2, map: map), original)
        }
        let color = BallMaterialStorage.Map(channels: 3, filter: .sub, greenDifference: true)
        XCTAssertEqual(BallMaterialStorage.decode(try packed([26, 250, 11, 9, 11, 239]),
            width: 2, height: 1, map: color), [20, 250, 5, 40, 5, 255])
    }

    func testMalformedAndOversizedMapsFailWithBoundedOutput() throws {
        let map = BallMaterialStorage.Map(channels: 1, filter: .raw, greenDifference: false)
        XCTAssertNil(BallMaterialStorage.decode(Data([1, 2, 3]), width: 2, height: 2, map: map))
        XCTAssertNil(BallMaterialStorage.decode(try packed([1, 2, 3]), width: 2, height: 2, map: map))
        XCTAssertNil(BallMaterialStorage.decode(try packed([1, 2, 3, 4, 5]), width: 2, height: 2, map: map))
        XCTAssertNil(BallMaterialStorage.decode(try packed([1]), width: Int.max, height: Int.max, map: map))
        XCTAssertNil(BallMaterialStorage.decode(try packed([1]), width: 0, height: 1, map: map))
        XCTAssertNil(BallMaterialStorage.decode(try packed([1]), width: 1, height: 1,
            map: .init(channels: 1, filter: .raw, greenDifference: true)))
        let valid = try packed(Array(repeating: UInt8(10), count: 100))
        XCTAssertNil(BallMaterialStorage.decode(Data(valid.prefix(valid.count / 2)), width: 10, height: 10, map: map))
    }

    func testExternalLegacyWorksButBrokenCatalogDoesNotFallBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try packed([1, 2, 3, 4, 5, 6, 7]).write(to: directory.appendingPathComponent("test.jdmaterial"))
        let old = try XCTUnwrap(BallMaterialStorage.load(resource: "test", width: 1, height: 1, directory: directory))
        XCTAssertEqual(old.rgba, [1, 2, 3, 4])
        XCTAssertEqual(old.normals, [5, 6, 7])
        try Data("broken".utf8).write(to: directory.appendingPathComponent("ball-materials.json"))
        XCTAssertNil(BallMaterialStorage.load(resource: "test", width: 1, height: 1, directory: directory))
        let catalog = BallMaterialStorage.Catalog(version: 2, width: 1, height: 1, materials: [:], maps: [:])
        try JSONEncoder().encode(catalog).write(to: directory.appendingPathComponent("ball-materials.json"))
        XCTAssertNil(BallMaterialStorage.load(resource: "test", width: 1, height: 1, directory: directory))
    }
}
