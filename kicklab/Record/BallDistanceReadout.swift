import SwiftUI
import UIKit

struct BallDistanceReadout: View {
    let value: String
    let detail: String
    var paused = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack(spacing: 7) {
                Text("DISTANCE").tracking(1.8)
                Text("EXPERIMENTAL").tracking(0.8).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: .capsule)
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            Text(value).font(.system(size: compact ? 34 : 56, weight: .semibold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.65)
                .accessibilityIdentifier("ball-distance-value")
            Text(detail).font(.system(size: compact ? 11 : 12, weight: .medium))
                .foregroundStyle(paused ? Color.orange : SessionStyle.mint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ball-distance-detail")
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .contain)
    }
}

/// Distance is burned into app captures only (ARKit floor, experimental), after the visual
/// effect pass. The badge never uses a touch count or a guessed video scale.
nonisolated enum BallDistanceBadgeRenderer {
    static func draw(in context: CGContext, size: CGSize, state: BallDistanceTimeline.Sample) {
        let canvas = CGSize(width: 400, height: 138)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { renderer in
            let c = renderer.cgContext
            c.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
            c.addPath(UIBezierPath(roundedRect: CGRect(origin: .zero, size: canvas), cornerRadius: 20).cgPath)
            c.fillPath()
            ("DISTANCE  /  EXPERIMENTAL" as NSString).draw(at: CGPoint(x: 20, y: 16), withAttributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.white.withAlphaComponent(0.8), .kern: 1.5])
            (state.valueLabel as NSString).draw(at: CGPoint(x: 18, y: 38), withAttributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 45, weight: .semibold), .foregroundColor: UIColor.white])
            (state.status.label as NSString).draw(at: CGPoint(x: 20, y: 105), withAttributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: state.status == .paused || state.status == .needsSetup ? UIColor.systemOrange :
                    UIColor(red: 0.72, green: 0.98, blue: 0.82, alpha: 1)])
        }
        guard let cg = image.cgImage else { return }
        let width = min(size.width * 0.52, size.height * 0.55)
        let rect = CGRect(x: size.width * 0.04, y: size.height * 0.04,
            width: width, height: width * canvas.height / canvas.width)
        context.saveGState()
        // CGContext image coordinates are reversed after the video context's top-left flip.
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(cg, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
