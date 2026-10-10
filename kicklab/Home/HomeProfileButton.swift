import SwiftUI

/// The soft monoline avatar from the profile icon concepts, drawn at display resolution.
struct HomeProfileButton: View {
    let action: () -> Void
    var zoom: Namespace.ID? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            ProfileMonolineMark()
                .frame(width: 29, height: 29)
                .frame(width: 48, height: 48)
                .background {
                    Circle().fill(LinearGradient(
                        colors: [
                            .white.opacity(scheme == .dark ? 0.12 : 0.8),
                            .white.opacity(scheme == .dark ? 0.015 : 0.2),
                            .white.opacity(scheme == .dark ? 0.045 : 0.5)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                }
                .glassEffect(.regular.interactive(), in: .circle)
                .overlay {
                    Circle().strokeBorder(LinearGradient(
                        colors: [.white.opacity(0.38), .white.opacity(0.03), .white.opacity(0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.65)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HomeIconZoomSource(id: "profile", zoom: zoom))
        .accessibilityLabel("Open profile")
        .accessibilityIdentifier("home-profile")
    }
}

struct ProfileMonolineMark: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let stroke = StrokeStyle(lineWidth: size * 0.072, lineCap: .round, lineJoin: .round)

            ZStack {
                // One flowing line rises from the left shoulder, loops around the head,
                // and returns to the neckline. The right shoulder supplies the accent.
                Path { path in
                    path.move(to: point(0.11, 0.88, size))
                    path.addCurve(to: point(0.40, 0.60, size),
                                  control1: point(0.11, 0.69, size),
                                  control2: point(0.26, 0.67, size))
                    path.addCurve(to: point(0.67, 0.28, size),
                                  control1: point(0.55, 0.52, size),
                                  control2: point(0.68, 0.44, size))
                    path.addCurve(to: point(0.43, 0.12, size),
                                  control1: point(0.66, 0.12, size),
                                  control2: point(0.54, 0.06, size))
                    path.addCurve(to: point(0.35, 0.36, size),
                                  control1: point(0.33, 0.16, size),
                                  control2: point(0.31, 0.26, size))
                    path.addCurve(to: point(0.51, 0.56, size),
                                  control1: point(0.38, 0.48, size),
                                  control2: point(0.43, 0.53, size))
                }
                .stroke(TrainingHomeStyle.ink(scheme), style: stroke)

                Path { path in
                    path.move(to: point(0.62, 0.61, size))
                    path.addCurve(to: point(0.89, 0.88, size),
                                  control1: point(0.78, 0.64, size),
                                  control2: point(0.89, 0.69, size))
                }
                .stroke(TrainingHomeStyle.accent(scheme), style: stroke)
            }
        }
        .accessibilityHidden(true)
    }

    private func point(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> CGPoint {
        CGPoint(x: x * size, y: y * size)
    }
}
