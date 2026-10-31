// Build with ContactPose.swift and VisionRevisionExperiment.swift, -D DEBUG.
// Pose evidence only: this deliberately does not produce touch accuracy claims.
import AVFoundation
import CoreImage
import Foundation
import Vision

nonisolated enum VideoWorkExecution { static var cpuOnly: Bool { false } }

struct Sample: Codable { let time: Double; let reasons: [String] }
struct Clip: Codable { let id, source, sha256: String; let duration: Double; let samples: [Sample] }
struct Plan: Codable { let protocolID: String; let clips: [Clip] }
struct PoseOutput: Codable { let landmarks: [String: PoseLandmark] }
struct Arm: Codable { let poses: [PoseOutput]; let milliseconds: Double; let error: String? }
struct Row: Codable {
    let sourceSeconds: Double
    let requested: [Sample]
    let width, height: Int
    let legacy, modern: Arm
}

@main struct Audit {
    static let names: [(BodyJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose,.nose),(.leftShoulder,.leftShoulder),(.rightShoulder,.rightShoulder),
        (.leftElbow,.leftElbow),(.rightElbow,.rightElbow),(.leftWrist,.leftWrist),(.rightWrist,.rightWrist),
        (.leftHip,.leftHip),(.rightHip,.rightHip),(.leftKnee,.leftKnee),(.rightKnee,.rightKnee),
        (.leftAnkle,.leftAnkle),(.rightAnkle,.rightAnkle)]
    static let context = CIContext(options: [.useSoftwareRenderer: false])
    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()

