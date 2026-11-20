#if DEBUG
import AVFoundation
import Foundation
/// Explicit developer replay only. Simulates RF every ~100 ms using saved model
/// boxes, and matches the real frames between. It never mutates game state.
nonisolated enum WallPixelTrackingReplay {
 static func run(folder root: URL, output: URL) async throws {
 let csv=try String(contentsOf:root.appendingPathComponent("detections.csv"),encoding:.utf8).split(separator:"\n").map{$0.split(separator:",",omittingEmptySubsequences:false).map(String.init)}
 let rows=csv.dropFirst().map{Dictionary(uniqueKeysWithValues:zip(csv[0],$0))}
 let asset=AVURLAsset(url:root.appendingPathComponent("video.mov"))
 guard let track=try await asset.loadTracks(withMediaType:.video).first else { return }
 let reader=try AVAssetReader(asset:asset)
 let out=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);out.alwaysCopiesSampleData=false;reader.add(out);reader.startReading()
 var pixel=WallBallPixelTracker(), result=[[String:Any]](), i=0, lastSeed = -Double.infinity, pending=[Int]()
 while let s=out.copyNextSampleBuffer() {
 let t=CMSampleBufferGetPresentationTimeStamp(s).seconds
 while i+1<rows.count && abs(Double(rows[i+1]["t"]!)!-t)<abs(Double(rows[i]["t"]!)!-t) {i+=1}
 guard let p=CMSampleBufferGetImageBuffer(s) else {continue}
 autoreleasepool {
 let began=ProcessInfo.processInfo.systemUptime
 let image=WallBallPixelTracker.Image(p)!
 let match=pixel.update(image,at:t)
 let saved=rows[i]
 let vals=["ball_score","bx","by","bw","bh"].map{Double(saved[$0]!)!}
 let ball=vals[0] >= 0.2 ? Detection(score:vals[0],x:vals[1],y:vals[2],width:vals[3],height:vals[4]):nil
 var r:[String:Any] = ["t":t,"ms":(ProcessInfo.processInfo.systemUptime-began)*1000,"failure":pixel.failure as Any? ?? NSNull()]
 if let match {r["tracked"]=[match.score,match.x*image.size.width,match.y*image.size.height,(match.width*image.size.width+match.height*image.size.height)/2]}
 if let ball {
 r["model"]=[ball.score,ball.x*image.size.width,ball.y*image.size.height,(ball.width*image.size.width+ball.height*image.size.height)/2]
 if let match {
 let d=(ball.width*image.size.width+ball.height*image.size.height)/2
 r["errorDiameters"]=hypot((match.x-ball.x)*image.size.width,(match.y-ball.y)*image.size.height)/d
 }
 }
 if t-lastSeed >= 0.09 {
 let confirmed=WallBallPixelTracker.agrees(match,model:ball,size:image.size)
 for j in pending {result[j]["confirmed"]=confirmed}
 pending=[]
 if let ball {pixel.seed(ball,image:image,at:t)} else {pixel.reset()}
 lastSeed=t;r["seed"]=true
 } else {pending.append(result.count)}
 result.append(r)
 }
 }
 let report: [String: Any] = ["method": "Saved RF boxes at 100 ms intervals seed production pixel matching on actual recorded frames; no interpolated frames; endpoint model agreement required. Measures tracker cost, not RF inference or live hit accuracy.",
    "rows": result, "frames": result.count, "matches": result.filter { $0["tracked"] != nil }.count,
    "completed": Date().timeIntervalSince1970]
 try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
 }
}

#endif
