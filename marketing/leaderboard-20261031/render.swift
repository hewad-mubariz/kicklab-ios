import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Extends the existing App Store artwork renderer; captured app pixels are not redrawn.
let root = URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "marketing/leaderboard-20261031")
let W: CGFloat = 1320, H: CGFloat = 2868
func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((hex>>16)&255)/255, green: CGFloat((hex>>8)&255)/255, blue: CGFloat(hex&255)/255, alpha: alpha) }
let lime = rgb(0xD0FA43), white = rgb(0xF3F4ED), muted = rgb(0xB9C6CD)
func font(_ size: CGFloat, _ condensed: Bool = false, _ bold: Bool = false) -> NSFont {
    condensed ? NSFont(name:"DINCondensed-Bold",size:size)! : NSFont.systemFont(ofSize:size,weight:bold ? .semibold : .regular)
}
func text(_ text:String, x:CGFloat, y:CGFloat, width:CGFloat, size:CGFloat, color:NSColor, condensed:Bool=false, bold:Bool=false, tracking:CGFloat=0, centered:Bool=false) {
    let paragraph=NSMutableParagraphStyle();paragraph.alignment = centered ? .center : .left
    var fitted = size
    while (text as NSString).size(withAttributes:[.font:font(fitted,condensed,bold),.kern:tracking]).width > width && fitted > size * 0.65 { fitted -= 1 }
    (text as NSString).draw(in:NSRect(x:x,y:y,width:width,height:size*1.8),withAttributes:[.font:font(fitted,condensed,bold),.foregroundColor:color,.kern:tracking,.paragraphStyle:paragraph])
}
func path(_ points:[CGPoint], color:NSColor, line:CGFloat) {
    let p=NSBezierPath();p.move(to:points[0]); for q in points.dropFirst(){p.line(to:q)};p.lineWidth=line;color.setStroke();p.stroke()
}
func draw(_ image: NSImage, rect:NSRect) { image.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high]) }
func canvas(width:Int,height:Int, paint:()->Void) -> NSBitmapImageRep {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32)!
    let context=NSGraphicsContext(bitmapImageRep:rep)!;NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=context
    context.cgContext.translateBy(x:0,y:CGFloat(height));context.cgContext.scaleBy(x:1,y:-1)
    NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
    paint();NSGraphicsContext.restoreGraphicsState();return rep
}
func opaquePNG(_ rep: NSBitmapImageRep) -> Data {
    let image=rep.cgImage!
    let c=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
    let data=NSMutableData();let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,c.makeImage()!,nil);CGImageDestinationFinalize(destination)
    return data as Data
}
let frame=NSImage(contentsOf:root.appendingPathComponent("sources/iphone-17-pro-max-blue.png"))!
struct Copy: Decodable {
    let language: String
    let storefronts: [String]
    let headline: [String]
    let subtitle: String
    let disclosure: String
}
let specs = try JSONDecoder().decode([Copy].self, from: Data(contentsOf: root.appendingPathComponent("copy.json")))
for spec in specs {
    let rep=canvas(width:1320,height:2868) {
        let c=NSGraphicsContext.current!.cgContext
        let colors=[rgb(0x08121C).cgColor,rgb(0x183747).cgColor,rgb(0x071019).cgColor] as CFArray
        let grad=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.62,1])!
        c.drawLinearGradient(grad,start:CGPoint(x:0,y:0),end:CGPoint(x:1320,y:2868),options:[])
        // Restrained pitch markings sit behind the device, keeping the UI dominant.
        let pitch=NSBezierPath(ovalIn:NSRect(x:-650,y:1180,width:2350,height:1450));pitch.lineWidth=2;rgb(0x95B9C9,0.15).setStroke();pitch.stroke()
        path([CGPoint(x:0,y:2450),CGPoint(x:1320,y:1800)],color:rgb(0x95B9C9,0.12),line:2)
        for y in stride(from:52,through:2868,by:46) { for x in stride(from:26,through:1320,by:46) {
            rgb(0xDAECF4,0.035).setFill();NSBezierPath(ovalIn:NSRect(x:x,y:y,width:2,height:2)).fill()
        }}
        text("JUGGLE DUDE",x:94,y:85,width:800,size:34,color:white,bold:true,tracking:5)
        text("04",x:1144,y:87,width:100,size:27,color:muted,tracking:3)
        path([CGPoint(x:94,y:149),CGPoint(x:1226,y:149)],color:rgb(0xA1B8C5,0.25),line:1)
        text(spec.headline[0],x:60,y:216,width:1200,size:166,color:white,condensed:true,centered:true)
        text(spec.headline[1],x:60,y:374,width:1200,size:166,color:lime,condensed:true,centered:true)
        text(spec.subtitle,x:80,y:553,width:1160,size:40,color:muted,centered:true)
        // Like the Maccu references: enlarge the device and let its lower edge
        // continue beyond the canvas. Source UI pixels keep their proportions.
        text(spec.disclosure,x:80,y:613,width:1160,size:27,color:muted,centered:true)
        let deviceWidth: CGFloat = 1220
        let deviceY: CGFloat = 665
        let device=NSRect(x:(W-deviceWidth)/2,y:deviceY,width:deviceWidth,height:deviceWidth*3000/1470)
        let sc=device.width/1470
        let screen=NSRect(x:device.minX+75*sc,y:device.minY+66*sc,width:1320*sc,height:2868*sc)
        NSGraphicsContext.saveGraphicsState()
        let shadow=NSShadow();shadow.shadowColor=NSColor.black.withAlphaComponent(0.5);shadow.shadowBlurRadius=50;shadow.shadowOffset=NSSize(width:0,height:28);shadow.set()
        rgb(0x010507).setFill();NSBezierPath(roundedRect:device.insetBy(dx:20,dy:20),xRadius:180*sc,yRadius:180*sc).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState();NSBezierPath(roundedRect:screen,xRadius:177*sc,yRadius:177*sc).addClip()
        let img=NSImage(contentsOf:root.appendingPathComponent("screens/"+spec.language+".png"))!
        draw(img,rect:screen)
        NSGraphicsContext.restoreGraphicsState();draw(frame,rect:device)
    }
    let data=opaquePNG(rep)
    for storefront in spec.storefronts {
        let folder=root.appendingPathComponent("screenshots/"+storefront)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try data.write(to:folder.appendingPathComponent("04-leaderboard-1320x2868.png"))
    }
}
print("Rendered \(specs.count) screenshots at 1320x2868")
let sheet=canvas(width:2200,height:1000) {
    rgb(0x08121C).setFill(); NSRect(x:0,y:0,width:2200,height:1000).fill()
    for (i,spec) in specs.enumerated() {
        text(spec.language.uppercased(),x:CGFloat(i)*440+10,y:15,width:420,size:20,color:white,centered:true)
        let im=NSImage(contentsOf:root.appendingPathComponent("screenshots/"+spec.storefronts[0]+"/04-leaderboard-1320x2868.png"))!
        draw(im,rect:NSRect(x:CGFloat(i)*440+10,y:60,width:420,height:420*2868/1320))
    }
}
try opaquePNG(sheet).write(to:root.appendingPathComponent("contact-sheet.png"))
