import AVFoundation
import AppKit
import CryptoKit
import Foundation
import simd

struct PixelDifference {
    var channels = 0, total = 0, aboveTwo = 0, maximum = 0, alphaMaximum = 0
    mutating func add(_ a: CGImage, _ b: CGImage) {
        precondition(a.width == b.width && a.height == b.height && a.bytesPerRow == b.bytesPerRow)
        let x = Array(a.dataProvider!.data! as Data), y = Array(b.dataProvider!.data! as Data)
        precondition(x.count == y.count)
        for i in x.indices {
            let d = abs(Int(x[i])-Int(y[i]));channels += 1;total += d;maximum = max(maximum,d)
            if d > 2 { aboveTwo += 1 }; if i%4 == 3 { alphaMaximum = max(alphaMaximum,d) }
        }
    }
    var json: [String:Any] {
        ["channels":channels,"mean_absolute_byte_error":Double(total)/Double(max(1,channels)),
         "max_byte_error":maximum,"fraction_above_2":Double(aboveTwo)/Double(max(1,channels)),
         "max_alpha_error":alphaMaximum,"screen_pass":Double(aboveTwo)/Double(max(1,channels)) <= 0.001 && maximum <= 12 && alphaMaximum <= 1]
    }
}
func statistics(_ values: [Double]) -> [String:Any] {
    let sorted = values.sorted()
    return ["n":sorted.count,"median_ms":sorted[sorted.count/2],"p95_ms":sorted[min(sorted.count-1,Int(Double(sorted.count)*0.95))]]
}
func measure(_ operation: () -> CGImage) -> (CGImage,Double) {
    let t = ProcessInfo.processInfo.systemUptime
    let result = operation()
    return (result,(ProcessInfo.processInfo.systemUptime-t)*1000)
}