    static func legacy(_ pixels: CVPixelBuffer, _ request: VNDetectHumanBodyPoseRequest) throws -> [PoseOutput] {
        try VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        return try (request.results ?? []).prefix(8).map { observation in
            let recognized = try observation.recognizedPoints(.all)
            var points: [String: PoseLandmark] = [:]
            for (name,joint) in names {
                if let p = recognized[joint] {
                    points[name.rawValue] = .init(x:p.location.x,y:1-p.location.y,confidence:Double(p.confidence))
                }
            }
            return PoseOutput(landmarks: points)
        }
    }
    static func modern(_ pixels: CVPixelBuffer, _ session: VisionBodyPoseRevision2.Session) throws -> [PoseOutput] {
        try VisionBodyPoseRevision2.poses(in: pixels, session: session).map {
            PoseOutput(landmarks: Dictionary(uniqueKeysWithValues: $0.landmarks.map { ($0.key.rawValue,$0.value) }))
        }
    }
    static func measured(_ work: () throws -> [PoseOutput]) -> Arm {
        let t = ProcessInfo.processInfo.systemUptime
        do { let poses = try work(); return Arm(poses: poses,milliseconds:(ProcessInfo.processInfo.systemUptime-t)*1000,error:nil) }
        catch { return Arm(poses:[],milliseconds:(ProcessInfo.processInfo.systemUptime-t)*1000,error:String(describing:error)) }
    }
    static func scaled(_ raw: CVPixelBuffer) throws -> CVPixelBuffer {
        // Identical orientation and scale to ContactObservationStore.append.
        var image = CIImage(cvPixelBuffer:raw)
        if image.extent.width > image.extent.height { image = image.oriented(.right) }
        image = image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let scale = min(1,512/max(image.extent.width,image.extent.height))
        image = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        var pixels: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,Int(image.extent.width),Int(image.extent.height),
            kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&pixels)
        guard status == kCVReturnSuccess, let pixels else { throw NSError(domain:"PixelBuffer",code:Int(status)) }
        context.render(image,to:pixels)
        return pixels
    }
    static func run(_ clip: Clip, protocolID: String, output: URL) async throws {
        let done = output.appendingPathComponent(clip.id+".complete.json")
        if let data = try? Data(contentsOf:done),
           let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
           json["protocolID"] as? String == protocolID,
           json["sha256"] as? String == clip.sha256 {
            print("RESUME_SKIP \(clip.id)"); fflush(stdout); return
        }
        let asset = AVURLAsset(url:URL(fileURLWithPath:clip.source))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw NSError(domain:"NoVideo",code:1) }
        let reader = try AVAssetReader(asset:asset)
        let frames = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        frames.alwaysCopiesSampleData = false
        reader.add(frames)
        guard reader.startReading() else { throw reader.error ?? NSError(domain:"Reader",code:1) }
        let target = output.appendingPathComponent(clip.id+".jsonl")
        let temp = output.appendingPathComponent(clip.id+".partial.jsonl")
        FileManager.default.createFile(atPath:temp.path,contents:nil)
        let file = try FileHandle(forWritingTo:temp); defer { try? file.close() }
        let request = VNDetectHumanBodyPoseRequest()
        let modernSession = VisionBodyPoseRevision2.Session()
        request.revision = VNDetectHumanBodyPoseRequestRevision1
        var next = 0, count = 0, failures = 0, decoded = 0
        let start = ProcessInfo.processInfo.systemUptime
        print("START \(clip.id) requested=\(clip.samples.count)"); fflush(stdout)
        while next < clip.samples.count {
            var ended = false
            try autoreleasepool {
                guard let frame = frames.copyNextSampleBuffer() else { ended = true; return }
                decoded += 1
                let time = CMSampleBufferGetPresentationTimeStamp(frame).seconds
                guard time+0.00001 >= clip.samples[next].time else { return }
                var samples: [Sample] = []
                while next < clip.samples.count && clip.samples[next].time <= time+0.00001 {
                    samples.append(clip.samples[next]); next += 1
                }
                guard let raw = CMSampleBufferGetImageBuffer(frame) else { throw NSError(domain:"MissingPixels",code:1) }
                let pixels = try scaled(raw)
                var a: Arm, b: Arm
                // Alternate ordering to avoid a fixed first-request scheduling bias.
                if count % 2 == 0 { a=measured { try legacy(pixels,request) }; b=measured { try modern(pixels,modernSession) } }
                else { b=measured { try modern(pixels,modernSession) }; a=measured { try legacy(pixels,request) } }
                if a.error != nil || b.error != nil { failures += 1 }
                let row = Row(sourceSeconds:time,requested:samples,width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),legacy:a,modern:b)
                try file.write(contentsOf:encoder.encode(row)); try file.write(contentsOf:Data([10]))
                count += 1
                if count % 100 == 0 { print("PROGRESS \(clip.id) frames=\(count) time=\(String(format:"%.2f",time))"); fflush(stdout) }
            }
            if ended { break }
        }
        if reader.status == .failed { throw reader.error ?? NSError(domain:"ReaderFailed",code:1) }
        reader.cancelReading()
        guard next == clip.samples.count else { throw NSError(domain:"UnreachedSamples",code:clip.samples.count-next) }
        try file.synchronize()
        if FileManager.default.fileExists(atPath:target.path) { try FileManager.default.removeItem(at:target) }
        try FileManager.default.moveItem(at:temp,to:target)
        let report: [String:Any] = ["protocolID":protocolID,"id":clip.id,"sha256":clip.sha256,
            "source":clip.source,"requestedSamples":clip.samples.count,"evaluatedFrames":count,
            "decodedFrames":decoded,"errorFrames":failures,"elapsedSeconds":ProcessInfo.processInfo.systemUptime-start,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"vision":VisionRevisionExperiment.report,
            "scope":"Mac sampled pose evidence only; no ball tracking, hand detection, person selection or touch counter. Not phone throughput or touch accuracy."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:done,options:.atomic)
        print("DONE \(clip.id) frames=\(count) errors=\(failures)"); fflush(stdout)
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 3 else { fatalError("Usage: pose-audit plan.json output-directory [clip IDs...]") }
        let plan = try JSONDecoder().decode(Plan.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        let output = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let ids = Set(CommandLine.arguments.dropFirst(3))
        for clip in plan.clips where ids.isEmpty || ids.contains(clip.id) {
            try await run(clip,protocolID:plan.protocolID,output:output)
        }
    }
}
