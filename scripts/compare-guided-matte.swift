// STAGES_FOLDER OUTPUT_FOLDER. MPS trial; no production filter is selected here.
import CoreGraphics
import Foundation
import ImageIO
import MetalKit
import MetalPerformanceShaders
import UniformTypeIdentifiers

@main struct CompareGuidedMatte {
    static func main() throws {
        let a=CommandLine.arguments,input=URL(fileURLWithPath:a[1]),out=URL(fileURLWithPath:a[2])
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!,loader=MTKTextureLoader(device:device)
        for n in [60,125,150,195] {
            let prefix=String(format:"%03d-",n)
            let color=try loader.newTexture(URL:input.appendingPathComponent(prefix+"person-source.png"),options:[.SRGB:false])
            let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input.appendingPathComponent(prefix+"person-repaired.png") as CFURL,nil)!,0,nil)!
            let w=image.width,h=image.height
            var bytes=[UInt8](repeating:0,count:w*h)
            bytes.withUnsafeMutableBytes { b in
                let context=CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
                context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            }
            let guideImage=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input.appendingPathComponent(prefix+"person-guide.png") as CFURL,nil)!,0,nil)!
            var guide=[UInt8](repeating:0,count:w*h)
            guide.withUnsafeMutableBytes { b in
                let context=CGContext(data:b.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0)!
                context.interpolationQuality = .high;context.draw(guideImage,in:CGRect(x:0,y:0,width:w,height:h))
            }
            func texture(_ format:MTLPixelFormat)->MTLTexture {let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false);d.usage=[.shaderRead,.shaderWrite];d.storageMode = .shared;return device.makeTexture(descriptor:d)!}
            let mask=texture(.r32Float),coefficients=texture(.rgba32Float),result=texture(.r32Float),weights=texture(.r32Float)
            let values=bytes.map {Float($0)/255};values.withUnsafeBytes {mask.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
            var confidence=[Float](repeating:0.001,count:w*h)
            for y in 0..<h {for x in 0..<w {
                var low=bytes[y*w+x],high=low
                for dy in [-6,0,6] {for dx in [-6,0,6] {
                    let value=bytes[min(h-1,max(0,y+dy))*w+min(w-1,max(0,x+dx))]
                    low=min(low,value);high=max(high,value)
                }}
                if (low>250 && guide[y*w+x]>180) || (high<4 && guide[y*w+x]<40) {confidence[y*w+x]=1}
            }}
            confidence.withUnsafeBytes {weights.replace(region:MTLRegionMake2D(0,0,w,h),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:w*4)}
            for diameter in [13,25,41] {for epsilon:Float in [0.0001,0.001] {
                let filter=MPSImageGuidedFilter(device:device,kernelDiameter:diameter);filter.epsilon=epsilon
                let command=queue.makeCommandBuffer()!
                filter.encodeRegression(to:command,sourceTexture:mask,guidanceTexture:color,weightsTexture:a.contains("--weighted") ? weights:nil,destinationCoefficientsTexture:coefficients)
                filter.encodeReconstruction(to:command,guidanceTexture:color,coefficientsTexture:coefficients,destinationTexture:result)
                command.commit();command.waitUntilCompleted();if let error=command.error {throw error}
                var v=[Float](repeating:0,count:w*h);v.withUnsafeMutableBytes {result.getBytes($0.baseAddress!,bytesPerRow:w*4,from:MTLRegionMake2D(0,0,w,h),mipmapLevel:0)}
                let data=Data(v.map {UInt8((max(0,min(1,$0))*255).rounded())}),provider=CGDataProvider(data:data as CFData)!
                let png=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                let destination=out.appendingPathComponent(prefix+"d\(diameter)-e\(epsilon).png")
                let writer=CGImageDestinationCreateWithURL(destination as CFURL,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(writer,png,nil);guard CGImageDestinationFinalize(writer) else {fatalError("PNG")}
            }}
            print("frame \(n)")
        }
    }
}
