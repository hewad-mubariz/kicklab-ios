import SwiftUI

struct LearnHubView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var level: LearnLevel = .basics
    @State private var selected: LearnLesson?
    @State private var visible = false
    /// The coach only moves while its card is on screen, so it isn't running unseen far down the page.
    @State private var heroOnScreen = true
    @AppStorage("juggledude.learn.practised.v1") private var practised = ""
    private var ink: Color { TrainingHomeStyle.ink(scheme) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    hero
                    curriculum
                    help
                    HStack(spacing: 7) {
                        Image(systemName: "headphones")
                        Text("A little guidance. Your own pace.")
                    }
                    .font(.footnote).foregroundStyle(TrainingHomeStyle.muted(scheme))
                    .frame(maxWidth: .infinity).padding(.bottom, 10)
                }
                .frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
            }
            .background(TrainingHomeStyle.homeBackground(scheme)).foregroundStyle(ink)
            .toolbar(.hidden, for: .navigationBar)
            .accessibilityIdentifier("learn-screen")
            .fullScreenCover(item: $selected) { lesson in LearnLessonView(lesson: lesson) }
            .onAppear { visible = true }.onDisappear { visible = false }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Learn").font(TrainingHomeStyle.display(44, relativeTo: .largeTitle)).accessibilityAddTraits(.isHeader)
                Text("Small steps. Better control.").font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            Spacer()
            Image(systemName: "waveform").font(.system(size: 19, weight: .medium))
                .frame(width: 46, height: 46).background(TrainingHomeStyle.lime, in: .circle)
                .foregroundStyle(TrainingHomeStyle.buttonInk).accessibilityLabel("Lessons include spoken coaching")
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Color(red: 0.15, green: 0.25, blue: 0.19), Color(red: 0.04, green: 0.09, blue: 0.075)],
                               center: .center, startRadius: 15, endRadius: 260)
                JugglingCoachStage(motion: .touchCatch, playing: visible && heroOnScreen && selected == nil, showsPhase: false)
                    .padding(.leading, 38).padding(.top, 20)
                    .onScrollVisibilityChange(threshold: 0.05) { heroOnScreen = $0 }
                VStack(alignment: .leading, spacing: 7) {
                    Text("YOUR PRACTICE PARTNER").font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.8).foregroundStyle(TrainingHomeStyle.lime)
                    Text("Let's try\ntogether.").font(TrainingHomeStyle.display(34, relativeTo: .title))
                        .lineSpacing(-2).foregroundStyle(.white)
                }.padding(20)
            }.frame(height: 280)
            Button { selected = .lesson("touch-catch") } label: {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42).background(TrainingHomeStyle.lime, in: .circle)
                        .foregroundStyle(TrainingHomeStyle.buttonInk)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("START WITH ONE TOUCH").font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(1.3).foregroundStyle(TrainingHomeStyle.lime)
                        Text("One touch. One catch.").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 18)).foregroundStyle(.white)
                }.padding(18)
            }.buttonStyle(.plain).accessibilityIdentifier("learn-start")
                .background(Color(red: 0.10, green: 0.15, blue: 0.12))
        }.clipShape(.rect(cornerRadius: 24))
    }

    private var curriculum: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Find your next step").font(.system(size: 21, weight: .bold))
                Spacer()
                Text("12 drills").font(.caption).foregroundStyle(TrainingHomeStyle.muted(scheme))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(LearnLevel.allCases) { item in
                        Button { level = item } label: {
                            HStack(spacing: 6) {
                                Text(item.number).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                Text(item.title).font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(level == item ? TrainingHomeStyle.lime : TrainingHomeStyle.panel(scheme), in: .capsule)
                            .overlay(Capsule().strokeBorder(level == item ? .clear : TrainingHomeStyle.line(scheme), lineWidth: 1))
                            .foregroundStyle(level == item ? TrainingHomeStyle.buttonInk : ink)
                        }.buttonStyle(.plain).accessibilityAddTraits(level == item ? .isSelected : [])
                            .accessibilityIdentifier("learn-level-\(item.id)")
                    }
                }
            }
            Text(level.subtitle).font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
            VStack(spacing: 0) {
                ForEach(Array(LearnLesson.all.filter { $0.level == level }.enumerated()), id: \.element.id) { index, lesson in
                    if index > 0 { Divider().padding(.leading, 52) }
                    Button { selected = lesson } label: {
                        HStack(alignment: .center, spacing: 14) {
                            Text(String(format: "%02d", index + 1)).font(TrainingHomeStyle.display(26, relativeTo: .title2))
                                .foregroundStyle(TrainingHomeStyle.muted(scheme)).frame(width: 28)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(lesson.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink)
                                Text(lesson.summary).font(.system(size: 13)).foregroundStyle(TrainingHomeStyle.muted(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: practised.split(separator: ",").contains(Substring(lesson.id)) ? "checkmark.circle.fill" : "arrow.up.right")
                                .font(.system(size: 15)).foregroundStyle(TrainingHomeStyle.accent(scheme))
                        }.padding(.vertical, 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("learn-lesson-\(lesson.id)")
                }
            }
        }
    }

    private var help: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                Text("Something feel tricky?").font(.system(size: 18, weight: .bold))
            }
            Text("There's a smaller step for that.").font(.subheadline).foregroundStyle(TrainingHomeStyle.muted(scheme))
            helpButton("The ball gets away from me", lesson: "keep-close")
            helpButton("My other foot needs practice", lesson: "other-foot-catch")
        }.padding(20)
            .background(scheme == .dark ? Color.white.opacity(0.04) : Color(red: 0.96, green: 0.97, blue: 0.93), in: .rect(cornerRadius: 20))
    }
    private func helpButton(_ title: String, lesson: String) -> some View {
        Button { selected = .lesson(lesson) } label: {
            HStack {
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 13))
            }.contentShape(Rectangle()).padding(.vertical, 4)
        }.buttonStyle(.plain)
    }
}
