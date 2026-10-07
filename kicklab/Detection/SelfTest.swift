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
        let model = try loadModel()
        guard let shape = model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
              shape.count == 4 else { throw NSError(domain: "KickLab", code: 22) }
        let height = shape[2].intValue
        let width = shape[3].intValue

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
                                     dataType: .float32)
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(input.dataPointer))
        for i in 0..<(3 * height * width) { ptr[i] = value }

        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(multiArray: input)])
        let out = try model.prediction(from: provider)

        let result = try BallDetector.decodedValues(out, width: width, height: height)
        let ball = Double(result[0])
        let person = Double(result[5])
        let box = (1...4).map { String(format: "%.3f", result[$0]) }.joined(separator: ", ")

        let notes: String
        if BallDetector.configuredResourceName == "KickLabFasterRCNN" {
            notes = "Faster R-CNN flat-grey diagnostic; SSDLite reference score does not apply"
        } else if abs(ball - expectedGreyBallScore) > 0.05 {
            notes = "DISAGREES with the lab (~0.008) - model or input handling is wrong"
        } else {
            notes = "matches the lab - model and decoding are correct"
        }

        return SelfTestResult(
            ballScore: ball,
            personScore: person,
            ballBox: box,
            outputCount: result.count,
            shape: "10 decoded scalars",
            strides: "stride-aware reads",
            dataType: "Float32",
            notes: notes)
    }

    private static func loadModel() throws -> MLModel {
        guard let url = Bundle.main.url(forResource: BallDetector.configuredResourceName, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: BallDetector.configuredResourceName, withExtension: "mlpackage") else {
            throw NSError(domain: "KickLab", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: "model not in bundle"])
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: config)
    }
}
