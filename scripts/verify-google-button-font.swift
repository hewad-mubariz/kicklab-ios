// xcrun swift scripts/verify-google-button-font.swift font.ttf subset.json output-directory
// Run separately for the original and subset fonts; compare renders.json for pixels/metrics.
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("Expected font.ttf, subset.json and output directory") }
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[3])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [String: Any]
let labels = manifest["labels"] as! [String: String]
guard let provider = CGDataProvider(url: input as CFURL), let graphicsFont = CGFont(provider) else { fatalError("Invalid font") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var results = [[String: Any]]()
for locale in labels.keys.sorted() {
    let label = labels[locale]!
    for size: CGFloat in [17, 22, 34, 48] {
        for weight in [400, 500, 700] {
            for dark in [false, true] {
                let variation: [NSNumber: NSNumber] = [0x77676874: NSNumber(value: weight), // wght
                    0x6f70737a: NSNumber(value: min(18, Double(size))), // opsz
                    0x47524144: 0] // GRAD
                let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
                let font = CTFontCreateWithGraphicsFont(graphicsFont, size, nil, descriptor)
                // Named optical-size/weight instances have different PostScript names.
                let fontName = CTFontCopyPostScriptName(font) as String
                precondition(fontName.hasPrefix("GoogleSans"), "Unexpected font fallback: \(fontName)")
                let characters = Array(label.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                precondition(CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count), "Missing label character")
                precondition(!glyphs.contains(0), "Missing glyph")
                let ink: CGFloat = dark ? 0.9 : 0.12
                let attributed = NSAttributedString(string: label, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: ink, alpha: 1)])
                let line = CTLineCreateWithAttributedString(attributed)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let width = Int(ceil(advance)) + 48, height = Int(ceil(ascent + descent)) + 48
                let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(gray: dark ? 0.08 : 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.textPosition = CGPoint(x: 24, y: 24 + descent)
                CTLineDraw(line, context)
                let pixels = Data(bytes: context.data!, count: height * width * 4)
                let name = "\(locale)-\(Int(size))-\(weight)-\(dark ? "dark" : "light")"
                let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name + ".png") as CFURL,
                    "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil)
                precondition(CGImageDestinationFinalize(destination))
                results.append(["name": name, "font": fontName, "advance": advance, "ascent": ascent, "descent": descent,
                    "pixel_sha256": SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()])
            }
        }
    }
}
try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("renders.json"))
print("Rendered \(results.count) labels with no missing glyphs")
