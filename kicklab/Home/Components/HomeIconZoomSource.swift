import SwiftUI

/// Keep the native zoom snapshot aligned with Home's 48-point glass icons.
struct HomeIconZoomSource: ViewModifier {
    let id: String
    let zoom: Namespace.ID?

    func body(content: Content) -> some View {
        if let zoom {
            content.matchedTransitionSource(id: id, in: zoom) { source in
                source
                    .background(.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .circular))
                    .shadow(color: .clear, radius: 0)
            }
        } else {
            content
        }
    }
}
