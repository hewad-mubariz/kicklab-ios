import SwiftUI

enum ReplayTool: String, Identifiable {
    case counter = "Counter", timer = "Timer", ball = "Ball", effects = "Effects", graph = "Graph"
    var id: String { rawValue }
}

struct ReplayToolbox: View {
    let counterStyle: ExportBadgeStyle
    let onClose: () -> Void
    let onSelect: (ReplayTool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Customize replay").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
                .accessibilityLabel("Close customization tools")
                .accessibilityIdentifier("replay-close-tools")
            }
            HStack(spacing: 9) {
                tile(.counter)
                tile(.timer)
                tile(.ball)
            }
            HStack(spacing: 9) {
                tile(.effects)
                tile(.graph)
                backgroundsPreview
            }
        }
        .padding(16).foregroundStyle(.white)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    private func tile(_ tool: ReplayTool) -> some View {
        Button { onSelect(tool) } label: {
            VStack(spacing: 6) {
                preview(for: tool).frame(height: 52).accessibilityHidden(true)
                Text(tool.rawValue).font(.system(size: 11, weight: .medium))
            }.padding(.horizontal, 10).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [.white.opacity(0.1), .white.opacity(0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), in: .rect(cornerRadius: 17))
                .overlay {
                    RoundedRectangle(cornerRadius: 17)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                }
                .contentShape(.rect(cornerRadius: 17))
        }.buttonStyle(.plain)
            .accessibilityLabel(tool.rawValue)
            .accessibilityIdentifier("replay-tool-\(tool.rawValue.lowercased())")
    }

    @ViewBuilder
    private func preview(for tool: ReplayTool) -> some View {
        switch tool {
        case .counter:
            if let image = ExportOverlayRenderer.image(style: counterStyle, time: 1,
                counter: .init(count: 5, isTotal: false, age: 0.2)) {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Text("05").font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
            }
        case .timer:
            HStack(spacing: 7) {
                Circle().fill(SessionStyle.mint).frame(width: 5, height: 5)
                Text("00:12").font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 8).padding(.vertical, 9)
            .background(.black.opacity(0.24), in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75) }
        case .ball:
            BallSkinPreview(skin: .chrome)
        case .effects:
            Image("replay-tool-effects-v2").resizable().scaledToFit()
        case .graph:
            ReplayGraphPreview().padding(.horizontal, 2).padding(.vertical, 6)
        }
    }

    private var backgroundsPreview: some View {
        VStack(spacing: 6) {
            VStack(spacing: 4) {
                Image(systemName: "mountain.2.fill")
                    .font(.system(size: 23)).foregroundStyle(.white.opacity(0.3))
                Text("Coming soon").font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: .capsule)
            }.frame(height: 52)
            Text("Backgrounds").font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }.padding(.horizontal, 6).padding(.vertical, 10).frame(maxWidth: .infinity)
            .background(.white.opacity(0.025), in: .rect(cornerRadius: 17))
            .foregroundStyle(.white.opacity(0.5))
            .accessibilityElement(children: .ignore).accessibilityLabel("Backgrounds, coming soon")
    }
}

/// Uses the same graph drawing as the normal live and replay HUD.
private struct ReplayGraphPreview: View {
    private let points = (0...80).map { index in
        CaptureMotionPoint(time: Double(index) / 20, y: 0.8 - abs(sin(Double(index) / 20 * .pi * 2)) * 0.6)
    }

    var body: some View {
        CaptureMotionGraph(layout: CaptureGraphLayout(points: points, time: 2.45, duration: 4),
                           touchTimes: stride(from: 0.0, through: 4, by: 0.5).map { $0 })
    }
}

/// Visible selection handles share the export transform; the video and output stay aligned.
struct CounterSelectionFrame: View {
    @Binding var placement: ExportOverlayPlacement
    let size: CGSize
    let onRemove: () -> Void
    @State private var initialScale: Double?

    var body: some View {
        let rect = placement.rect(in: size)
        ZStack {
            Rectangle().strokeBorder(.white.opacity(0.9), lineWidth: 1).allowsHitTesting(false)
            ForEach(0..<4) { index in
                Circle().fill(.white).frame(width: 7, height: 7)
                    .position(x: index % 2 == 0 ? 0 : rect.width, y: index < 2 ? 0 : rect.height)
                    .allowsHitTesting(false)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black).frame(width: 25, height: 25).background(.white, in: .circle)
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).position(x: 0, y: 0)
                .accessibilityLabel("Remove counter").accessibilityIdentifier("replay-remove-counter")
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                .frame(width: 25, height: 25).background(.white, in: .circle)
                .frame(width: 44, height: 44).contentShape(.circle)
                .gesture(DragGesture().onChanged { value in
                    if initialScale == nil { initialScale = placement.scale }
                    let delta = Double(value.translation.width + value.translation.height) / 240
                    placement = placement.transformed(scale: (initialScale ?? placement.scale) + delta, in: size)
                }.onEnded { _ in initialScale = nil })
                .position(x: rect.width, y: rect.height)
                .accessibilityLabel("Resize counter").accessibilityAddTraits(.allowsDirectInteraction)
        }
        .frame(width: rect.width, height: rect.height)
        .rotationEffect(.radians(placement.radians))
        .position(x: rect.midX, y: rect.midY)
    }
}
