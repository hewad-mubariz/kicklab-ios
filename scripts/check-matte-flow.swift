import Foundation
import Vision
import CoreVideo
func frame(_ dx:Int,_ dy:Int)->CVPixelBuffer {
 var b:CVPixelBuffer?;CVPixelBufferCreate(nil,128,128,kCVPixelFormatType_32BGRA,nil,&b)
 CVPixelBufferLockBaseAddress(b!,[]);let p=CVPixelBufferGetBaseAddress(b!)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(b!)
 for y in 0..<128 {for x in 0..<128 {let xx=x-dx,yy=y-dy;let v=UInt8((xx>=25 && xx<95 && yy>=25 && yy<95) ? 70+(xx*11+yy*13)%160:10);for c in 0..<3 {p[y*row+x*4+c]=v};p[y*row+x*4+3]=255}}
 CVPixelBufferUnlockBaseAddress(b!,[]);return b!
}
let prev=frame(0,0),current=frame(8,5)
let req=VNGenerateOpticalFlowRequest(targetedCVPixelBuffer:current,orientation:.up)
req.computationAccuracy = .high
try VNImageRequestHandler(cvPixelBuffer:prev,orientation:.up).perform([req])
let b=req.results!.first!.pixelBuffer
CVPixelBufferLockBaseAddress(b,.readOnly)
let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:Float.self),r=CVPixelBufferGetBytesPerRow(b)/4
var x:Float=0,y:Float=0
for yy in 40..<80 {for xx in 40..<80 {x+=p[yy*r+xx*2];y+=p[yy*r+xx*2+1]}}
print("target=current handler=previous: \(x/1600),\(y/1600)")
