import AVFoundation
import CoreML
import CryptoKit
import XCTest
@testable import kicklab

@MainActor
final class VisualInferenceThroughputTests: XCTestCase {
    private func hashes(_ output:MLFeatureProvider)->[String:String] {
        var result=[String:String]()
        for name in output.featureNames.sorted() {
            guard let a=output.featureValue(for:name)?.multiArrayValue else {continue}
            var expected=1,contiguous=true
            for i in a.shape.indices.reversed() {if a.strides[i].intValue != expected {contiguous=false};expected *= a.shape[i].intValue}
            var hash=SHA256()
            if contiguous {
                let bytes=a.dataType == .float16 ? 2:a.dataType == .double ? 8:4
                hash.update(data:Data(bytesNoCopy:a.dataPointer,count:a.count*bytes,deallocator:.none))
            } else {
                for i in 0..<a.count {var value=a[i].doubleValue;withUnsafeBytes(of:&value){hash.update(bufferPointer:$0)}}
            }
            result[name]=hash.finalize().map {String(format:"%02x",$0)}.joined()
        }
        return result
    }
    private func measure(_ detector:BallDetector,_ inputs:[MLFeatureProvider],mode:String) async throws -> (Double,[[String:String]],Double) {
        let width=mode == "serial" ? 1:2
        var seconds=0.0,hashSeconds=0.0,values=[[String:String]]()
        for offset in stride(from:0,to:inputs.count,by:width) {
            let part=Array(inputs[offset..<min(offset+width,inputs.count)])
            let start=ProcessInfo.processInfo.systemUptime
            let outputs:[MLFeatureProvider]
            if mode == "serial" {outputs=[try detector.reviewSerial(part[0])]}
            else if mode == "batch2" {let batch=try detector.reviewBatch(part);outputs=(0..<batch.count).map {batch.features(at:$0)}}
            else {
                outputs=try await withThrowingTaskGroup(of:(Int,MLFeatureProvider).self) {group in
                    for (i,input) in part.enumerated() {group.addTask {(i,try await detector.reviewAsync(input))}}
                    var values=[(Int,MLFeatureProvider)]()
                    for try await value in group {values.append(value)}
                    return values.sorted {$0.0<$1.0}.map(\.1)
                }
            }
            seconds += ProcessInfo.processInfo.systemUptime-start
            let hashStart=ProcessInfo.processInfo.systemUptime
            for output in outputs {values.append(autoreleasepool {hashes(output)})}
            hashSeconds += ProcessInfo.processInfo.systemUptime-hashStart
        }
        return (seconds,values,hashSeconds)
    }
    func testPhysicalImmutableInputsAcrossSerialBatchAndAsync() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("This is a physical-device throughput measurement.")
        #else
        let source=URL.documentsDirectory.appendingPathComponent("batch-fresh-source.mov")
        guard FileManager.default.fileExists(atPath:source.path) else {throw XCTSkip("Diagnostic recording is not staged.")}
        let detector=try BallDetector(resourceName:"KickLabYOLO26MotionSegmentation")
        let asset=AVURLAsset(url:source),track=try await asset.loadTracks(withMediaType:.video)[0],reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[track],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=try await EffectVideoGeometry.composition(track:track,duration:asset.load(.duration),shortEdge:720)
        output.alwaysCopiesSampleData=false;reader.add(output);XCTAssertTrue(reader.startReading())
        var inputs=[MLFeatureProvider](),index=0,selected=[Int]()
        while inputs.count<32, let sample=output.copyNextSampleBuffer() {
            if index%90==0 {inputs.append(try autoreleasepool {try detector.reviewInput(CMSampleBufferGetImageBuffer(sample)!)});selected.append(index)}
            index += 1
        }
        reader.cancelReading();XCTAssertEqual(inputs.count,32)
        for mode in ["serial","batch2","async2"] {_ = try await measure(detector,Array(inputs.prefix(4)),mode:mode)}
        let reference=try await measure(detector,inputs,mode:"serial")
        var rows=[[String:Any]]()
        for (round,order) in [["serial","batch2","async2"],["async2","serial","batch2"],["batch2","async2","serial"]].enumerated() {
            for mode in order {
                let thermal=ProcessInfo.processInfo.thermalState.rawValue
                let result=try await measure(detector,inputs,mode:mode)
                let changed=zip(reference.1,result.1).enumerated().filter {$0.element.0 != $0.element.1}.map(\.offset)
                rows.append(["round":round,"mode":mode,"prediction_s":result.0,
                             "output_access_and_hash_s":result.2,"prediction_and_hash_s":result.0+result.2,
                             "changed_inputs":changed,"thermal":thermal])
                XCTAssertEqual(changed,[],mode)
            }
        }
        func layout(_ output:MLFeatureProvider)->[String:Any] {
            var result=[String:Any]()
            for name in output.featureNames.sorted() {
                guard let a=output.featureValue(for:name)?.multiArrayValue else {continue}
                result[name]=["type":a.dataType.rawValue,"shape":a.shape,"strides":a.strides]
            }
            return result
        }
        let layouts:[String:Any]=["serial":layout(try detector.reviewSerial(inputs[0])),
                                  "batch2":layout(try detector.reviewBatch(Array(inputs.prefix(2))).features(at:0))]
        try JSONSerialization.data(withJSONObject:["rows":rows,"layouts":layouts,"source_frames":selected,
            "scope":"iPhone immutable32real inputs,3rotated rounds. Prediction call and output access plus SHA256 separately timed; hashing is diagnostic work, not production mask decoding. Not total preparation."],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL.documentsDirectory.appendingPathComponent("batch-async-pilot.json"))
        #endif
    }
}
