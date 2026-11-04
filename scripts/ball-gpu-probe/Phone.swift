import Foundation
import SwiftUI
import simd

@main struct GPUProbeApp: App {
    @State private var status = "Measuring CPU and GPU ball rendering…"
    var body: some Scene {
        WindowGroup {
            VStack(spacing:20) {Text("Juggle GPU Probe").font(.title);Text(status).multilineTextAlignment(.center)}
                .padding().task {
                    UIApplication.shared.isIdleTimerDisabled = true
                    let result = await Task.detached(priority:.userInitiated) { () -> String in
                        do {try PhoneProbe.run();return "Finished. Results saved locally. The main Juggle Dude app was not changed."}
                        catch {return "Failed: \(error)"}
                    }.value
                    status = result
                    UIApplication.shared.isIdleTimerDisabled = false
                }
        }
    }
}
enum PhoneProbe {
    static func run() throws {
        let source = try String(contentsOf:Bundle.main.url(forResource:"Sphere",withExtension:"txt")!,encoding:.utf8)
        GPUProbe.renderer = try GPUSphere(shader:source)
        let thermalStart=ProcessInfo.processInfo.thermalState.rawValue
        var rows=[[String:Any]]()
        for skin in GPUProbe.skins {
            var cpu=[Double](),gpu=[Double](),diff=PixelDifference()
            for enabled in [false,true] {GPUProbe.enabled=enabled;_ = BallSkinSphereRenderer.image(skin:skin,time:0,orientation:simd_quatf(angle:0,axis:SIMD3(0,1,0)))!}
            for i in 0..<30 {
                autoreleasepool {
                    let q=simd_normalize(simd_quatf(angle:Float(i)*0.37,axis:simd_normalize(SIMD3<Float>(0.2,1,0.3))))
                    var images=[Bool:CGImage]()
                    for enabled in i%2 == 0 ? [false,true] : [true,false] {
                        GPUProbe.enabled=enabled
                        let (image,ms)=measure {BallSkinSphereRenderer.image(skin:skin,time:Double(i)/7,orientation:q)!}
                        images[enabled]=image
                        if enabled{gpu.append(ms)}else{cpu.append(ms)}
                    }
                    diff.add(images[false]!,images[true]!)
                }
            }
            var timerDiff=PixelDifference()
            for time in [0.0,0.5,2.0] {
                GPUProbe.enabled=false;let a=BallSkinSphereRenderer.image(skin:skin,time:time)!
                GPUProbe.enabled=true;let b=BallSkinSphereRenderer.image(skin:skin,time:time)!
                timerDiff.add(a,b)
            }
            rows.append(["skin":skin.rawValue,"cpu":statistics(cpu),"gpu":statistics(gpu),"difference":diff.json,"timer_difference":timerDiff.json])
        }
        let report:[String:Any]=["scope":"Physical phone, optimized standalone sphere-only prototype. Uncached 256px surface draws; GPU includes command wait and CPU readback. Alternating paired arms. Excludes masks, blur, geometry, live replay, export, sustained thermal and energy tests. Main app unchanged.",
            "date":ISO8601DateFormatter().string(from:Date()),"gpu":GPUProbe.renderer.device.name,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,"thermal_start":thermalStart,
            "thermal_end":ProcessInfo.processInfo.thermalState.rawValue,"spheres":rows]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
            .write(to:URL.documentsDirectory.appendingPathComponent("gpu-probe.json"))
    }
}
