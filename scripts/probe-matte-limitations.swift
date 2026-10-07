// METALLIB OUTPUT.json. Small controlled probes of the current implementation.
// These establish algorithm limitations, not the cause of an unseen user frame.
import CoreImage
import Foundation
import Metal

@main struct ProbeMatteLimitations {
    static let w=128,h=144
    static func mask(_ sample:(Int,Int)->UInt8) throws -> CVPixelBuffer {
        let b=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_OneComponent8)
        CVPixelBufferLockBaseAddress(b,[]);defer {CVPixelBufferUnlockBaseAddress(b,[])}
        let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),r=CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {for x in 0..<w {p[y*r+x]=sample(x,y)}}
        return b
    }
    static func bgra(_ sample:(Int,Int)->(UInt8,UInt8,UInt8)) throws -> CVPixelBuffer {
        let b=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(b,[]);defer {CVPixelBufferUnlockBaseAddress(b,[])}
        let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),r=CVPixelBufferGetBytesPerRow(b)
        for y in 0..<h {for x in 0..<w {let v=sample(x,y),i=y*r+x*4;p[i]=v.0;p[i+1]=v.1;p[i+2]=v.2;p[i+3]=255}}
        return b
    }
    static func value(_ b:CVPixelBuffer,_ x:Int,_ y:Int)->Int {
        CVPixelBufferLockBaseAddress(b,.readOnly);defer {CVPixelBufferUnlockBaseAddress(b,.readOnly)}
        let c=CVPixelBufferGetPixelFormatType(b)==kCVPixelFormatType_OneComponent8 ? 1:4
        return Int(CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self)[y*CVPixelBufferGetBytesPerRow(b)+x*c])
    }
    static func main() throws {
        let a=CommandLine.arguments,device=MTLCreateSystemDefaultDevice()!,ci=CIContext(mtlDevice:device)
        func worker() throws -> ForegroundEdgeProcessor {try .init(device:device,context:ci,library:a[1])}
        func body(_ x:Int,_ y:Int)->Bool {(32..<88).contains(x) && (20..<130).contains(y)}
        func hole(_ x:Int,_ y:Int)->Bool {(54..<66).contains(x) && (64..<76).contains(y)}
        let color=try bgra {x,y in body(x,y) ? (30,45,190):(20,170,20)}
        let withPatch=try mask {x,y in body(x,y) || ((88..<116).contains(x) && (60..<92).contains(y)) ? 255:0}
        let connected=try DetailedForegroundMaskProcessor.bodyComponent(withPatch)
        let packedPatch=try bgra {x,y in let v=UInt8(value(connected,x,y));return (v,v,v)}
        let patchResult=try worker().process(color:color,mask:packedPatch,at:0,temporal:false)
        let withHole=try mask {x,y in body(x,y) && !hole(x,y) ? 255:0}
        let weakGuide=try mask {x,y in body(x,y) ? 230:0}
        let strongGuide=try mask {x,y in body(x,y) ? 255:0}
        let whole=try bgra {x,y in let v:UInt8=body(x,y) ? 255:0;return (v,v,v)}
        let missing=try bgra {x,y in let v:UInt8=body(x,y) && !hole(x,y) ? 255:0;return (v,v,v)}
        let temporal=try worker();_ = try temporal.process(color:color,mask:whole,at:0)
        let flow=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_TwoComponent32Float)
        CVPixelBufferLockBaseAddress(flow,[]);memset(CVPixelBufferGetBaseAddress(flow)!,0,CVPixelBufferGetBytesPerRow(flow)*h);CVPixelBufferUnlockBaseAddress(flow,[])
        let holeResult=try temporal.process(color:color,mask:missing,at:1.0/30,backwardFlow:flow)
        let faint=try mask {x,y in body(x,y) ? 255:((45..<48).contains(x) && (5..<20).contains(y)) ? 20:0}
        let faintClean=try DetailedForegroundMaskProcessor.bodyComponent(faint)
        let stronger=try mask {x,y in body(x,y) ? 255:((45..<48).contains(x) && (5..<20).contains(y)) ? 34:0}
        let strongerClean=try DetailedForegroundMaskProcessor.bodyComponent(stronger)
        let report:[String:Any]=[
            "note":"Synthetic probes using shared production code. No claim of real-clip defect frequency or ground-truth accuracy.",
            "attachedBackgroundPatch":["input":255,"afterComponentCleanup":value(connected,102,76),"afterEdgeRefinement":value(patchResult.alpha,102,76)],
            "missingInteriorPatch":["repairRegionsWith230Guide":DetailedForegroundMaskProcessor.personRepairRegions(withHole,guide:weakGuide).count,"repairRegionsWith255Guide":DetailedForegroundMaskProcessor.personRepairRegions(withHole,guide:strongGuide).count,"centerAfterPerfectZeroMotionHistory":value(holeResult.alpha,60,70),"historyUsed":temporal.usedHistory],
            "faintAttachedStrand":["alpha20AfterCleanup":value(faintClean,46,10),"alpha34AfterCleanup":value(strongerClean,46,10)]
        ]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:a[2]));print(String(decoding:data,as:UTF8.self))
    }
}
