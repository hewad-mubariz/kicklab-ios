import SwiftUI

struct LearnLessonView: View {
    @State var lesson: LearnLesson
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var coach = LearningCoach()
    @State private var playing = true
    @State private var slow = false
    @State private var sideView = false
    @State private var saved = false
    @AppStorage("juggledude.learn.practised.v1") private var practised = ""
    @AppStorage("juggledude.learn.voice.v1") private var voice = true
    private var ink: Color { TrainingHomeStyle.ink(scheme) }
    private var muted: Color { TrainingHomeStyle.muted(scheme) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    title.id("lesson-top")
                    demonstration
                    coachCaption
                    if coach.mode == .reflection { reflection.id("lesson-check-in") } else { instruction }
                }.frame(maxWidth: 560).padding(20).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("learn-lesson-screen")
            .onChange(of: coach.mode) { _, mode in
                withAnimation(.easeInOut(duration: 0.25)) {
                    reader.scrollTo(mode == .reflection ? "lesson-check-in" : "lesson-top", anchor: .top)
                }
            }
            .onChange(of: lesson.id) { _, _ in reader.scrollTo("lesson-top", anchor: .top) }
        }
        .background(TrainingHomeStyle.homeBackground(scheme)).foregroundStyle(ink)
        .safeAreaInset(edge: .top, spacing: 0) {
            toolbar.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
                .background(TrainingHomeStyle.homeBackground(scheme))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomAction }
        .onAppear { coach.voiceEnabled = voice }
        .onDisappear { coach.pause(); playing = false }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { coach.pause(); playing = false }
        }
    }

    private var toolbar: some View {
        HStack {
            Button { coach.pause(); dismiss() } label: {
                Image(systemName: "arrow.left").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                    .background(TrainingHomeStyle.panel(scheme), in: .circle)
                    .overlay(Circle().strokeBorder(TrainingHomeStyle.line(scheme)))
            }.accessibilityLabel("Back to lessons").accessibilityIdentifier("learn-close")
            Spacer()
            Text("LET'S LEARN TOGETHER").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.4).foregroundStyle(muted)
            Spacer()
            Button { voice.toggle(); coach.voiceEnabled = voice } label: {
                Image(systemName: voice ? "speaker.wave.2" : "speaker.slash").font(.system(size: 17)).frame(width: 44, height: 44)
                    .background(voice ? TrainingHomeStyle.lime : TrainingHomeStyle.panel(scheme), in: .circle)
                    .foregroundStyle(voice ? TrainingHomeStyle.buttonInk : ink)
            }.accessibilityLabel(voice ? "Mute coach" : "Enable coach voice").accessibilityIdentifier("learn-voice")
        }.buttonStyle(.plain)
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(lesson.level.number) / \(lesson.level.title.uppercased())")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.3)
                    .foregroundStyle(TrainingHomeStyle.accent(scheme))
                Spacer()
                Text(coach.mode == .practice ? (coach.round == 0 ? "Get ready" : "Try \(coach.round) of 3") : "YOUR OWN PACE")
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(muted)
                    .accessibilityIdentifier("learn-round")
            }
            Text(lesson.title).font(TrainingHomeStyle.display(39, relativeTo: .largeTitle)).accessibilityIdentifier("learn-lesson-title")
            Text(lesson.summary).font(.subheadline).foregroundStyle(muted)
        }
    }
    private var demonstration: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                RadialGradient(colors: [Color(red: 0.16, green: 0.26, blue: 0.20), Color(red: 0.04, green: 0.09, blue: 0.075)],
                               center: .center, startRadius: 10, endRadius: 280)
                JugglingCoachStage(motion: lesson.motion, playing: playing, slow: slow, sideView: sideView, speaking: coach.speaking)
                HStack(spacing: 6) {
                    Circle().fill(TrainingHomeStyle.lime).frame(width: 5, height: 5)
                    Text(coach.mode == .practice ? "TRY WITH ME" : "WATCH THE MOVEMENT")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                }.foregroundStyle(.white.opacity(0.8)).padding(17)
            }.frame(height: 300)
            HStack(spacing: 0) {
                control(playing ? "Pause" : "Play", icon: playing ? "pause.fill" : "play.fill", identifier: "learn-play") {
                    playing.toggle(); if !playing { coach.pause() }
                }
                Spacer()
                control(slow ? "0.5×" : "1×", icon: "speedometer", identifier: "learn-speed") { slow.toggle() }
                Spacer()
                control(sideView ? "Side" : "Front", icon: "rotate.3d", identifier: "learn-angle") { sideView.toggle() }
            }.padding(.horizontal, 15).padding(.vertical, 5).background(Color(red: 0.10, green: 0.15, blue: 0.12))
        }.clipShape(.rect(cornerRadius: 22))
    }
    private func control(_ text: String, icon: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9)).frame(minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
    private var coachCaption: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: coach.speaking ? "waveform" : "quote.bubble").font(.system(size: 19))
                .foregroundStyle(TrainingHomeStyle.accent(scheme)).frame(width: 38, height: 38)
                .background(TrainingHomeStyle.lime.opacity(scheme == .dark ? 0.12 : 0.28), in: .circle)
            VStack(alignment: .leading, spacing: 5) {
                Text("COACH").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.5).foregroundStyle(muted)
                Text(coach.caption).font(.system(size: 16, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("learn-caption")
                if coach.voiceUnavailable {
                    Text("Voice isn't available on this device. Follow the captions.").font(.caption).foregroundStyle(muted)
                }
            }
            Spacer(minLength: 0)
            if coach.mode != .practice {
                Button {
                    coach.voiceEnabled = true; voice = true; coach.introduce(lesson)
                } label: {
                    Image(systemName: "play.circle").font(.system(size: 25)).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Hear the coach").accessibilityIdentifier("learn-hear-coach")
            }
        }.padding(.vertical, 3)
    }
    private var instruction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text(coach.mode == .practice ? "Your little goal" : "Three little steps").font(.system(size: 19, weight: .bold))
            if coach.mode == .practice {
                Text(lesson.target).font(.body)
                Text("Practise at your pace. Tap Done when you're ready to check in.").font(.subheadline).foregroundStyle(muted)
            } else {
                ForEach(Array(lesson.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 25, height: 25)
                            .background(TrainingHomeStyle.lime.opacity(scheme == .dark ? 0.12 : 0.32), in: .circle)
                        Text(step).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                    }
                }
                Label(lesson.target, systemImage: "scope").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TrainingHomeStyle.accent(scheme)).padding(.top, 3)
            }
        }
    }
    private var reflection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text(saved ? "A little practice, banked." : "How did that feel?").font(.system(size: 22, weight: .bold))
            Text(saved ? "Your practice check-in is saved on this device." : "Your check-in helps you choose the next step.")
                .font(.subheadline).foregroundStyle(muted)
            if !saved {
                Button {
                    var ids = Set(practised.split(separator: ",").map(String.init))
                    ids.insert(lesson.id); practised = ids.sorted().joined(separator: ","); saved = true
                    coach.say("Practice saved. Keep building at your own pace.")
                } label: {
                    Label("Feeling good · save practice", systemImage: "checkmark.circle")
                        .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        .background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 14)).foregroundStyle(TrainingHomeStyle.buttonInk)
                }.buttonStyle(.plain).accessibilityIdentifier("learn-save-practice")
            }
            if lesson.easierID != lesson.id {
                Button {
                    coach.reset(); saved = false; playing = true
                    lesson = .lesson(lesson.easierID)
                    coach.say("Let's take a smaller step. \(lesson.cue)")
                } label: {
                    HStack {
                        Text("Make it a little easier")
                        Spacer()
                        Image(systemName: "arrow.down.right")
                    }.font(.system(size: 15, weight: .medium)).padding(16).contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(TrainingHomeStyle.line(scheme)))
                }.buttonStyle(.plain).accessibilityIdentifier("learn-easier")
            }
        }
    }
    private var bottomAction: some View {
        VStack(spacing: 9) {
            Button {
                saved = false
                if coach.mode == .practice { coach.finish() }
                else { playing = true; coach.start(lesson) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: coach.mode == .practice ? "checkmark" : "play.fill").font(.system(size: 14, weight: .bold))
                    Text(coach.mode == .practice ? "Done for now" : (coach.mode == .reflection ? "Let's try again" : "Let's try together"))
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    if coach.mode != .practice { Text("~40 SEC").font(.system(size: 10, weight: .bold, design: .monospaced)).opacity(0.65) }
                }.padding(.horizontal, 20).frame(minHeight: 56)
                    .foregroundStyle(TrainingHomeStyle.buttonInk).background(TrainingHomeStyle.lime, in: .rect(cornerRadius: 18))
            }.buttonStyle(.plain).accessibilityIdentifier("learn-practice")
            Text(coach.mode == .practice ? "Guided practice · camera is off" : "Listen to your coach, or follow the captions")
                .font(.system(size: 11)).foregroundStyle(muted)
        }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: 600).frame(maxWidth: .infinity).background(TrainingHomeStyle.homeBackground(scheme))
    }
}
