import CoreGraphics
import CoreText
import Foundation
import MetalKit

/// Crisp native typography, shared by the room and its floor reflection.
/// The top half of the transparent atlas is the wordmark; the bottom is a motto.
nonisolated enum ArenaSignage {
    static func make(device: MTLDevice) throws -> MTLTexture {
        let width = 2048, height = 1024
        guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ForegroundMaskProcessor.Failure.allocation
        }
        func line(_ string: String, size: CGFloat, color: CGColor, kern: CGFloat = 0) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string:string,attributes:[
                NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("HelveticaNeue-BoldItalic" as CFString,size,nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):color,
                NSAttributedString.Key(kCTKernAttributeName as String):kern]))
        }
        let white = CGColor(red:0.94,green:0.97,blue:1,alpha:1)
        let mint = CGColor(red:0.14,green:1,blue:0.70,alpha:1)
        let juggle=line("Juggle ",size:302,color:white),dude=line("Dude",size:302,color:mint)
        let juggleWidth=CTLineGetTypographicBounds(juggle,nil,nil,nil),dudeWidth=CTLineGetTypographicBounds(dude,nil,nil,nil)
        let x=(Double(width)-juggleWidth-dudeWidth)*0.5
        context.textPosition=CGPoint(x:x,y:658);CTLineDraw(juggle,context)
        context.textPosition=CGPoint(x:x+juggleWidth,y:658);CTLineDraw(dude,context)
        let motto=line("PRACTICE. IMPROVE. REPEAT.",size:69,color:white,kern:6)
        context.textPosition=CGPoint(x:(Double(width)-CTLineGetTypographicBounds(motto,nil,nil,nil))/2,y:228)
        CTLineDraw(motto,context)
        guard let image=context.makeImage() else {throw ForegroundMaskProcessor.Failure.allocation}
        return try MTKTextureLoader(device:device).newTexture(cgImage:image,options:[.SRGB:true,.generateMipmaps:true])
    }
}
