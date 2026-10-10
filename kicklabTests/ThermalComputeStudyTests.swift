import AVFoundation
import CoreML
import CryptoKit
import Darwin
import XCTest
@testable import kicklab

/// Explicit physical-device experiment. Never changes production compute units.
@MainActor
final class ThermalComputeStudyTests: XCTestCase {
    private func cpuSeconds() -> Double {
        var value = rusage(); _ = getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    private func hashes(_ output: MLFeatureProvider) -> [String: String] {
        var result = [String: String]()
        for name in output.featureNames {
            guard let array = output.featureValue(for: name)?.multiArrayValue else { continue }
            var stride = 1, contiguous = true
            for index in array.shape.indices.reversed() {
                if array.strides[index].intValue != stride { contiguous = false }
                stride *= array.shape[index].intValue
            }
            var hash = SHA256()
            if contiguous {
                let bytes = array.dataType == .float16 ? 2 : array.dataType == .double ? 8 : 4
                hash.update(data: Data(bytesNoCopy: array.dataPointer, count: array.count * bytes, deallocator: .none))
            } else {
                for index in 0..<array.count {
                    var value = array[index].doubleValue
                    withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
                }
            }
            result[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }

    func testPhysicalComputePlacementStudy() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Compute placement and timing require the physical phone")
        #else
        let url = try XCTUnwrap(Bundle.main.url(forResource: BallDetector.productionResourceName, withExtension: "mlmodelc"))
        let source = try XCTUnwrap(Bundle(for: type(of: self)).url(forResource: "juggling-eighteen", withExtension: "mov"))
        var placement = [String: [[String: Any]]]()
        for (name, units) in [("all", MLComputeUnits.all), ("cpu-ne", .cpuAndNeuralEngine)] {
            let configuration = MLModelConfiguration(); configuration.computeUnits = units
            let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
            var rows = [[String: Any]]()
            if case .program(let program) = plan.modelStructure {
                func visit(_ block: MLModelStructure.Program.Block) {
                    for operation in block.operations {
                        if let usage = plan.deviceUsage(for: operation) {
                            rows.append(["operation": operation.operatorName,
                                "preferred": usage.preferred.description,
                                "estimated_cost": plan.estimatedCost(of: operation)?.weight ?? 0])
                        }
                        for nested in operation.blocks { visit(nested) }
                    }
                }
                for function in program.functions.values { visit(function.block) }
            }
            placement[name] = rows
        }
        let detector = try BallDetector()
        let asset = AVURLAsset(url: source), reader = try AVAssetReader(asset: asset)
        let video = try await asset.loadTracks(withMediaType: .video)[0]
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: video, duration: asset.load(.duration), shortEdge: 720)
        output.alwaysCopiesSampleData = false; reader.add(output); XCTAssertTrue(reader.startReading())
        var inputs = [MLFeatureProvider](), index = 0
        while inputs.count < 16, let buffer = output.copyNextSampleBuffer() {
            if index % 30 == 0, let pixels = CMSampleBufferGetImageBuffer(buffer) {
                inputs.append(try autoreleasepool { try detector.reviewInput(pixels) })
            }
            index += 1
        }
        reader.cancelReading(); XCTAssertEqual(inputs.count, 16)
        var models = [String: MLModel]()
        for (name, units) in [("all", MLComputeUnits.all), ("cpu-ne", .cpuAndNeuralEngine)] {
            let configuration = MLModelConfiguration(); configuration.computeUnits = units
            models[name] = try MLModel(contentsOf: url, configuration: configuration)
            _ = try autoreleasepool { try models[name]!.prediction(from: inputs[0]) }
        }
        let reference = try inputs.map { input in try autoreleasepool { hashes(try models["all"]!.prediction(from: input)) } }
        var rows = [[String: Any]]()
        for (round, order) in [["all", "cpu-ne"], ["cpu-ne", "all"], ["all", "cpu-ne"]].enumerated() {
            for name in order {
                let thermal = ProcessInfo.processInfo.thermalState.rawValue
                var prediction = 0.0, cpu = 0.0, hashTime = 0.0, changed = [Int]()
                for (i, input) in inputs.enumerated() {
                    try autoreleasepool {
                        let start = ProcessInfo.processInfo.systemUptime, beforeCPU = cpuSeconds()
                        let result = try models[name]!.prediction(from: input)
                        prediction += ProcessInfo.processInfo.systemUptime - start
                        cpu += cpuSeconds() - beforeCPU
                        let hashStart = ProcessInfo.processInfo.systemUptime
                        if hashes(result) != reference[i] { changed.append(i) }
                        hashTime += ProcessInfo.processInfo.systemUptime - hashStart
                    }
                }
                rows.append(["round": round, "units": name, "prediction_s": prediction,
                    "prediction_cpu_s": cpu, "output_hash_s": hashTime,
                    "changed_inputs": changed, "thermal": thermal])
            }
        }
        try JSONSerialization.data(withJSONObject: ["placement": placement, "rows": rows,
            "scope": "16 immutable real frame tensors, three rotated rounds. Compute-plan cost weights are estimates, not actual energy. Prediction and diagnostic hashing timed separately. Production remains all."], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("thermal-compute-study.json"))
        #endif
    }
}
