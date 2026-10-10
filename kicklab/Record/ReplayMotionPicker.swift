import SwiftUI

struct ReplayMotionPicker: View {
    @Binding var style: MotionStyle
    @Binding var showGraph: Bool
    @Binding var includeGraph: Bool
    let snapshot: MotionStyleSnapshot
    let sourceAspect: CGFloat
    let isPlaying: Bool
    let onTogglePlayback: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Show ball motion").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Show ball motion", isOn: Binding(get: { showGraph }, set: { visible in
                    showGraph = visible
                    if !visible { includeGraph = false }
                })).labelsHidden().fixedSize()
                    .tint(SessionStyle.mint).accessibilityLabel("Show ball motion")
            }.padding(.horizontal, 16)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include graph in saved video").font(.system(size: 12, weight: .semibold))
                    Text("Save and share this style with your clip.")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Toggle("Include graph in saved video", isOn: Binding(get: { includeGraph }, set: { included in
                    includeGraph = included
                    if included { showGraph = true }
                }))
                    .labelsHidden().fixedSize().tint(SessionStyle.mint)
                    .accessibilityIdentifier("motion-include-export")
            }
            .padding(.horizontal, 16)

            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1)
                        Text("In this clip · \(ExportPreviewTime.label(at: snapshot.graph.time))")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
                            .accessibilityIdentifier("motion-preview-time")
                    }
                    Spacer()
                    Text(snapshot.graph.status).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(SessionStyle.mint)
                    Button(action: onTogglePlayback) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel(isPlaying ? "Pause motion preview" : "Play motion preview")
                    .accessibilityIdentifier("motion-preview-play")
                }
                MotionStyleGraph(style: style, snapshot: snapshot, sourceAspect: sourceAspect)
                    .frame(height: 100)
                    .opacity(showGraph ? 1 : 0.3)
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
                                style = option; showGraph = true
                            } label: {
                                MotionStyleOption(style: option, selected: style == option)
                            }
                            .buttonStyle(SessionPressStyle(scale: reduceMotion ? 1 : 0.97))
                            .accessibilityLabel(option.title + (option == .ballMotion ? ", Default" : ""))
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
            Text(style == .ballMotion ? "DEFAULT" : style.measure)
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
