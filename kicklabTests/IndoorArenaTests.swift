import CoreVideo
import Foundation
import Testing
@testable import kicklab

struct IndoorArenaTests {
    @Test(arguments: [PreviewEnvironment.indoorArena, .urbanCourt, .forestCourt, .snowField, .beachField])
    func switchingRoomsPreservesForegroundAndAFullTurnReturnsToTheSameView(environment: PreviewEnvironment) throws {
        let renderer=try StadiumPreviewRenderer()
        let width=128,height=256
        func buffer() throws -> CVPixelBuffer {
            try ForegroundMaskProcessor.buffer(width:width,height:height,format:kCVPixelFormatType_32BGRA)
        }
        let source=try buffer(),mask=try buffer()
        for (image,isMask) in [(source,false),(mask,true)] {
            CVPixelBufferLockBaseAddress(image,[])
            let bytes=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt8.self)
            let row=CVPixelBufferGetBytesPerRow(image)
            for y in 0..<height {for x in 0..<width {
                let i=y*row+x*4,inside=(48..<80).contains(x) && (80..<210).contains(y)
                bytes[i]=isMask ? (inside ? 255:0):31
                bytes[i+1]=isMask ? bytes[i]:97
                bytes[i+2]=isMask ? bytes[i]:182
                bytes[i+3]=255
            }}
            CVPixelBufferUnlockBaseAddress(image,[])
        }
        func pixels(_ image:CVPixelBuffer)->[UInt8] {
            CVPixelBufferLockBaseAddress(image,.readOnly)
            defer {CVPixelBufferUnlockBaseAddress(image,.readOnly)}
            let bytes=CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to:UInt8.self)
            let row=CVPixelBufferGetBytesPerRow(image)
            return (0..<height).flatMap { y in Array(UnsafeBufferPointer(start:bytes+y*row,count:width*4)) }
        }
        var camera=SceneCameraRig(aspect:0.5,subjectHeight:0.4,ground:SIMD2(0.5,0.85))
        camera.movement=0
        let stadium=try buffer(),indoor=try buffer(),turned=try buffer()
        try renderer.render(source:source,mask:mask,output:stadium,camera:camera,time:0,scene:true)
        try renderer.render(source:source,mask:mask,output:indoor,camera:camera,time:0,scene:true,environment:environment)
        camera.look.x=2*Float.pi
        try renderer.render(source:source,mask:mask,output:turned,camera:camera,time:0,scene:true,environment:environment)
        let a=pixels(stadium),b=pixels(indoor),c=pixels(turned)
        for y in 85..<205 {for x in 52..<76 {for channel in 0..<3 {
            let i=(y*width+x)*4+channel
            #expect(abs(Int(a[i])-Int(b[i]))<=1)
        }}}
        let backgroundDifference=(0..<(width*70*4)).reduce(0) {$0+abs(Int(a[$1])-Int(b[$1]))}
        #expect(backgroundDifference>width*70*4*8)
        let wrapDifference=zip(b,c).reduce(0) {$0+abs(Int($1.0)-Int($1.1))}
        #expect(Double(wrapDifference)/Double(b.count)<1)
    }
}
