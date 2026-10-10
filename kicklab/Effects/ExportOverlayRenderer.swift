import CoreGraphics
import Foundation

/// One deterministic drawing path for the editor and encoded video frames.
/// Motion is evaluated from media timestamps, so export and scrubbing agree.
nonisolated enum ExportOverlayRenderer {
    static let badgeSize = CGSize(width: 240, height: 180)

    static func image(style: ExportBadgeStyle,
                      time: Double, counter: ExportCounterState, scale: CGFloat = 2) -> CGImage? {
        let size = badgeSize
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: scale, y: -scale)
        drawBadge(in: ctx, style: style, time: time, counter: counter)
        return ctx.makeImage()
    }

    static func draw(in ctx: CGContext, size: CGSize, settings: ExportOverlaySettings,
                     time: Double, counter: ExportCounterState) {
        guard settings.counter.enabled else { return }
        let item = settings.counter, rect = item.placement.rect(in: size)
        ctx.saveGState()
        ctx.translateBy(x: rect.midX, y: rect.midY)
        ctx.rotate(by: item.placement.radians)
        ctx.scaleBy(x: rect.width / badgeSize.width, y: rect.height / badgeSize.height)
        ctx.translateBy(x: -badgeSize.width / 2, y: -badgeSize.height / 2)
        drawBadge(in: ctx, style: item.style, time: time, counter: counter)
        ctx.restoreGState()
    }

    private static func drawBadge(in ctx: CGContext, style: ExportBadgeStyle,
                                  time: Double, counter: ExportCounterState) {
        switch style {
        case .normal: NormalCounterAppearance.draw(in: ctx, counter: counter)
        case .classic: ClassicCounterAppearance.draw(in: ctx, counter: counter)
        default: CounterArt.draw(style, in: ctx, time: time, counter: counter)
        }
    }
}
