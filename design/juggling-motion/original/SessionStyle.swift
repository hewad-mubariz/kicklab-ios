import SwiftUI
import UIKit

/// Visual tokens for capture and the post-session flow. No session logic lives here.
enum SessionStyle {
    static let mint = Color(red: 0.34, green: 0.96, blue: 0.65)
    static let deepGreen = Color(red: 0.025, green: 0.38, blue: 0.24)
    static let background = Color(red: 0.015, green: 0.045, blue: 0.055)
    static let panel = Color(red: 0.025, green: 0.085, blue: 0.095)
    static let rim = Color(red: 0.16, green: 0.27, blue: 0.28)
    static let secondary = Color.white.opacity(0.72)
    static let inset: CGFloat = 20
    static let radius: CGFloat = 12
}

struct SessionBackdrop: View {
    var body: some View {
        ZStack {
            SessionStyle.background
            RadialGradient(colors: [SessionStyle.deepGreen.opacity(0.18), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 480)
            LinearGradient(colors: [.clear, .black.opacity(0.52)], startPoint: .center, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SessionPanel: ViewModifier {
    var tint: Color = SessionStyle.rim
    var radius: CGFloat = SessionStyle.radius

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [Color(red: 0.04, green: 0.12, blue: 0.13), SessionStyle.panel], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(tint.opacity(0.8), lineWidth: 0.7))
    }
}

struct SessionHeader: View {
    let title: String
    let onBack: () -> Void
    var onHome: (() -> Void)? = nil

    var body: some View {
        HStack {
            control("chevron.left", label: "Back", action: onBack)
            Spacer(minLength: 8)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            Spacer(minLength: 8)
            if let onHome { control("house.fill", label: "Home", action: onHome) }
            else { Color.clear.frame(width: 44, height: 44) }
        }
        .padding(.horizontal, SessionStyle.inset - 5)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(SessionStyle.panel.opacity(0.75), in: Circle())
                .overlay(Circle().strokeBorder(SessionStyle.rim, lineWidth: 0.7))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(HomePressStyle())
        .accessibilityLabel(label)
    }
}

struct SessionSegments<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = option }
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: selection == option ? .semibold : .medium))
                        .foregroundStyle(selection == option ? .white : SessionStyle.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if selection == option {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(LinearGradient(colors: [SessionStyle.deepGreen, SessionStyle.deepGreen.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SessionStyle.mint, lineWidth: 0.8))
                                    .shadow(color: SessionStyle.mint.opacity(0.20), radius: 7)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(HomePressStyle())
                .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(SessionStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(SessionStyle.rim, lineWidth: 0.7))
    }
}

struct SessionAction: View {
    let title: String
    var symbol: String? = nil
    var primary = true
    var trailingSymbol = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol, !trailingSymbol { Image(systemName: symbol) }
                Text(title)
                if let symbol, trailingSymbol { Image(systemName: symbol) }
            }
            .font(.system(size: 15, weight: primary ? .bold : .medium))
            .foregroundStyle(primary ? Color(red: 0.015, green: 0.12, blue: 0.08) : .white)
            .frame(maxWidth: .infinity)
            .frame(minHeight: primary ? 52 : 48)
            .background {
                RoundedRectangle(cornerRadius: 17)
                    .fill(primary ? SessionStyle.mint : SessionStyle.panel.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(SessionStyle.mint.opacity(primary ? 0.8 : 0.7), lineWidth: 0.8))
                    .shadow(color: primary ? SessionStyle.mint.opacity(0.2) : .clear, radius: 12, y: 2)
            }
        }
        .buttonStyle(HomePressStyle())
    }
}

struct PostStatCard: View {
    let icon: String
    var iconColor: Color = SessionStyle.mint
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.75)
                Text(title).font(.system(size: 11)).foregroundStyle(SessionStyle.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 67, alignment: .leading)
        .modifier(SessionPanel())
        .accessibilityElement(children: .combine)
    }
}

/// Native slider behavior with the reference's small circular mint thumb.
struct SessionIntensitySlider: UIViewRepresentable {
    @Binding var value: Double

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = UIColor(SessionStyle.mint)
        slider.maximumTrackTintColor = UIColor(SessionStyle.rim)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { context in
            UIColor(SessionStyle.mint).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 18, height: 18))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.accessibilityLabel = "Effect intensity"
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        context.coordinator.value = $value
        slider.value = Float(value)
        slider.accessibilityValue = "\(Int((value * 100).rounded())) percent"
    }

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }
        @objc func changed(_ slider: UISlider) { value.wrappedValue = Double(slider.value) }
    }
}
