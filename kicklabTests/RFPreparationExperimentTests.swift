import XCTest
import UIKit
import CryptoKit
@testable import kicklab
import AVFoundation
import CoreImage
import CoreML
import Foundation

nonisolated enum RFSelectedMaskProbe {
    struct Sample { let time: Double; let input: MLFeatureProvider }
    struct Comparison: Codable {
        let time: Double
        let query: Int
        let candidateQuery: Int
        let boxMaxDelta: Double
        let scoreMaxDelta: Double
        let maskMaxDelta: Double
        let changedMaskValues: Int
        let changedMaskSigns: Int
        let baselineMS: Double
        let candidateMS: Double
    }
    struct Report: Codable {
        let edge: Int
        let compute: String
        let baselineLoadSeconds: Double
        let candidateLoadSeconds: Double
        let rows: [Comparison]
        let failure: String?
    }
    static func value(_ a: MLMultiArray, _ i: Int) -> Double {
        switch a.dataType {
        case .float16: Double(a.dataPointer.assumingMemoryBound(to: Float16.self)[i])
        case .float32: Double(a.dataPointer.assumingMemoryBound(to: Float.self)[i])
        default: a[i].doubleValue
        }
    }
    static func inputs(source: URL, edge: Int, limit: Int = 24) async throws -> [Sample] {
        let asset = AVURLAsset(url: source)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition = try await EffectVideoGeometry.composition(track: track, duration: asset.load(.duration), shortEdge: 720)
        output.alwaysCopiesSampleData = false; reader.add(output)
        guard reader.startReading() else { throw reader.error! }
        defer { reader.cancelReading() }
        let context = CIContext(options:[.useSoftwareRenderer:true,.workingColorSpace:NSNull(),.cacheIntermediates:false])
        var result = [Sample](), index = 0
        while let sample = output.copyNextSampleBuffer(), result.count < limit {
            defer { index += 1 }
            guard index % 97 == 0, let sourcePixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let input: MLFeatureProvider = try autoreleasepool {
                let width = CVPixelBufferGetWidth(sourcePixels), height = CVPixelBufferGetHeight(sourcePixels)
                var target: CVPixelBuffer?
                guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&target) == kCVReturnSuccess, let target else { throw NSError(domain:"Probe",code:1) }
                context.render(CIImage(cvPixelBuffer:sourcePixels),to:target,bounds:CGRect(x:0,y:0,width:width,height:height),colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
                let tensor = try MLMultiArray(shape:[1,3,NSNumber(value:edge),NSNumber(value:edge)],dataType:.float32)
                CVPixelBufferLockBaseAddress(target,.readOnly)
                defer { CVPixelBufferUnlockBaseAddress(target,.readOnly) }
                RFInputNormalization.normalizeBGRA(CVPixelBufferGetBaseAddress(target)!.assumingMemoryBound(to:UInt8.self),width:width,height:height,rowBytes:CVPixelBufferGetBytesPerRow(target),into:tensor.dataPointer.assumingMemoryBound(to:Float.self),edge:edge)
                return try MLDictionaryFeatureProvider(dictionary:["tensors":tensor])
            }
            result.append(.init(time:sample.presentationTimeStamp.seconds,input:input))
        }
        return result
    }
    static func run(samples: [Sample], baseline: URL, candidate: URL, edge: Int, cpuOnly: Bool,
                    alternative: MLComputeUnits? = nil, candidateFunction: String? = nil,
                    selectedMask: Bool = true, referenceCPU: Bool? = nil) -> Report {
        let units = alternative ?? (cpuOnly ? MLComputeUnits.cpuOnly : .cpuAndGPU)
        let name: String
        switch units {
        case .cpuOnly: name = "cpuOnly"
        case .cpuAndGPU: name = "cpuAndGPU"
        case .cpuAndNeuralEngine: name = "cpuAndNeuralEngine"
        case .all: name = "all"
        @unknown default: name = "unknown"
        }
        var baseLoad = 0.0, candidateLoad = 0.0
        do {
            let configuration = MLModelConfiguration(); configuration.computeUnits = (referenceCPU ?? cpuOnly) ? .cpuOnly : .cpuAndGPU
            configuration.functionName = "rf\(edge)"
            var start = ProcessInfo.processInfo.systemUptime
            let base = try MLModel(contentsOf:baseline,configuration:configuration)
            baseLoad = ProcessInfo.processInfo.systemUptime - start
            configuration.functionName = candidateFunction
            configuration.computeUnits = units
            start = ProcessInfo.processInfo.systemUptime
            let changed = try MLModel(contentsOf:candidate,configuration:configuration)
            candidateLoad = ProcessInfo.processInfo.systemUptime - start
            for row in samples.prefix(3) {
                _ = try base.prediction(from:row.input); _ = try changed.prediction(from:row.input)
            }
            var rows = [Comparison]()
            for (iteration, row) in samples.enumerated() {
                let record: Comparison = try autoreleasepool {
                    var a: MLFeatureProvider!, b: MLFeatureProvider!, ta = 0.0, tb = 0.0
                    for isBase in (iteration % 2 == 0 ? [true,false] : [false,true]) {
                        let began = ProcessInfo.processInfo.systemUptime
                        let result = try (isBase ? base : changed).prediction(from:row.input)
                        let ms = (ProcessInfo.processInfo.systemUptime-began)*1000
                        if isBase { a=result;ta=ms } else { b=result;tb=ms }
                    }
                    func delta(_ name:String) -> Double {
                        let x=a.featureValue(for:name)!.multiArrayValue!,y=b.featureValue(for:name)!.multiArrayValue!
                        let shape = x.shape.map(\.intValue)
                        let xs = x.strides.map(\.intValue), ys = y.strides.map(\.intValue)
                        var largest = 0.0
                        for index in 0..<x.count {
                            var remaining = index, xi = 0, yi = 0
                            for axis in shape.indices.reversed() {
                                let coordinate = remaining % shape[axis]
                                remaining /= shape[axis]
                                xi += coordinate * xs[axis]; yi += coordinate * ys[axis]
                            }
                            largest = max(largest, abs(value(x, xi) - value(y, yi)))
                        }
                        return largest
                    }
                    let scores=a.featureValue(for:"linear_122")!.multiArrayValue!
                    let stride=scores.strides[1].intValue, column=scores.strides[2].intValue*37
                    var query=0
                    for q in 1..<100 where value(scores,q*stride+column)>value(scores,query*stride+column) { query=q }
                    var chosen: Int
                    if selectedMask { chosen=b.featureValue(for:"ball_query")!.multiArrayValue![0].intValue }
                    else {
                        let candidateScores=b.featureValue(for:"linear_122")!.multiArrayValue!
                        let candidateStride = candidateScores.strides[1].intValue
                        let candidateColumn = candidateScores.strides[2].intValue * 37
                        chosen=0
                        for q in 1..<100 where value(candidateScores,q*candidateStride+candidateColumn)>value(candidateScores,chosen*candidateStride+candidateColumn) { chosen=q }
                    }
                    let x=a.featureValue(for:"add_62")!.multiArrayValue!, y=b.featureValue(for:selectedMask ? "selected_mask" : "add_62")!.multiArrayValue!
                    let targetOffset=selectedMask ? 0 : chosen*y.strides[1].intValue
                    let offset=query*x.strides[1].intValue, side=edge/4
                    var maximum=0.0, different=0, signs=0
                    for yy in 0..<side { for xx in 0..<side {
                        let u=value(x,offset+yy*x.strides[2].intValue+xx*x.strides[3].intValue)
                        let v=value(y,targetOffset+yy*y.strides[2].intValue+xx*y.strides[3].intValue)
                        maximum=max(maximum,abs(u-v));different += u == v ? 0 : 1
                        signs += (u>0) == (v>0) ? 0 : 1
                    } }
                    return .init(time:row.time,query:query,candidateQuery:chosen,boxMaxDelta:delta("concat_2"),scoreMaxDelta:delta("linear_122"),maskMaxDelta:maximum,changedMaskValues:different,changedMaskSigns:signs,baselineMS:ta,candidateMS:tb)
                }
                rows.append(record)
            }
            return .init(edge:edge,compute:name,baselineLoadSeconds:baseLoad,candidateLoadSeconds:candidateLoad,rows:rows,failure:nil)
        } catch {
            return .init(edge:edge,compute:name,baselineLoadSeconds:baseLoad,candidateLoadSeconds:candidateLoad,rows:[],failure:String(reflecting:error as NSError))
        }
    }
}


