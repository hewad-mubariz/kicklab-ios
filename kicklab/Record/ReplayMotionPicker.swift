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

            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                        Text("In this clip · \(ExportPreviewTime.label(at: snapshot.graph.time))")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                            .accessibilityIdentifier("motion-preview-time")
                    }
                    Spacer()
                    if let status = style.status(snapshot.graph) {
                        Text(status).font(.system(size: 9, weight: .medium))
                            .foregroundStyle(SessionStyle.mint)
                    }
                    Button(action: onTogglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .appGlassButtonStyle().buttonBorderShape(.circle)
                    .accessibilityLabel(isPlaying ? "Pause motion preview" : "Play motion preview")
                    .accessibilityIdentifier("motion-preview-play")
                }
                MotionStyleGraph(style: style, snapshot: snapshot, sourceAspect: sourceAspect)
                    .frame(height: 100)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Motion preview")
                    .accessibilityValue(style.rawValue)
                    .accessibilityIdentifier("motion-selected-preview")
            }
            .padding(14)
            .background(Color(red: 0.045, green: 0.065, blue: 0.067), in: .rect(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
            .padding(.horizontal, 16)

            HStack {
                Text("Motion styles").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(MotionStyle.allCases.count) styles · Swipe to explore").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }.padding(.horizontal, 16)

            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(MotionStyle.allCases) { option in
                            Button {
                                style = option
                            } label: {
                                MotionStyleOption(style: option, selected: style == option)
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
                    }.padding(.horizontal, 16).padding(.vertical, 2)
                }
                .accessibilityIdentifier("motion-style-options")
                .onAppear { reader.scrollTo(style, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: style)
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
    var width: CGFloat = 146

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MotionStyleGraph(style: style, snapshot: MotionStyleSample.preview(for: style))
                .frame(height: 66).accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(style.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                        .foregroundStyle(.black, SessionStyle.mint)
                }
            }
            Text(style == .ballMotion ? String(localized: "DEFAULT", bundle: AppLanguage.bundle, locale: AppLanguage.locale) : style.measure)
                .font(.system(size: 7, weight: .medium)).tracking(0.6)
                .foregroundStyle(style == .ballMotion ? SessionStyle.mint : .white.opacity(0.45))
        }
        .padding(12).frame(width: width)
        .background(Color(red: 0.05, green: 0.075, blue: 0.077), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.14), lineWidth: selected ? 1.3 : 0.5)
        }
        .foregroundStyle(.white).contentShape(.rect(cornerRadius: 16))
    }
}
