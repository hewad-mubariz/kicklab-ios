import SwiftUI

struct HomeHeroView: View {
    let tagline: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: -1) {
                Text("KICK").foregroundStyle(HomeSurface.ink(scheme))
                Text("LAB").foregroundStyle(HomeSurface.green(scheme))
            }
            .font(Theme.brandWordmark(38))
            .tracking(-1.4)
            .accessibilityLabel("KickLab")

            Text("PRACTICE. IMPROVE. REPEAT.")
                .font(.system(size: 8, weight: .medium))
                .tracking(2.2)
                .foregroundStyle(HomeSurface.ink(scheme))
                .padding(.top, 1)

            HStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 0)
                Image("hero-ball-mascot")
                    .resizable().scaledToFit()
                    .frame(width: HomeSurface.mascotSize, height: 144)
                    .shadow(color: (scheme == .dark ? Theme.brand : HomeSurface.forest).opacity(0.24), radius: 14, y: 5)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "crown")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(scheme == .dark ? Theme.brand : HomeSurface.forest)
                    Text("BETTER\nPLAYERS.\nBRIGHTER\nTOMORROWS.")
                        .font(.custom("Futura-CondensedExtraBold", size: 16, relativeTo: .subheadline))
                        .italic()
                        .lineSpacing(-2)
                        .foregroundStyle(HomeSurface.ink(scheme))
                        .shadow(color: scheme == .light ? .white.opacity(0.65) : .clear, radius: 5)
                }
                .rotationEffect(.degrees(-9))
                .frame(width: 120)
                .accessibilityLabel(tagline)
                Spacer(minLength: 0)
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
    }
}
