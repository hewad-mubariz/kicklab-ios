import SwiftUI
import simd

/// Small ball renders for the touch strip, drawn once per print off the main actor.
actor BallThumbnailStore {
    static let shared = BallThumbnailStore()
    private var images: [BallSkin: CGImage] = [:]
    private let pose = simd_quatf(angle: 1.89, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: 0.59, axis: SIMD3(1, 0, 0))

    func image(for skin: BallSkin) -> CGImage? {
        guard skin != .original else { return nil }
        if let hit = images[skin] { return hit }
        let rendered = BallSkinSphereRenderer.previewImage(skin: skin, time: 0, orientation: pose)
        if let rendered { images[skin] = rendered }
        return rendered
    }
}

/// A ball at thumbnail size; the original ball is the plain symbol.
struct BallThumbnail: View {
    let skin: BallSkin
    var size: CGFloat = 30
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if skin == .original {
                Image(systemName: "soccerball").font(.system(size: size * 0.72)).foregroundStyle(.white.opacity(0.8))
            } else if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit().transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .task(id: skin) {
            let requested = skin
            let rendered = await BallThumbnailStore.shared.image(for: requested)
            guard !Task.isCancelled else { return }
            withAnimation(SessionMotion.fade) { image = rendered }
        }
        .accessibilityHidden(true)
    }
}

/// Every counted touch in a row. Tap one to pick its ball; the clip holds that moment.
/// A dot marks where the ball changes; the ring slides to the chosen touch.
struct BallTouchStrip: View {
    let touchTimes: [Double]
    let edit: SessionEditState
    @Binding var selected: Int
    let onSelect: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ring

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(touchTimes.indices, id: \.self) { index in chip(index) }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, index in
                withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(height: 66)
        .sensoryFeedback(.selection, trigger: selected)
    }

    private func chip(_ index: Int) -> some View {
        let skin = edit.ballSkin(forTouch: index)
        let isSelected = index == selected
        let changes = edit.ballChanges[index] != nil
        return Button { onSelect(index) } label: {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(.white.opacity(isSelected ? 0.14 : 0.06))
                    BallThumbnail(skin: skin, size: 28)
                    if isSelected {
                        Circle().strokeBorder(SessionStyle.mint, lineWidth: 1.6)
                            .shadow(color: SessionStyle.mint.opacity(0.55), radius: 6)
                            .matchedGeometryEffect(id: "touch-ring", in: ring)
                    }
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .topTrailing) {
                    if changes {
                        Circle().fill(SessionStyle.mint).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1))
                            .offset(x: 1, y: -1)
                            .transition(.sessionPop(scale: 0.2))
                    }
                }
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium)).monospacedDigit()
                    .foregroundStyle(isSelected ? SessionStyle.mint : .white.opacity(0.7))
            }
            .scaleEffect(isSelected && !reduceMotion ? 1.08 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: isSelected)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: changes)
        .id(index)
        .accessibilityLabel("Touch \(index + 1), \(skin == .original ? "original ball" : skin.title)")
        .accessibilityIdentifier("ball-touch-\(index + 1)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One row of picks with a symbol and a name. The chosen chip lights mint; a pick kicks it.
struct ReplayChipRow<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let selection: Item
    let title: (Item) -> String
    let symbol: (Item) -> String
    let identifier: (Item) -> String
    let accessibilityLabel: (Item) -> String
    let onPick: (Item) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kicks: [Item: Int] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 7) {
                    ForEach(items) { item in chip(item) }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
        .frame(height: 66)
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ item: Item) -> some View {
        let selected = item == selection
        return Button {
            kicks[item, default: 0] += 1
            onPick(item)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol(item))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(selected ? SessionStyle.mint.opacity(0.14) : .white.opacity(0.06), in: .circle)
                    .overlay { Circle().strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5) }
                    .symbolEffect(.bounce, value: kicks[item, default: 0])
                    .sessionKick(kicks[item, default: 0], amount: 0.12)
                Text(title(item))
                    .font(.system(size: 9.5, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 58)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: selected)
        .id(item)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityIdentifier(identifier(item))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Sounds for touches and ball changes. Each pick plays once so it can be judged on the spot.
struct ReplaySoundPage: View {
    @Binding var edit: SessionEditState
    let onPreview: (ReplaySound) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("Touch sound", symbol: "hand.tap.fill")
            ReplayChipRow(items: TouchSound.allCases, selection: edit.touchSound, title: \.title, symbol: \.symbol,
                          identifier: { "touch-sound-\($0.rawValue)" },
                          accessibilityLabel: { $0 == .none ? "No touch sound" : "\($0.title) touch sound" }) { sound in
                withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.touchSound = sound }
                onPreview(.touch(sound))
            }
            label("Ball change sound", symbol: "arrow.triangle.2.circlepath")
            ReplayChipRow(items: BallSwapSound.allCases, selection: edit.swapSound, title: \.title, symbol: \.symbol,
                          identifier: { "swap-sound-\($0.rawValue)" },
                          accessibilityLabel: { $0 == .none ? "No ball change sound" : "\($0.title) ball change sound" }) { sound in
                withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.swapSound = sound }
                onPreview(.swap(sound))
            }
            if !edit.hasBallChanges {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(SessionStyle.mint)
                    Text("Pick a ball per touch in Ball to hear the change sound.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .transition(.sessionRise)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("sound-change-note")
            }
        }
        .padding(.top, 2)
    }

    private func label(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(SessionStyle.mint)
            Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 16)
        .accessibilityAddTraits(.isHeader)
    }
}
