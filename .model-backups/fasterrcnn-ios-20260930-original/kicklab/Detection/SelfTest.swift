//
//  SelfTest.swift
//  kicklab
//
//  Run the model on an image built in code: no camera, no video, no rotation.
//
//  This is the check that has settled every argument so far. When Live and File
//  both reported a ball in every frame, this said 0.0081 on flat grey against the
//  lab's 0.008 - proving the model was fine and the decoding was not.
//

import CoreML
import Foundation

struct SelfTestResult {
    var ballScore: Double
    var personScore: Double
    var ballBox: String
    var outputCount: Int
    var shape: String
    var strides: String
    var dataType: String
    var notes: String
}

enum SelfTest {
    /// Expected ball score on flat grey, measured in the lab: ~0.008.
    static let expectedGreyBallScore = 0.008

    static func runGrey(value: Float = 0.5) throws -> SelfTestResult {
        let side = 320
        let model = try loadModel()

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
                                     dataType: .float32)
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(input.dataPointer))
        for i in 0..<(3 * side * side) { ptr[i] = value }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: provider)

        guard let result = out.featureValue(for: "detection")?.multiArrayValue else {
            throw NSError(domain: "KickLab", code: 20,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "no 'detection' output - is the bundled model stale?"])
        }

        let ball = Double(result[0].floatValue)
        let person = Double(result[5].floatValue)
        let box = (1...4).map { String(format: "%.3f", result[$0].floatValue) }
            .joined(separator: ", ")

        let notes: String
        if abs(ball - expectedGreyBallScore) > 0.05 {
            notes = "DISAGREES with the lab (~0.008) - model or input handling is wrong"
        } else {
            notes = "matches the lab - model and decoding are correct"
        }

        return SelfTestResult(
            ballScore: ball,
            personScore: person,
            ballBox: box,
            outputCount: result.count,
            shape: result.shape.map(\.stringValue).joined(separator: "x"),
            strides: result.strides.map(\.stringValue).joined(separator: ","),
            dataType: "\(result.dataType.rawValue)",
            notes: notes)
    }

    private static func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: "KickLabDetector", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "KickLabDetector", withExtension: "mlpackage") else {
            throw NSError(domain: "KickLab", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "model not in bundle"])
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: config)
    }
}
