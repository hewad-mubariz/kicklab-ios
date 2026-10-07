import SwiftUI

struct ModuleCardView: View {
    let module: TrainingModule
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isUtility: Bool { module.destination == .challenges || module.destination == .stats }
    private var compact: Bool { isUtility || module.destination == .penalties }
    private var artHeight: CGFloat { compact ? 53 : HomeSurface.sceneArtHeight }

    var body: some View {
        Button(action: action) {
            Group {
                if module.style == .comingSoon { comingSoonCard }
                else { activeCard }
            }
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: HomeSurface.cardRadius))
        }
        .buttonStyle(HomePressStyle())
        .disabled(!module.isAvailable)
        .accessibilityLabel(module.accessibilityLabel)
        .accessibilityIdentifier("module-\(module.id)")
    }

    private var activeCard: some View {
        VStack(spacing: 0) {
            if isUtility {
                Group {
                    if module.destination == .challenges {
                        Image("icon-challenges").resizable().scaledToFit().padding(3)
                    } else {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(scheme == .dark ? Theme.brand : Color(red: 0.18, green: 0.28, blue: 0.33))
                    }
                }
                .frame(height: artHeight)
                .frame(maxWidth: .infinity)
            } else {
                // GeometryReader constrains the portrait source to the grid column;
                // the centered landscape crop keeps the ball, targets and keeper visible.
                GeometryReader { geometry in
                    Image(module.imageName)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .offset(y: module.destination == .penalties ? 7 : 0)
                        .clipped()
                }
                .frame(height: artHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 3)
                .padding(.top, 3)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(module.title)
                    .font(.system(size: 14, weight: .bold).width(.condensed))
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .bottom, spacing: 3) {
                    Text(module.subtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(scheme == .dark ? HomeSurface.forest : .white)
                        .frame(width: 23, height: 23)
                        .background(scheme == .dark ? Theme.brand : HomeSurface.forest, in: Circle())
                }
            }
            .foregroundStyle(HomeSurface.ink(scheme))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: HomeSurface.sceneFooterHeight, alignment: .topLeading)
        }
        .background(HomeSurface.panel(scheme))
        .clipShape(RoundedRectangle(cornerRadius: HomeSurface.cardRadius))
        .modifier(HomePanel())
    }

    private var comingSoonCard: some View {
        VStack(spacing: 4) {
            Image(systemName: comingSoonSymbol)
                .font(.system(size: 25, weight: .light))
                .frame(height: 29)
            Text(module.title)
                .font(.system(size: 12, weight: .semibold).width(.condensed))
                .lineLimit(1).minimumScaleFactor(0.8)
            Text("Coming Soon").font(.system(size: 9))
        }
        .foregroundStyle(HomeSurface.ink(scheme).opacity(0.8))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(scheme == .dark ? Color(red: 0.17, green: 0.21, blue: 0.21).opacity(0.90) : Color(red: 0.89, green: 0.92, blue: 0.87).opacity(0.94), in: RoundedRectangle(cornerRadius: HomeSurface.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: HomeSurface.cardRadius).strokeBorder(HomeSurface.rim(scheme), lineWidth: 0.7))
    }

    private var comingSoonSymbol: String {
        switch module.id {
        case "dribbling": "cone"
        case "passing": "shoe"
        default: "trophy"
        }
    }
}