@MainActor
final class RFPreparationExperimentTests: XCTestCase {
    private let folder = URL.documentsDirectory.appending(path: "exact-clip-check")
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: folder.appending(path: name), options: .atomic)
    }
    func testSelectedMaskModel() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only")
        #endif
        let edge = RFDeviceProfile.current.rawValue
        let model = folder.appending(path: "RFSelectedMask\(edge).mlmodelc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path))
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let source = folder.appending(path: "clip.mov")
        let base = try XCTUnwrap(Bundle.main.url(forResource: RFSmallModel.fp16.rawValue, withExtension: "mlmodelc"))
        let samples = try await RFSelectedMaskProbe.inputs(source: source, edge: edge)
        var reports = [RFSelectedMaskProbe.Report]()
        for cpu in [true, false] {
            let report = RFSelectedMaskProbe.run(samples: samples, baseline: base, candidate: model,
                edge: edge, cpuOnly: cpu, referenceCPU: edge == 288 ? true : nil)
            reports.append(report)
            try write(reports, "selected-mask-probe.json")
            if cpu { XCTAssertNil(report.failure); XCTAssertEqual(report.rows.count, 24) }
            for row in report.rows { XCTAssertEqual(row.query, row.candidateQuery) }
        }
    }
    func testModelBackendComparison() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only")
        #endif
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let edge = RFDeviceProfile.current.rawValue
        let base = try XCTUnwrap(Bundle.main.url(forResource: RFSmallModel.fp16.rawValue, withExtension: "mlmodelc"))
        let samples = try await RFSelectedMaskProbe.inputs(source: folder.appending(path: "clip.mov"), edge: edge)
        var reports = [RFSelectedMaskProbe.Report]()
        for units: MLComputeUnits in [.cpuAndNeuralEngine, .all] {
            reports.append(RFSelectedMaskProbe.run(samples: samples, baseline: base, candidate: base,
                edge: edge, cpuOnly: true, alternative: units, candidateFunction: "rf\(edge)", selectedMask: false))
            try write(reports, "backend-probe.json")
        }
    }
    func testBatchedModelComparison() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only")
        #endif
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let edge = RFDeviceProfile.current.rawValue
        let base = try XCTUnwrap(Bundle.main.url(forResource: RFSmallModel.fp16.rawValue, withExtension: "mlmodelc"))
        let samples = try await RFSelectedMaskProbe.inputs(source: folder.appending(path: "clip.mov"), edge: edge)
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let rows = try RFBatchProbe.run(modelURL: base, samples: samples, edge: edge, cpu: edge == 288)
        struct Result: Encodable {
            let thermalBefore: Int, thermalAfter: Int
            let rows: [RFBatchProbe.Row]
        }
        try write(Result(thermalBefore: thermal, thermalAfter: ProcessInfo.processInfo.thermalState.rawValue,
            rows: rows), "batch-probe.json")
        XCTAssertEqual(rows.count, 6)
        for row in rows { XCTAssertTrue(row.equalOutputs, "Batch output differs from single-frame inference") }
    }
    func testCompatibilityGraphs() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only")
        #endif
        let edge = RFDeviceProfile.current.rawValue
        try XCTSkipUnless(edge == 288, "A13 compatibility experiment")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        let base = try XCTUnwrap(Bundle.main.url(forResource: RFSmallModel.fp16.rawValue, withExtension: "mlmodelc"))
        let samples = try await RFSelectedMaskProbe.inputs(source: folder.appending(path: "clip.mov"), edge: edge)
        struct Result: Encodable {
            let model: String; let thermalBefore: Int; let thermalAfter: Int
            let measurement: RFSelectedMaskProbe.Report
        }
        var reports = [Result]()
        for name in ["RFFixed288", "RFCompatConv288", "RFCompatMatmul288", "RFSelectedMask288"] {
            let model = folder.appending(path: "\(name).mlmodelc")
            try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path))
            for cpu in [true, false] {
                let thermal = ProcessInfo.processInfo.thermalState.rawValue
                let report = RFSelectedMaskProbe.run(samples: samples, baseline: base, candidate: model,
                    edge: edge, cpuOnly: cpu, selectedMask: name == "RFSelectedMask288", referenceCPU: true)
                reports.append(.init(model: name, thermalBefore: thermal,
                    thermalAfter: ProcessInfo.processInfo.thermalState.rawValue, measurement: report))
                try write(reports, "compatibility-graphs.json")
                if cpu { XCTAssertNil(report.failure); XCTAssertEqual(report.rows.count, 24) }
            }
        }
    }
    func testCropReaderComparison() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phones only")
        #endif
        let file = folder.appending(path: "raw-visual.plist")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: file.path))
        let stored = try PropertyListDecoder().decode([StoredFrame].self, from: Data(contentsOf: file))
        XCTAssertTrue(StoredFrame.validated(stored))
        let frames = stored.map(\.frame), source = folder.appending(path: "clip.mov")
        let previousIdle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdle }
        PreparationPerformance.reset()
        struct Row: Encodable { let selective: Bool; let seconds: Double; let thermalBefore: Int; let thermalAfter: Int; let digest: String }
        var rows = [Row](), reference: Data?
        for (index, selective) in [false, true, true, false].enumerated() {
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await VideoWorkExecution.detached {
                try await RFMaskCropRefiner.refine(source: source, frames: frames, selectiveRead: selective)
            }.value
            let seconds = ProcessInfo.processInfo.systemUptime - start
            try SessionAnalysisStore.frameData(result).write(to: folder.appending(path: "crop-result-\(index).plist"), options: .atomic)
            let canonical = JSONEncoder(); canonical.outputFormatting = [.sortedKeys]
            let data = try canonical.encode(result.map(StoredFrame.init))
            if let reference { XCTAssertEqual(data, reference, "Repair output changed under selective reading") }
            else { reference = data }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            rows.append(.init(selective: selective, seconds: seconds, thermalBefore: thermal,
                thermalAfter: ProcessInfo.processInfo.thermalState.rawValue, digest: digest))
            try write(rows, "crop-reader-comparison.json")
        }
    }
}

