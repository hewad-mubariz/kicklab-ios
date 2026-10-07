import SwiftUI

/// Deterministic GPU sparks, triggered by a real count change and then allowed
/// to settle. Reducing motion removes the radial movement altogether.
struct LiveCounterBurst: View {
    let trigger: Int
    var warn = false
    var reviewAge: Float? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date.distantPast
    @State private var active = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active || reduceMotion || reviewAge != nil)) { clock in
            MetalEffectSurface { size in
                EffectFrame(size: size, center: SIMD2(Float(size.width / 2), Float(size.height / 2)),
                    radius: Float(size.width * 0.225), time: 0, intensity: 1,
                    counter: true, burstAge: reduceMotion ? 10 : reviewAge ?? Float(clock.date.timeIntervalSince(started)),
                    seed: Float(trigger % 1000), tint: warn ? SIMD3(1, 0.55, 0.12) : SIMD3(0.18, 1, 0.4))
            }
        }
        .frame(width: 330, height: 250)
        .allowsHitTesting(false).accessibilityHidden(true)
        .task(id: trigger) {
            active = false
            guard trigger > 0, reviewAge == nil, !reduceMotion else { return }
            started = .now; active = true
            do { try await Task.sleep(for: .milliseconds(1050)) } catch { return }
            active = false
        }
    }
}

struct LiveTouchCounter: View {
    let value: Int
    var warn = false
    var size: CGFloat = 100
    var reviewAge: Float? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bump = false
    private var tint: Color { warn ? Theme.warn : SessionStyle.mint }

    var body: some View {
        Text("\(value)")
            .font(.system(size: size, weight: .black, design: .default))
            .monospacedDigit().tracking(-4)
            .foregroundStyle(LinearGradient(colors: [.white, tint.opacity(0.95), tint], startPoint: .top, endPoint: .bottom))
            .shadow(color: tint.opacity(0.8), radius: 7)
            .shadow(color: tint.opacity(0.38), radius: 22)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
            .scaleEffect(bump && !reduceMotion ? 1.065 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.62), value: bump)
            .frame(width: 292, height: 120)
            .background { LiveCounterBurst(trigger: value, warn: warn, reviewAge: reviewAge) }
            .minimumScaleFactor(0.55).lineLimit(1)
            .accessibilityLabel("\(value) touches")
            .task(id: value) {
                bump = false
                guard value > 0 else { return }
                bump = true
                do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
                bump = false
            }
    }
}

struct LiveMilestonePill: View {
    let next: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(LinearGradient(colors: [.white, Theme.star, .orange], startPoint: .top, endPoint: .bottom))
                .shadow(color: Theme.star.opacity(0.6), radius: 7)
            Text("Next: \(next)")
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .background(.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(SessionStyle.mint.opacity(0.95), lineWidth: 1.4))
        .shadow(color: SessionStyle.mint.opacity(0.35), radius: 9)
    }
}

// MARK: - Person tracking corners

struct TrackingCorners: View {
    let rect: CGRect
    var color: Color = SessionStyle.mint

    var body: some View {
        Canvas { context, size in
            let frame = CGRect(
                x: rect.minX * size.width,
                y: rect.minY * size.height,
                width: rect.width * size.width,
                height: rect.height * size.height
            )
            let arm: CGFloat = min(24, min(frame.width, frame.height) * 0.2)
            let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)

            func corner(_ origin: CGPoint, dx: CGFloat, dy: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: origin.x + dx * arm, y: origin.y))
                path.addLine(to: origin)
                path.addLine(to: CGPoint(x: origin.x, y: origin.y + dy * arm))
                context.stroke(path, with: .color(color.opacity(0.95)), style: stroke)
            }

            corner(CGPoint(x: frame.minX, y: frame.minY), dx: 1, dy: 1)
            corner(CGPoint(x: frame.maxX, y: frame.minY), dx: -1, dy: 1)
            corner(CGPoint(x: frame.minX, y: frame.maxY), dx: 1, dy: -1)
            corner(CGPoint(x: frame.maxX, y: frame.maxY), dx: -1, dy: -1)
        }
        .shadow(color: color.opacity(0.7), radius: 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Side live stats

struct LiveStatCard: View {
    /// Asset catalog image (prefer) or SF Symbol fallback.
    var imageName: String? = nil
    var symbol: String? = nil
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let imageName {
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(height: 22)

            Text(value)
                .font(.system(size: 17, weight: .bold, design: .default))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(width: 62)
        .padding(.vertical, 9)
        .background(SessionStyle.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
        }
    }
}
