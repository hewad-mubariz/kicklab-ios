import SwiftUI

/// Where the analytics go in the saved video. The replay always shows them; this is the one choice
/// for the saved clip: none, the see-through card, or full width like the replay's own readout.
enum AnalyticsPlacement: CaseIterable {
    case off, card, full

    init(included: Bool, background: Bool) { self = !included ? .off : background ? .card : .full }

    var title: String {
        switch self {
        case .off: String(localized: "Off", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .card: String(localized: "Card", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        case .full: String(localized: "Full width", bundle: AppLanguage.bundle, locale: AppLanguage.locale)
        }
    }
}

struct ReplayMotionPicker: View {
    @Binding var style: MotionStyle
    @Binding var includeGraph: Bool
    @Binding var analyticsBackground: Bool
    let snapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    var showsProBadges = false
    /// Test build: the analytics lab views, listed in the same scroll under the graph styles.
    var labSelection: Binding<LabViewID?>? = nil
    var labStatus: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placement: AnalyticsPlacement { AnalyticsPlacement(included: includeGraph, background: analyticsBackground) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Short, so the video keeps its room above the panel while choosing.
            Text("In your saved video").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                ForEach(AnalyticsPlacement.allCases, id: \.self) { option in
                    Button {
                        includeGraph = option != .off
                        if option != .off { analyticsBackground = option == .card }
                    } label: {
                        AnalyticsPlacementOption(placement: option, style: style, selected: placement == option)
                    }
                    .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.97))
                    .accessibilityLabel(option.title)
                    .accessibilityAddTraits(placement == option ? .isSelected : [])
                    .accessibilityIdentifier("analytics-placement-\(option)")
                }
            }
            .padding(.horizontal, 16)
            .sensoryFeedback(.selection, trigger: placement)

            // The chosen graph's tile draws this clip live; play runs the clip under it.
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(labSelection == nil ? LocalizedStringKey("Graph styles") : LocalizedStringKey("Analytics")).font(.system(size: 12, weight: .semibold))
                    Text("In this clip · \(ExportPreviewTime.label(at: snapshot.graph.time))")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                        .accessibilityIdentifier("motion-preview-time")
                }
                Spacer()
                Button(action: onTogglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                        .contentTransition(.symbolEffect(.replace))
                }
                .appGlassButtonStyle().buttonBorderShape(.circle)
                .accessibilityLabel(isPlaying ? "Pause motion preview" : "Play motion preview")
                .accessibilityIdentifier("motion-preview-play")
            }
            .padding(.horizontal, 16)

            // Two to a row, scrolling down; the next row peeks under a fade so there is more below.
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                  VStack(alignment: .leading, spacing: 10) {
                    if labSelection != nil { sectionTitle("Graph styles") }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(MotionStyle.allCases) { option in
                            Button {
                                style = option
                            } label: {
                                MotionStyleOption(style: option, selected: style == option, width: nil,
                                                  live: style == option ? snapshot : nil, sourceAspect: sourceAspect)
                                    .overlay(alignment: .topTrailing) {
                                        if showsProBadges { ProBadge().padding(8) }
                                    }
                            }
                            .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.97))
                            .accessibilityLabel(option.title + (option == .ballMotion ? ", " + String(localized: "Default", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : ""))
                            .accessibilityHint(option.caption)
                            .accessibilityAddTraits(style == option ? .isSelected : [])
                            .accessibilityIdentifier("motion-style-\(option.rawValue)")
                            .id(option)
                        }
                    }
                    if let labSelection { labSection(labSelection) }
                  }
                  .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 22)
                }
                .frame(height: 300)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                           .init(color: .black.opacity(0), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .accessibilityIdentifier("motion-style-options")
                .onAppear { reader.scrollTo(style, anchor: .center) }
                // A tile picked at the fade's edge slides fully into view.
                .onChange(of: style) { _, picked in
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { reader.scrollTo(picked) }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: style)
    }

    private func sectionTitle(_ title: LocalizedStringKey, status: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.4)
                .foregroundStyle(.white.opacity(0.7)).textCase(.uppercase)
            Spacer(minLength: 6)
            if let status {
                Text(status).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(SessionStyle.mint).lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .padding(.top, 4)
    }

    /// The lab views as tiles, two to a row; tapping the one that is on turns it off again.
    private func labSection(_ selection: Binding<LabViewID?>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("New analytics (test)", status: labStatus)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach(LabViewID.allCases) { view in
                    let on = selection.wrappedValue == view
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selection.wrappedValue = on ? nil : view }
                    } label: {
                        LabViewTile(view: view, selected: on)
                    }
                    .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.96))
                    .accessibilityLabel(view.title)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("lab-view-\(view.rawValue)")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }
}