nonisolated enum RFBatchProbe {
    struct Row: Codable {
        let edge: Int, groupSize: Int
        let compute: String
        let predictionSeconds: Double
        let samples: Int, equalOutputs: Bool
    }
    static func fingerprint(_ output: MLFeatureProvider) -> String {
        var hash = SHA256()
        for name in output.featureNames.sorted() {
            let value = output.featureValue(for: name)!.multiArrayValue!
            let shape = value.shape.map(\.intValue), strides = value.strides.map(\.intValue)
            let elementBytes: Int
            switch value.dataType {
            case .float16: elementBytes = 2
            case .float32, .int32: elementBytes = 4
            default: elementBytes = 8
            }
            hash.update(data: Data(name.utf8))
            let width = shape.last!, rowCount = value.count / width
            for row in 0..<rowCount {
                var remaining = row, offset = 0
                for axis in shape.dropLast().indices.reversed() {
                    offset += (remaining % shape[axis]) * strides[axis]
                    remaining /= shape[axis]
                }
                if strides.last == 1 {
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: value.dataPointer.advanced(by: offset * elementBytes), count: width * elementBytes))
                } else {
                    for column in 0..<width {
                        hash.update(bufferPointer: UnsafeRawBufferPointer(start: value.dataPointer.advanced(by: (offset + column * strides.last!) * elementBytes), count: elementBytes))
                    }
                }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func run(modelURL: URL, samples: [RFSelectedMaskProbe.Sample], edge: Int, cpu: Bool) throws -> [Row] {
        let config = MLModelConfiguration(); config.functionName = "rf\(edge)"
        config.computeUnits = cpu ? .cpuOnly : .cpuAndGPU
        let model = try MLModel(contentsOf: modelURL, configuration: config)
        for sample in samples.prefix(3) { _ = try model.prediction(from: sample.input) }
        var reference = [String](), rows = [Row]()
        for size in [1, 2, 4, 4, 2, 1] {
            var seconds = 0.0, fingerprints = [String]()
            for begin in stride(from: 0, to: samples.count, by: size) {
                try autoreleasepool {
                    let inputs = samples[begin..<min(samples.count,begin+size)].map(\.input)
                    let started = ProcessInfo.processInfo.systemUptime
                    let outputs: [MLFeatureProvider]
                    if size == 1 { outputs = [try model.prediction(from: inputs[0])] }
                    else {
                        let batch = try model.predictions(fromBatch: MLArrayBatchProvider(array: inputs))
                        outputs = (0..<batch.count).map { batch.features(at: $0) }
                    }
                    seconds += ProcessInfo.processInfo.systemUptime - started
                    fingerprints += outputs.map(fingerprint)
                }
            }
            if reference.isEmpty { reference = fingerprints }
            rows.append(.init(edge: edge, groupSize: size, compute: cpu ? "cpuOnly" : "cpuAndGPU",
                predictionSeconds: seconds, samples: samples.count, equalOutputs: reference == fingerprints))
        }
        return rows
    }
}