@main enum Probe {
    static func main() async throws {
        let folder = URL(fileURLWithPath:CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath:folder.path) else { fatalError("Choose a fresh output folder") }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        GPUProbe.renderer = try GPUSphere(shader:String(contentsOfFile:"scripts/ball-gpu-probe/Sphere.metal",encoding:.utf8))
        print("GPU: \(GPUProbe.renderer.device.name)")
        var report: [String:Any] = ["scope":"Mac prototype only. Uncached sphere rendering; GPU timing includes submit, wait, readback and CGImage construction. Full replacement timings retain existing CPU masking, blur and background; exclude decoding, geometry, final composition and encoding. Not a phone or export benchmark.",
            "date":ISO8601DateFormatter().string(from:Date()),"gpu":GPUProbe.renderer.device.name,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"thermal_start":ProcessInfo.processInfo.thermalState.rawValue,
            "screen":"At most 0.1% channels differ by >2/255; max difference <=12/255; alpha <=1/255. Screening only, not release acceptance."]
        let sources = ["kicklab/Effects/BallSkinSphereRenderer.swift","kicklab/Effects/BallMaterialRenderer.swift","scripts/ball-gpu-probe/Sphere.metal","scripts/ball-gpu-probe/GPUSphere.swift","scripts/ball-gpu-probe/Main.swift","scripts/ball-gpu-probe/build.sh"]
        report["sha256"] = try Dictionary(uniqueKeysWithValues:sources.map { ($0,SHA256.hash(data:try Data(contentsOf:URL(fileURLWithPath:$0))).map{String(format:"%02x",$0)}.joined()) })
        var sphereRows = [[String:Any]]()
        for skin in GPUProbe.skins {
            var cpu = [Double](), gpu = [Double](), diff = PixelDifference()
            // Warm static geometry, decompressed maps, GPU buffers and pipeline before timing.
            for enabled in [false,true] {
                GPUProbe.enabled=enabled
                _ = BallSkinSphereRenderer.image(skin:skin,time:0,orientation:simd_quatf(angle:0,axis:SIMD3(0,1,0)))!
            }
            for i in 0..<18 {
                let q = simd_normalize(simd_quatf(angle:Float(i)*0.37,axis:simd_normalize(SIMD3<Float>(0.2,1,0.3))))
                var images = [Bool:CGImage]()
                for enabled in i%2 == 0 ? [false,true] : [true,false] {
                    GPUProbe.enabled=enabled
                    let (image,ms)=measure { BallSkinSphereRenderer.image(skin:skin,time:Double(i)/7,orientation:q)! }
                    images[enabled]=image
                    if enabled {gpu.append(ms)} else {cpu.append(ms)}
                }
                diff.add(images[false]!,images[true]!)
                if i == 7 && [.arctic,.lava,.pearl,.metal].contains(skin) {
                    for enabled in [false,true] { try save(images[enabled]!,folder.appendingPathComponent("sphere-\(skin.rawValue)-\(enabled ? "gpu" : "cpu").png")) }
                }
            }
            // Exercise timer-derived pose separately, without conflating its matrix/quaternion rounding with source-driven poses.
            var timerDiff=PixelDifference()
            for time in [0.0,0.5,2.0] {
                GPUProbe.enabled=false;let a=BallSkinSphereRenderer.image(skin:skin,time:time)!
                GPUProbe.enabled=true;let b=BallSkinSphereRenderer.image(skin:skin,time:time)!
                timerDiff.add(a,b)
            }
            sphereRows.append(["skin":skin.rawValue,"cpu":statistics(cpu),"gpu":statistics(gpu),"difference":diff.json,"timer_difference":timerDiff.json])
            print("Sphere \(skin.rawValue): CPU \(statistics(cpu)), GPU \(statistics(gpu)), diff \(diff.json)")
        }
        report["spheres"] = sphereRows
        var clips = [[String:Any]]()
        for (name,source,stored) in [
            ("better","/Users/hewadmubariz/Downloads/IMG_8649 2.mov","artifacts/ball-pair-audit-20261102/better-source"),
            ("problem","/Users/hewadmubariz/Downloads/IMG_9094.MOV","artifacts/ball-pair-audit-20261102/problem-source")
        ] {
            clips.append(try await clip(name:name,source:source,stored:stored,folder:folder))
        }
        report["clips"] = clips
        report["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("report.json"))
        print("Done: \(folder.path)")
    }
    static func save(_ image: CGImage, _ url: URL) throws {
        try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:url)
    }
    static func clip(name:String,source:String,stored:String,folder:URL) async throws -> [String:Any] {
        var track=BallEffectTrack(frames:try SavedAppearanceFrames.frames(URL(fileURLWithPath:stored+"/visual.plist")))
        let spin=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:stored+"/spin.json"))) as! [String:Any]
        let entries=(spin["rows"] as! [[String:Any]]).map { row -> BallSurfaceTimeline.Entry in
            let q=row["orientation"] as! [Double]
            return .init(time:row["time"] as! Double,orientation:simd_quatf(ix:Float(q[0]),iy:Float(q[1]),iz:Float(q[2]),r:Float(q[3])),accepted:row["accepted"] as! Bool,visible:row["visible"] as! Bool)
        }
        track.surfaceMotion=BallSurfaceTimeline(entries:entries,elapsed:0,photographicExposure:spin["photographicExposure"] as? Double)
        let asset=AVURLAsset(url:URL(fileURLWithPath:source)), video=try await asset.loadTracks(withMediaType:.video)[0]
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.videoComposition=try await EffectVideoGeometry.composition(track:video,duration:asset.load(.duration),shortEdge:1080)
        output.alwaysCopiesSampleData=false;reader.add(output);guard reader.startReading() else {throw reader.error!}
        var rows=[[String:Any]](),index=0,aggregate=PixelDifference()
        var cpu=[Double](),gpu=[Double]()
        while let sample=output.copyNextSampleBuffer() {
            defer{index += 1}
            guard index%90 == 0 else{continue}
            try autoreleasepool {
                let time=sample.presentationTimeStamp.seconds,pixels=CMSampleBufferGetImageBuffer(sample)!
                let size=CGSize(width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels))
                guard let guide=track.replacementGuide(at:time),let fitted=BallReplacementFootprint.fit(pixels:pixels,sample:guide,measureTexture:true) else{return}
                let smear=track.smear(at:time,size:size)
                guard let matte=track.replacementMatte(at:time,fitted:fitted,size:size,smear:smear,photographicSmear:track.surfaceMotion?.photographicExposure != nil) else{return}
                let background=BallReplacementBackground(pixels:pixels,matte:matte)
                let light=BallSurfaceTimeline.white(pixels:pixels,center:matte.footprint.center,radius:matte.footprint.radius)
                for skin in [BallSkin.arctic,.lava,.stealth] {
                    func render() -> CGImage {
                        BallMaterialRenderer.replacement(footprint:matte.footprint,skin:skin,time:time,
                            coverage:{matte.coverage(x:$0,y:$1)},coverageBounds:matte.bounds,
                            orientation:track.surfaceMotion?.renderOrientation(at:time),smear:smear,light:light,background:background)!.image
                    }
                    // Warm each material before the timed matched arms.
                    for enabled in [false,true] {GPUProbe.enabled=enabled;_ = render()}
                    var diff=PixelDifference(),ct=[Double](),gt=[Double](),images=[Bool:CGImage]()
                    for round in 0..<3 {
                        for enabled in (index/90+round)%2 == 0 ? [false,true] : [true,false] {
                            GPUProbe.enabled=enabled
                            let (image,ms)=measure(render);images[enabled]=image
                            if enabled{gt.append(ms);gpu.append(ms)}else{ct.append(ms);cpu.append(ms)}
                        }
                        diff.add(images[false]!,images[true]!);aggregate.add(images[false]!,images[true]!)
                    }
                    rows.append(["index":index,"time":time,"skin":skin.rawValue,"cpu":statistics(ct),"gpu":statistics(gt),"difference":diff.json,
                        "smear":[smear.dx,smear.dy],"radius":matte.footprint.radius])
                    if [270,630,990].contains(index) && skin == .arctic {
                        for enabled in [false,true] {try save(images[enabled]!,folder.appendingPathComponent("\(name)-\(index)-\(enabled ? "gpu" : "cpu").png"))}
                    }
                }
            }
        }
        guard reader.status == .completed else{throw reader.error!}
        print("Clip \(name): CPU \(statistics(cpu)), GPU \(statistics(gpu)), diff \(aggregate.json)")
        return ["name":name,"source":source,"sample_stride":90,"decoded_short_edge":1080,"cpu":statistics(cpu),"gpu":statistics(gpu),"difference":aggregate.json,"rows":rows]
    }
}
