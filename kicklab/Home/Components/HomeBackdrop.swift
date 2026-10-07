import SwiftUI

struct HomeBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            Image(scheme == .dark ? "pitch-night" : "pitch-day")
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay {
                    LinearGradient(stops: scheme == .dark ? [
                        .init(color: Color(red: 0.01, green: 0.06, blue: 0.07).opacity(0.42), location: 0),
                        .init(color: .clear, location: 0.4),
                        .init(color: .black.opacity(0.32), location: 1)
                    ] : [
                        .init(color: Color.white.opacity(0.48), location: 0),
                        .init(color: Color.white.opacity(0.12), location: 0.28),
                        .init(color: .clear, location: 0.46),
                        .init(color: HomeSurface.forest.opacity(0.15), location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
