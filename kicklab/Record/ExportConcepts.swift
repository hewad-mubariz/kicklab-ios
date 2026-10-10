#if DEBUG
import AVFoundation
import SwiftUI

/// Three directions for what happens after tapping Download, for review only. Launch with
/// --session-design export-concept --concept A|B|C --export-state idle|saving|saved
/// and --session-video for the frame they show.
struct ExportConceptView: View {
    let concept: String
    let state: String
    @State private var frame: CGImage?

    var body: some View {
        Group {
            switch concept {
            case "B": ExportTrayConcept(state: state, frame: frame)
            case "C": SaveMomentConcept(state: state, frame: frame)
            default: InstantSaveConcept(state: state, frame: frame)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task {
            let url = SessionDesignReview.fileURL(SessionDesignReview.argument("--session-video") ?? "/tmp/kicklab-design-preview.mp4")
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 1600)
            frame = try? await generator.image(at: CMTime(seconds: 9, preferredTimescale: 600)).image
        }
    }
}

// MARK: - Shared pieces

private let exportLime = Color(red: 0.84, green: 1, blue: 0.42)

/// The edited replay: the session frame with its counter, as the export will look.
private struct ReplayCard: View {
    let frame: CGImage?
    var corner: CGFloat = 0
    /// Full-bleed under the editor chrome, the counter sits below the top bar.
    var counterTop: CGFloat? = nil

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { Color(white: 0.12) }
                LinearGradient(colors: [.black.opacity(0.35), .clear, .clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                if let badge = ExportOverlayRenderer.image(style: .normal, time: 9, counter: .init(count: 12, isTotal: false, age: 2), scale: 2) {
                    Image(decorative: badge, scale: 1).resizable().scaledToFit()
                        .frame(width: geometry.size.width * 0.36)
                        .padding(.leading, geometry.size.width * 0.05).padding(.top, counterTop ?? geometry.size.height * 0.06)
                }
            }
        }
        .clipShape(.rect(cornerRadius: corner))
    }
}

private struct ShareTarget: View {
    let title: String
    let symbol: String
    let fill: AnyShapeStyle

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(fill, in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.6) }
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ShareTargets: View {
    var body: some View {
        HStack(spacing: 0) {
            ShareTarget(title: "Stories", symbol: "camera.fill",
                        fill: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.98, green: 0.75, blue: 0.2), Color(red: 0.93, green: 0.2, blue: 0.45), Color(red: 0.55, green: 0.25, blue: 0.9)],
                                                           startPoint: .bottomLeading, endPoint: .topTrailing)))
            ShareTarget(title: "TikTok", symbol: "music.note", fill: AnyShapeStyle(Color(white: 0.07)))
            ShareTarget(title: "Messages", symbol: "message.fill", fill: AnyShapeStyle(Color(red: 0.2, green: 0.78, blue: 0.35)))
            ShareTarget(title: "More", symbol: "ellipsis", fill: AnyShapeStyle(Color.white.opacity(0.12)))
        }
    }
}

private struct RoundGlassButton: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 17, weight: .medium))
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: .circle)
    }
}

/// The replay editor's top bar and playback controls, so the concepts sit in context.
private struct EditorChrome<Trailing: View, Bottom: View>: View {
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RoundGlassButton(symbol: "chevron.left")
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(SessionStyle.mint).frame(width: 7, height: 7)
                    Text("SESSION 01").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 13).padding(.vertical, 10).glassEffect(.regular, in: .capsule)
                Spacer()
                trailing
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Spacer()
            bottom
        }
    }
}

private struct DownloadCircle: View {
    var body: some View {
        Image(systemName: "arrow.down.to.line").font(.system(size: 17, weight: .bold)).foregroundStyle(.black)
            .frame(width: 44, height: 44)
            .background(exportLime, in: .circle)
    }
}

