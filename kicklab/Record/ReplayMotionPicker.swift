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
    /// Test build: the analytics lab views, in the same grid as the graph styles. Only one analytic is
    /// shown at a time: a lab view replaces the graph on the replay, and a graph style turns it off.
    var labSelection: Binding<LabViewID?>? = nil
    var labStatus: String? = nil
    /// Body tracking for the chosen lab view, 0…1, while it prepares.
    var labProgress: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var chosenLab: LabViewID? { labSelection?.wrappedValue }
    private var chosenID: String { chosenLab.map { "lab-" + $0.rawValue } ?? "style-" + style.rawValue }

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
            if chosenLab != nil {
                Label("New analytics show in the replay; the saved video uses the graph style.", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            // The chosen graph's tile draws this clip live; play runs the clip under it.
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosenLab?.title ?? style.title).font(.system(size: 12, weight: .semibold))
                        .contentTransition(.interpolate)
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

            // One category, two to a row, scrolling down; the next row peeks under a fade so there is more below.
            ScrollViewReader { reader in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(MotionStyle.allCases) { option in styleTile(option) }
                        if let labSelection {
                            ForEach(LabViewID.allCases) { view in labTile(view, labSelection) }
                        }
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
                .onAppear { reader.scrollTo(chosenID, anchor: .center) }
                // A tile picked at the fade's edge slides fully into view.
                .onChange(of: chosenID) { _, picked in
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { reader.scrollTo(picked) }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: chosenLab)
        .sensoryFeedback(.selection, trigger: chosenID)
    }

    private func styleTile(_ option: MotionStyle) -> some View {
        let on = chosenLab == nil && style == option
        return Button {
            labSelection?.wrappedValue = nil
            style = option
        } label: {
            MotionStyleOption(style: option, selected: on, width: nil, live: on ? snapshot : nil, sourceAspect: sourceAspect)
                .overlay(alignment: .topTrailing) {
                    if showsProBadges { ProBadge().padding(8) }
                }
        }
        .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.97))
        .accessibilityLabel(option.title + (option == .ballMotion ? ", " + String(localized: "Default", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : ""))
        .accessibilityHint(option.caption)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("motion-style-\(option.rawValue)")
        .id("style-" + option.rawValue)
    }

    private func labTile(_ view: LabViewID, _ selection: Binding<LabViewID?>) -> some View {
        let on = selection.wrappedValue == view
        return Button {
            selection.wrappedValue = view
        } label: {
            LabViewTile(view: view, selected: on, progress: on ? labProgress : nil, status: on ? labStatus : nil)
                .overlay(alignment: .topTrailing) {
                    if showsProBadges { ProBadge().padding(8) }
                }
        }
        .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.97))
        .accessibilityLabel(view.title)
        .accessibilityValue(on && labProgress != nil ? "Preparing" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("lab-view-\(view.rawValue)")
        .id("lab-" + view.rawValue)
    }
}

/// A lab view in the Analytics grid, laid out like the graph styles: a diagram of the view, its name, and
/// what it needs. While its body tracking runs, the tile shows the progress.
struct LabViewTile: View {
    let view: LabViewID
    var selected = false
    var progress: Double? = nil
    var status: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
                .frame(height: 66).frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 9))
                .overlay {
                    if let progress {
                        ZStack {
                            Color.black.opacity(0.45)
                            VStack(spacing: 5) {
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.2))
                                    Capsule().fill(SessionStyle.mint).frame(width: 72 * max(0.04, min(1, progress)))
                                }
                                .frame(width: 72, height: 4)
                                .animation(.easeOut(duration: 0.3), value: progress)
                                Text("Tracking \(Int(progress * 100))%").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                                    .contentTransition(.numericText(value: progress))
                            }
                        }
                        .clipShape(.rect(cornerRadius: 9))
                        .transition(.opacity)
                    }
                }
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(view.title).font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if selected && progress == nil {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.black, SessionStyle.mint)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            caption
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 16))
        .animation(.snappy(duration: 0.25), value: selected)
        .animation(.easeOut(duration: 0.2), value: progress == nil)
    }

    /// The view drawn as a diagram on the tile's colour (a grey figure, a plain ball and the view itself),
    /// like the graph styles; the symbol on a mint panel if a preview is missing.
    @ViewBuilder private var preview: some View {
        if let image = UIImage(named: "analytics-preview-" + view.rawValue) {
            // Fitted, never filled: the picture's own size must not widen the tile. Its background is the
            // tile's colour, so the edges disappear.
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .opacity(progress == nil ? 1 : 0.35)
        } else {
            symbolPanel
        }
    }

    private var symbolPanel: some View {
        ZStack {
            LinearGradient(colors: [SessionStyle.mint.opacity(selected ? 0.24 : 0.1), .white.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: view.symbol)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(SessionStyle.mint)
                .shadow(color: SessionStyle.mint.opacity(selected ? 0.6 : 0), radius: 8)
                .symbolEffect(.bounce, value: selected)
                // Steps back while the body tracking bar is shown over it.
                .opacity(progress == nil ? 1 : 0.12)
        }
    }

    /// What the view reads, or the chosen one's state; the body views say they track the body first.
    @ViewBuilder private var caption: some View {
        if let status, progress == nil, selected, status.hasPrefix("Feet") == false {
            Text(status).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 4) {
                if view.needsBody {
                    Image(systemName: "figure.walk").font(.system(size: 7, weight: .bold))
                }
                Text(view.needsBody ? "BODY TRACKING" : view.group.uppercased())
                    .font(.system(size: 7, weight: .medium)).tracking(0.6).lineLimit(1)
            }
            .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.45))
        }
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
