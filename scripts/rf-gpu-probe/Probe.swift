import CoreML
import Foundation
import ImageIO
import Metal
import SwiftUI

@main struct RFModelProbeApp: App {
    @State private var status = "Starting isolated model check…"
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Juggle Model Check").font(.title)
                Text(status).monospaced().multilineTextAlignment(.center)
                Text("Keep this screen open. No camera or account data is used.").font(.footnote)
            }.padding().task {
                UIApplication.shared.isIdleTimerDisabled = true
                await Task.detached(priority: .userInitiated) {
                    let probe = Probe()
                    await probe.run { value in await MainActor.run { status = value } }
                }.value
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }
}

private final class Probe: @unchecked Sendable {
    let root = URL.documentsDirectory
    var report: [String: Any] = [:]
    var trials: [[String: Any]] = []
    struct Variant {
        let name: String, model: String, function: String?
        let compute: MLComputeUnits
        var lowPrecision = false
        var fastPrediction = false
    }
    struct Snapshot {
        let score: Double, box: [Double], mask: [UInt8]
        var json: [String: Any] { ["score": score, "box": box, "mask": Data(mask).base64EncodedString()] }
    }
    func save(_ status: String) {
        report["status"] = status; report["trials"] = trials
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("report.json"), options: .atomic)
        }
    }
    func conditions() async -> [String: Any] {
        await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return ["thermal": ProcessInfo.processInfo.thermalState.rawValue,
                    "low_power": ProcessInfo.processInfo.isLowPowerModeEnabled,
                    "battery_state": UIDevice.current.batteryState.rawValue,
                    "foreground": UIApplication.shared.applicationState == .active]
        }
    }
    func run(status: @escaping @Sendable (String) async -> Void) async {
        report = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                  "started": Date().ISO8601Format(), "input_edge": 288,
                  "scope": "12 fixed development video stills, two warmups; inference timings exclude input preparation and output comparison."]
        do {
            report["metal_control"] = try metalControl()
            let inputs = try (0..<12).map { try input(index: $0) }
            var baseline: [Snapshot] = []
            var variants = [
                Variant(name: "original-cpu", model: "RFDETRSmallRecovery040FP16", function: "rf288", compute: .cpuOnly),
                Variant(name: "original-gpu", model: "RFDETRSmallRecovery040FP16", function: "rf288", compute: .cpuAndGPU),
                Variant(name: "original-gpu-low-precision", model: "RFDETRSmallRecovery040FP16", function: "rf288", compute: .cpuAndGPU, lowPrecision: true),
                Variant(name: "original-gpu-fast-prediction", model: "RFDETRSmallRecovery040FP16", function: "rf288", compute: .cpuAndGPU, fastPrediction: true),
                Variant(name: "single-function-gpu", model: "RF288Single", function: nil, compute: .cpuAndGPU),
                Variant(name: "compat-cpu", model: "RF288Compat", function: nil, compute: .cpuOnly),
                Variant(name: "compat-gpu", model: "RF288Compat", function: nil, compute: .cpuAndGPU),
                Variant(name: "original-cpu-repeat", model: "RFDETRSmallRecovery040FP16", function: "rf288", compute: .cpuOnly)
            ]
            if ProcessInfo.processInfo.arguments.contains("--ne") {
                variants = [variants[0],
                    Variant(name: "original-gpu-default-function", model: "RFDETRSmallRecovery040FP16", function: nil, compute: .cpuAndGPU),
                    Variant(name: "original-cpu-ne", model: "RFDETRSmallRecovery040FP16", function: nil, compute: .cpuAndNeuralEngine),
                    Variant(name: "original-all", model: "RFDETRSmallRecovery040FP16", function: nil, compute: .all),
                    variants.last!]
            }
            for variant in variants {
                let startConditions = await conditions()
                guard startConditions["foreground"] as? Bool == true else { throw failure("App left foreground") }
                guard ProcessInfo.processInfo.thermalState.rawValue < 2 else { throw failure("Thermal pressure; stop before comparing hot runs") }
                await status(variant.name)
                report["active_variant"] = variant.name; save("running")
                var trial: [String: Any] = ["variant": variant.name, "start": startConditions]
                do {
                    let outcome = try autoreleasepool { () -> ([Double], [Snapshot], Double) in
                        let configuration = MLModelConfiguration()
                        configuration.computeUnits = variant.compute
                        configuration.functionName = variant.function
                        configuration.allowLowPrecisionAccumulationOnGPU = variant.lowPrecision
                        if variant.fastPrediction { configuration.optimizationHints.specializationStrategy = .fastPrediction }
                        let url = Bundle.main.url(forResource: variant.model, withExtension: "mlmodelc")!
                        let loadStart = ProcessInfo.processInfo.systemUptime
                        let model = try MLModel(contentsOf: url, configuration: configuration)
                        let loadMS = (ProcessInfo.processInfo.systemUptime - loadStart) * 1000
                        for _ in 0..<2 { _ = try model.prediction(from: inputs[0]) }
                        var times: [Double] = [], snapshots: [Snapshot] = []
                        for input in inputs {
                            let (time, sample) = try autoreleasepool { () -> (Double, Snapshot) in
                                let start = ProcessInfo.processInfo.systemUptime
                                let output = try model.prediction(from: input)
                                let time = (ProcessInfo.processInfo.systemUptime - start) * 1000
                                return (time, try snapshot(output))
                            }
                            times.append(time); snapshots.append(sample)
                        }
                        return (times, snapshots, loadMS)
                    }
                    trial["load_ms"] = outcome.2
                    trial["prediction_ms"] = outcome.0
                    let ordered = outcome.0.sorted()
                    trial["median_ms"] = (ordered[5] + ordered[6]) / 2
                    trial["samples"] = outcome.1.map(\.json)
                    if baseline.isEmpty { baseline = outcome.1 }
                    var maxScore = 0.0, maxBox = 0.0, minIoU = 1.0, flips: [Int] = []
                    for (i, pair) in zip(baseline, outcome.1).enumerated() {
                        maxScore = max(maxScore, abs(pair.0.score - pair.1.score))
                        for (a,b) in zip(pair.0.box,pair.1.box) { maxBox = max(maxBox,abs(a-b)) }
                        let intersection = zip(pair.0.mask,pair.1.mask).filter { $0.0 == 1 && $0.1 == 1 }.count
                        let union = zip(pair.0.mask,pair.1.mask).filter { $0.0 == 1 || $0.1 == 1 }.count
                        if union > 0 { minIoU = min(minIoU,Double(intersection)/Double(union)) }
                        if (pair.0.score >= 0.4) != (pair.1.score >= 0.4) { flips.append(i) }
                    }
                    trial["parity"] = ["max_score_delta": maxScore, "max_box_delta": maxBox, "minimum_mask_iou": minIoU, "threshold_flips": flips]
                    trial["status"] = "completed"
                } catch {
                    trial["status"] = "failed"; trial["error"] = describe(error)
                }
                trial["end"] = await conditions(); trials.append(trial); save("running")
            }
            report["finished"] = Date().ISO8601Format(); save("completed"); await status("Finished. Results saved.")
        } catch { report["error"] = describe(error); save("stopped"); await status("Stopped: \(error.localizedDescription)") }
    }
    func failure(_ text: String) -> NSError { NSError(domain: "RFModelProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func describe(_ error: Error, depth: Int = 0) -> [String: Any] {
        let e = error as NSError
        var result: [String: Any] = ["domain": e.domain, "code": e.code, "description": e.localizedDescription,
                                   "reason": e.localizedFailureReason ?? "", "details": String(describing: e.userInfo)]
        if depth < 4, let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { result["underlying"] = describe(underlying, depth: depth+1) }
        return result
    }
    func input(index: Int) throws -> MLFeatureProvider {
        let url = Bundle.main.url(forResource: String(format: "frame-%02d", index), withExtension: "png")!
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let array = try MLMultiArray(shape: [1,3,288,288], dataType: .float32)
        bytes.withUnsafeMutableBytes { pointer in
            let context = CGContext(data: pointer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            RFInputNormalization.normalizeBGRA(pointer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                width: image.width, height: image.height, rowBytes: image.width*4,
                into: array.dataPointer.assumingMemoryBound(to: Float.self), edge: 288)
        }
        return try MLDictionaryFeatureProvider(dictionary: ["tensors": array])
    }
    func snapshot(_ out: MLFeatureProvider) throws -> Snapshot {
        let logits = out.featureValue(for: "linear_122")!.multiArrayValue!
        let boxes = out.featureValue(for: "concat_2")!.multiArrayValue!
        let masks = out.featureValue(for: "add_62")!.multiArrayValue!
        var q = 0, score = -Double.infinity
        for i in 0..<100 {
            let value = 1 / (1 + exp(-logits[[0,NSNumber(value:i),37]].doubleValue))
            if value > score { q = i; score = value }
        }
        let box = (0..<4).map { boxes[[0,NSNumber(value:q),NSNumber(value:$0)]].doubleValue }
        var mask: [UInt8] = []
        for y in 0..<72 { for x in 0..<72 {
            let value = masks[[0,NSNumber(value:q),NSNumber(value:y),NSNumber(value:x)]].doubleValue
            guard value.isFinite else { throw failure("Nonfinite selected-ball mask") }
            mask.append(value > 0 ? 1 : 0)
        } }
        guard score.isFinite, box.allSatisfy(\.isFinite) else { throw failure("Nonfinite box/score") }
        return Snapshot(score: score, box: box, mask: mask)
    }
    func metalControl() throws -> [String: Any] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw failure("No Metal device") }
        let source = "#include <metal_stdlib>\nusing namespace metal; kernel void twice(device float *x [[buffer(0)]],uint i [[thread_position_in_grid]]){x[i]=x[i]*2.0f;}"
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "twice")!)
        var data: [Float] = [1,2,3,4]
        let buffer = device.makeBuffer(bytes: &data, length: 16, options: .storageModeShared)!
        let command = device.makeCommandQueue()!.makeCommandBuffer()!
        let encoder = command.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width:4,height:1,depth:1), threadsPerThreadgroup: MTLSize(width:4,height:1,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let result = Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: 4))
        guard result == [2,4,6,8] else { throw failure("Metal control output mismatch") }
        return ["device": device.name, "apple6": device.supportsFamily(.apple6), "passed": true]
    }
}
