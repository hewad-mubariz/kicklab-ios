import SwiftUI

/// The reference uses a small crown, with loose gold flecks around the whole result.
struct CrownBurst: View {
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 37, weight: .regular))
            .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.96, blue: 0.63), Theme.star, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: Theme.star.opacity(0.55), radius: 13)
            .scaleEffect(active || reduceMotion ? 1 : 0.78)
            .opacity(active ? 1 : 0)
            .accessibilityHidden(true)
    }
}

struct CompletionFlecks: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ForEach(0..<26, id: \.self) { index in
                // Deterministic scatter leaves the central numbers and labels clear.
                let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                let x = geometry.size.width / 2 + side * geometry.size.width * CGFloat(0.29 + Double((index * 7) % 9) / 70)
                let y = geometry.size.height * CGFloat((index * 37 + 9) % 100) / 100
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(index.isMultiple(of: 3) ? Color(red: 1, green: 0.94, blue: 0.55) : Theme.star)
                    .frame(width: index.isMultiple(of: 3) ? 4 : 2, height: index.isMultiple(of: 4) ? 8 : 4)
                    .rotationEffect(.degrees(Double(index * 31)))
                    .shadow(color: Theme.star.opacity(0.65), radius: 4)
                    .position(x: active || reduceMotion ? x : geometry.size.width / 2, y: active || reduceMotion ? y : 30)
                    .opacity(active ? (index.isMultiple(of: 4) ? 0.95 : 0.55) : 0)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.85), value: active)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

typealias SessionConfetti = CrownBurst