private struct PlaybackRow: View {
    var body: some View {
        HStack {
            RoundGlassButton(symbol: "play.fill")
            Spacer()
            Label("Customize", systemImage: "wand.and.stars").font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 20).frame(height: 48).glassEffect(.regular, in: .capsule)
            Spacer()
            RoundGlassButton(symbol: "arrow.uturn.backward")
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
    }
}

// MARK: - A · Instant save

/// Download saves at once, right in the editor. The button turns into its own progress pill;
/// when the clip is in Photos a toast drops in and the share targets rise from the bottom.
private struct InstantSaveConcept: View {
    let state: String
    let frame: CGImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ReplayCard(frame: frame, counterTop: 150).ignoresSafeArea()
            EditorChrome {
                switch state {
                case "saving":
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                            Circle().trim(from: 0, to: 0.54).stroke(exportLime, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "arrow.down").font(.system(size: 11, weight: .heavy)).foregroundStyle(exportLime)
                        }
                        .frame(width: 28, height: 28)
                        Text("54%").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .padding(.leading, 8).padding(.trailing, 14).frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                case "saved":
                    Image(systemName: "checkmark").font(.system(size: 17, weight: .heavy)).foregroundStyle(.black)
                        .frame(width: 44, height: 44).background(SessionStyle.mint, in: .circle)
                default: DownloadCircle()
                }
            } bottom: {
                if state == "saved" { sharePanel } else { PlaybackRow() }
            }
            if state == "saved" {
                VStack {
                    HStack(spacing: 10) {
                        ReplayCard(frame: frame, corner: 6).frame(width: 30, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Saved to Photos").font(.system(size: 14, weight: .semibold))
                            Text("1080p · 0:18").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.black, SessionStyle.mint)
                    }
                    .padding(.leading, 8).padding(.trailing, 12).padding(.vertical, 8)
                    .frame(width: 280)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 66)
                    Spacer()
                }
            }
        }
    }

    private var sharePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share your replay").font(.system(size: 17, weight: .semibold))
            ShareTargets()
            HStack(spacing: 10) {
                Label("Record another", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 46)
                    .background(.white.opacity(0.1), in: .capsule)
                Text("Done").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 96, height: 46).background(SessionStyle.mint, in: .capsule)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
}

// MARK: - B · Export tray

/// Download morphs into a tray, like Customize: the video shrinks above it, a quality chip
/// and one Save button. Saving fills the button; then share targets take its place.
private struct ExportTrayConcept: View {
    let state: String
    let frame: CGImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                EditorChrome { DownloadCircle().opacity(0.35) } bottom: { EmptyView() }
                    .frame(height: 60)
                ReplayCard(frame: frame, corner: 18)
                    .aspectRatio(9 / 16, contentMode: .fit)
                    .padding(.top, 10).padding(.bottom, 14)
                tray
            }
        }
    }

    private var tray: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(state == "saved" ? "Saved to Photos" : "Download").font(.system(size: 17, weight: .semibold))
                if state == "saved" {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, SessionStyle.mint)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("1080p").font(.system(size: 12, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(.white.opacity(0.1), in: .capsule)
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 32, height: 32).background(.white.opacity(0.1), in: .circle)
            }
            switch state {
            case "saved":
                ShareTargets()
                HStack(spacing: 10) {
                    Label("Record another", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                        .background(.white.opacity(0.1), in: .rect(cornerRadius: 17))
                    Text("Done").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 100, height: 50).background(SessionStyle.mint, in: .rect(cornerRadius: 17))
                }
            case "saving":
                GeometryReader { geometry in
                    let filled = geometry.size.width * 0.54
                    let label = Text("Saving 54%").font(.system(size: 15, weight: .bold)).monospacedDigit()
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 17).fill(SessionStyle.mint.opacity(0.18))
                        label.foregroundStyle(.white).frame(maxWidth: .infinity)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 17).fill(SessionStyle.mint)
                            label.foregroundStyle(Color(red: 0.015, green: 0.12, blue: 0.08))
                                .frame(width: geometry.size.width)
                        }
                        .frame(width: filled, alignment: .leading)
                        .clipped()
                    }
                }
                .frame(height: 52)
                Text("Rendering your effects and counter…").font(.system(size: 12)).foregroundStyle(SessionStyle.secondary)
                    .frame(maxWidth: .infinity)
            default:
                HStack(spacing: 10) {
                    Label("Save to Photos", systemImage: "arrow.down.to.line").font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(red: 0.015, green: 0.12, blue: 0.08))
                        .frame(maxWidth: .infinity, minHeight: 52).background(SessionStyle.mint, in: .rect(cornerRadius: 17))
                    Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
                        .frame(width: 52, height: 52).background(.white.opacity(0.1), in: .rect(cornerRadius: 17))
                }
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 16).padding(.bottom, 10)
    }
}

