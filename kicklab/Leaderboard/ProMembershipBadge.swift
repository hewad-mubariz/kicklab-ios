import SwiftUI

/// A small membership mark, separate from the seal used for reviewed scores.
/// Drawn natively so every size stays sharp without adding raster assets.
struct ProMembershipBadge: View {
    var size: CGFloat = 16
    static var title: String {
        String(localized: "Pro member", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
    }

    var body: some View {
        ZStack {
            ProHexagon().fill(Color(red: 0.10, green: 0.17, blue: 0.11))
            ProHexagon().strokeBorder(
                LinearGradient(colors: [Color(red: 0.80, green: 0.96, blue: 0.48),
                                        Color(red: 0.34, green: 0.65, blue: 0.43),
                                        LeaderboardStyle.lime], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1.2)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.49, weight: .heavy))
                .foregroundStyle(LeaderboardStyle.lime)
        }
        .frame(width: size, height: size)
        .fixedSize()
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + size * 0.25 }
        .anchorPreference(key: ProBadgeAnchor.self, value: .bounds) { $0 }
        .accessibilityHidden(true)
    }
}

private struct ProHexagon: InsettableShape {
    var inset: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset + 0.5, dy: inset + 0.5)
        let points = [CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + r.height * 0.25),
                      CGPoint(x: r.maxX, y: r.maxY - r.height * 0.25), CGPoint(x: r.midX, y: r.maxY),
                      CGPoint(x: r.minX, y: r.maxY - r.height * 0.25), CGPoint(x: r.minX, y: r.minY + r.height * 0.25)]
        // Short quadratic corners soften the facets at small text sizes.
        var path = Path()
        for i in points.indices {
            let p = points[i], before = points[(i + 5) % 6], after = points[(i + 1) % 6]
            let start = CGPoint(x: p.x + (before.x - p.x) * 0.16, y: p.y + (before.y - p.y) * 0.16)
            let end = CGPoint(x: p.x + (after.x - p.x) * 0.16, y: p.y + (after.y - p.y) * 0.16)
            if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
            path.addQuadCurve(to: end, control: p)
        }
        path.closeSubpath()
        return path
    }
    func inset(by amount: CGFloat) -> Self { Self(inset: inset + amount) }
}

private struct ProBadgeAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct ProMembershipExplanation: ViewModifier {
    let id: String
    @State private var showsExplanation = false

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ProBadgeAnchor.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    let bounds = geometry[anchor]
                    // A sibling of the row/podium button: never nest buttons or
                    // change the card's layout to enlarge this small mark's target.
                    Button { showsExplanation = true } label: {
                        Color.clear.frame(width: 44, height: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .position(x: bounds.midX, y: bounds.midY)
                    .accessibilityLabel(ProMembershipBadge.title)
                    .accessibilityIdentifier(id)
                }
            }
        }
        .alert(ProMembershipBadge.title, isPresented: $showsExplanation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This player has an active Juggle Dude Pro subscription. Membership does not affect rankings.")
        }
    }
}

extension View {
    func proMembershipExplanation(id: String) -> some View {
        modifier(ProMembershipExplanation(id: id))
    }
}
