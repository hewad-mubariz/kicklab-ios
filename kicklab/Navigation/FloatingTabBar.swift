import SwiftUI

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    TabHaptics.tabChanged()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.84)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: selection == tab ? tab.symbolNameSelected : tab.symbolName)
                            .font(.system(size: 20, weight: .regular))
                        Text(tab.title).font(.system(size: 9, weight: selection == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selection == tab ? HomeSurface.forest : HomeSurface.ink(scheme).opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background {
                        if selection == tab {
                            Circle()
                                .fill(LinearGradient(colors: [Color(red: 0.65, green: 1, blue: 0.69), Color(red: 0.25, green: 0.88, blue: 0.39)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(Circle().strokeBorder(Theme.brand.opacity(0.9), lineWidth: 2))
                                .shadow(color: Theme.brand.opacity(scheme == .dark ? 0.45 : 0.3), radius: 10)
                                .matchedGeometryEffect(id: "selected-tab", in: selectionAnimation)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HomePressStyle())
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 30)
                .fill(scheme == .dark ? Color(red: 0.025, green: 0.06, blue: 0.065).opacity(0.97) : Color(red: 0.96, green: 0.98, blue: 0.98).opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(HomeSurface.rim(scheme), lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 3)
        }
        .frame(maxWidth: 490)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .onAppear { TabHaptics.prepare() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main navigation")
    }
}
