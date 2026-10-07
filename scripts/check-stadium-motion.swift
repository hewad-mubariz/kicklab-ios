import Foundation
import CoreImage
import CoreVideo
import Metal
import simd
@main struct Check {
 static func main() throws {
 let context=CIContext(mtlDevice:MTLCreateSystemDefaultDevice()!),camera=SceneCameraRig(aspect:320.0/480,subjectHeight:0.4,ground:SIMD2(0.5,0.85))
 let tracker=StadiumCameraMotion(personCrop:CGRect(x:0.25,y:0.35,width:0.5,height:0.5),context:context,camera:camera)
 func frame(_ dx:Int,_ dy:Int) throws -> CVPixelBuffer {
 let b=try ForegroundMaskProcessor.buffer(width:320,height:480,format:kCVPixelFormatType_32BGRA)
 CVPixelBufferLockBaseAddress(b,[]);defer{CVPixelBufferUnlockBaseAddress(b,[])}
 let p=CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(b)
 for y in 0..<480 {for x in 0..<320 {
 let xx=x-dx,yy=y-dy;let v=UInt8(abs(((xx/7)*31+(yy/11)*53+(xx/19)*(yy/13)*11)%210)+20)
 let i=y*row+x*4;p[i]=v;p[i+1]=v;p[i+2]=v;p[i+3]=255
 }};return b
 }
 _=try tracker.update(frame(0,0));let measured=try tracker.update(frame(5,3))
 let expected=StadiumCameraMotion.integrate(.zero,imageShift:SIMD2(5.0/320,3.0/480),aspect:camera.aspect,tanHalfFOV:camera.tanHalfFOV)
 print("MEASURED \(measured) EXPECTED \(expected)")
 guard simd_distance(measured,expected)<0.004 else {throw NSError(domain:"CameraMotion",code:1)}
 }
}