// MARK: - C · Save moment

/// Download zooms the replay into a card and starts saving on arrival. The card's own border
/// fills as the progress ring; once it is in Photos the card bounces, a check lands on its
/// corner and the share targets and next steps appear below.
private struct SaveMomentConcept: View {
    let state: String
    let frame: CGImage?

    private var progress: Double { state == "saved" ? 1 : state == "saving" ? 0.54 : 0.08 }
    private var saved: Bool { state == "saved" }

    var body: some View {
        ZStack {
            SessionStyle.background.ignoresSafeArea()
            if let frame {
                Image(decorative: frame, scale: 1).resizable().scaledToFill().ignoresSafeArea()
                    .blur(radius: 40).opacity(0.35)
            }
            VStack(spacing: 0) {
                HStack {
                    RoundGlassButton(symbol: "chevron.left")
                    Spacer()
                    HStack(spacing: 4) {
                        Text("1080p").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).glassEffect(.regular, in: .capsule)
                }
                .padding(.horizontal, 20).padding(.top, 8)

                card.padding(.top, 14)

                VStack(spacing: 4) {
                    Text(saved ? "Saved to Photos" : "Saving your replay")
                        .font(.system(size: 24, weight: .bold))
                    Text(saved ? "Your juggle, effects and counter, ready to post." : "\(Int(progress * 100))% · Rendering effects and counter")
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(SessionStyle.secondary)
                }
                .padding(.top, 20)

                Spacer(minLength: 16)
                if saved {
                    ShareTargets().padding(.horizontal, 12)
                    HStack(spacing: 10) {
                        Label("Record another", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                            .background(.white.opacity(0.1), in: .rect(cornerRadius: 17))
                        Text("Done").font(.system(size: 15, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 104, height: 50).background(SessionStyle.mint, in: .rect(cornerRadius: 17))
                    }
                    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
                } else {
                    Text("Keep Juggle Dude open while it saves.")
                        .font(.system(size: 12)).foregroundStyle(SessionStyle.secondary.opacity(0.7))
                        .padding(.bottom, 20)
                }
            }
        }
    }

    private var card: some View {
        ZStack(alignment: .topTrailing) {
            ReplayCard(frame: frame, corner: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 22).fill(.black.opacity(saved ? 0 : 0.25))
                }
            // The card's border is the progress ring.
            RoundedRectangle(cornerRadius: 24)
                .stroke(.white.opacity(0.12), lineWidth: 4)
                .padding(-5)
            TopStartRoundedRect(radius: 24)
                .trim(from: 0, to: progress)
                .stroke(LinearGradient(colors: [SessionStyle.deepGreen, SessionStyle.mint], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(-5)
                .shadow(color: SessionStyle.mint.opacity(0.6), radius: 8)
            if saved {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .heavy)).foregroundStyle(SessionStyle.background)
                    .frame(width: 44, height: 44).background(SessionStyle.mint, in: .circle)
                    .shadow(color: SessionStyle.mint.opacity(0.7), radius: 10)
                    .offset(x: 14, y: -14)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxHeight: saved ? 360 : 420)
    }
}

/// A rounded rectangle whose outline starts at the top centre and runs clockwise,
/// so trimming it reads as a progress ring around the card.
private struct TopStartRoundedRect: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}
#endif