/// One lab view in the Analytics grid: its symbol, name and family.
struct LabViewTile: View {
    let view: LabViewID
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: view.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? SessionStyle.background : SessionStyle.mint)
                .frame(width: 32, height: 32)
                .background(selected ? SessionStyle.mint : SessionStyle.mint.opacity(0.12), in: .circle)
                .symbolEffect(.bounce, value: selected)
            VStack(alignment: .leading, spacing: 2) {
                Text(view.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(view.group.uppercased()).font(.system(size: 7, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 14))
    }
}

/// A small frame of footage showing where the analytics sit in the saved video, drawn with the chosen style.
struct AnalyticsPlacementOption: View {
    let placement: AnalyticsPlacement
    let style: MotionStyle
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            footage
                .frame(height: 34)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(placement.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(.black, SessionStyle.mint)
                }
            }
        }
        .padding(8).frame(maxWidth: .infinity)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 14))
    }

    private var footage: some View {
        // Sky over grass, so the see-through card reads as see-through.
        LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.38), Color(red: 0.13, green: 0.36, blue: 0.2)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .bottom) {
                switch placement {
                case .off:
                    Image(systemName: "eye.slash").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxHeight: .infinity)
                case .card:
                    graph.padding(3)
                        .background(.black.opacity(0.35), in: .rect(cornerRadius: 4))
                        .padding(4)
                case .full:
                    graph.padding(.horizontal, 3).padding(.top, 8).padding(.bottom, 3)
                        .background(LinearGradient(colors: [.clear, .black.opacity(ExportMotionGraphRenderer.shadeAlpha)],
                                                   startPoint: .top, endPoint: .bottom))
                }
            }
    }

    private var graph: some View {
        MotionStyleGraph(style: style, snapshot: MotionStyleSample.preview(for: style)).frame(height: 14)
    }
}

struct MotionStyleOption: View {
    let style: MotionStyle
    var selected = false
    /// A fixed width for a sideways row; nil fills its grid column.
    var width: CGFloat? = 146
    /// The clip's own data, drawn live in this style; without it the tile shows sample motion.
    var live: MotionStyleSnapshot? = nil
    var sourceAspect: CGFloat = 9.0 / 16.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let live {
                    MotionStyleGraph(style: style, snapshot: live, sourceAspect: sourceAspect)
                } else {
                    MotionStyleGraph(style: style, snapshot: MotionStyleSample.preview(for: style))
                }
            }
            .frame(height: 66).accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(style.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.black, SessionStyle.mint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            caption
        }
        .padding(12)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 16))
        .animation(.snappy(duration: 0.25), value: selected)
    }

    /// The live tile reads out the clip where the style has something to say; others name what they measure.
    @ViewBuilder private var caption: some View {
        if let live, let status = style.status(live.graph) {
            Text(status).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(SessionStyle.mint)
                .contentTransition(.numericText())
        } else {
            Text(style == .ballMotion ? String(localized: "DEFAULT", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : style.measure)
                .font(.system(size: 7, weight: .medium)).tracking(0.6).lineLimit(1)
                .foregroundStyle(style == .ballMotion ? SessionStyle.mint : .white.opacity(0.45))
        }
    }
}
