import CoreVideo
import Foundation
import Testing
@testable import kicklab

struct LosslessAlphaTests {
    @Test func alphaRoundTripsExactlyAcrossBackwardSeeksAndRejectsMissingTimes() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let w=63,h=17
        let writer=try LosslessAlphaCache.Writer(folder:folder,width:w,height:h)
        var expected:[[UInt8]]=[]
        for frame in 0..<2 {
            let values=(0..<w*h).map {UInt8(frame==0 ? ($0%w<30 ? 127:0):($0*113+$0/7)%256)}
            expected.append(values)
            let pixels=try ForegroundMaskProcessor.buffer(width:w,height:h,format:kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(pixels,[])
            let p=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<h {for x in 0..<w {p[y*row+x*4]=values[y*w+x]}}
            CVPixelBufferUnlockBaseAddress(pixels,[])
            try writer.append(pixels,at:Double(frame)*1001/60000)
        }
        try writer.finish()
        let reader=try LosslessAlphaCache.Reader(folder:folder)
        #expect(reader.frameCount==2)
        for frame in [1,0,1] {
            let pixels=try reader.frame(at:Double(frame)*1001/60000)
            CVPixelBufferLockBaseAddress(pixels,.readOnly)
            let p=CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<h {#expect(Array(UnsafeBufferPointer(start:p.advanced(by:y*row),count:w))==Array(expected[frame][y*w..<(y+1)*w]))}
            CVPixelBufferUnlockBaseAddress(pixels,.readOnly)
        }
        #expect(throws:(any Error).self) {try reader.frame(at:0.1)}
        try Data([0]).write(to:folder.appendingPathComponent("alpha.lzfse"))
        #expect(throws:(any Error).self) {try LosslessAlphaCache.Reader(folder:folder)}
    }
}
