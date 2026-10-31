import SwiftUI

/// Runs of looks across the clip's touches. A recipe lays them out in one tap; the dial picks a
/// run, New look starts one at the lens and Remove look hands its touches back to the look
/// before; the pickers change a whole run at once, so nobody edits touches one by one.
struct LooksPage: View {
    @Binding var edit: SessionEditState
    let touchTimes: [Double]
    let currentTime: Double
    let onSeek: (Double) -> Void
    let onPreviewMoment: (Double) -> Void
    let onPreviewSound: (ReplaySound) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTouch: Int
    @State private var part: LookPart = .ball
    @State private var recipeKicks: [LookRecipe: Int] = [:]
    @State private var ballKicks: [BallSkin: Int] = [:]
    @State private var effectKicks: [BallStyle: Int] = [:]
    /// A ball pick lands on the clip after its flight, so redrawing never steals frames from it.
    @State private var pendingBall: BallSkin?
    @State private var pendingRun: Range<Int>?
    @State private var applyBall: Task<Void, Never>?
    @State private var cuts = 0
    /// Every's Custom… slider: open, the interval under the thumb, and the pending re-layout.
    @State private var showsStepSlider = false
    @State private var sliderStep = Double(LookRecipes.defaultStep)
    @State private var applyStep: Task<Void, Never>?

    enum LookPart: String, CaseIterable, Identifiable {
        case ball = "Ball", effect = "Effect", change = "Change"
        var id: String { rawValue }
    }

    private let skins: [BallSkin] = [.original, .metal, .lava, .pearl, .volt,
                                     .chrome, .arctic, .matrix, .stealth, .crimson,
                                     .gold, .galaxy, .graffiti, .aurora, .classic]

    init(edit: Binding<SessionEditState>, touchTimes: [Double], currentTime: Double,
         onSeek: @escaping (Double) -> Void, onPreviewMoment: @escaping (Double) -> Void,
         onPreviewSound: @escaping (ReplaySound) -> Void) {
        _edit = edit
        self.touchTimes = touchTimes; self.currentTime = currentTime
        self.onSeek = onSeek; self.onPreviewMoment = onPreviewMoment; self.onPreviewSound = onPreviewSound
        _selectedTouch = State(initialValue: Self.nearest(touchTimes, to: currentTime))
    }

    // MARK: Run under the lens

    private var run: Range<Int> { edit.run(containing: selectedTouch, touchCount: touchTimes.count) }
    private var runLook: TouchLook {
        var look = edit.look(forTouch: run.lowerBound)
        if let pendingBall, pendingRun == run { look.ball = pendingBall }
        return look
    }
    private var runStarts: [Int] { edit.runStarts.filter { $0 < touchTimes.count } }
    private var runNumber: Int { (runStarts.firstIndex(of: run.lowerBound) ?? 0) + 1 }
    private var canSplit: Bool { selectedTouch > run.lowerBound }
    /// The lens is on the touch where a look of its own begins, so that look can be removed.
    private var onLookStart: Bool { selectedTouch > 0 && selectedTouch == run.lowerBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            recipeRow
            if showsStepSlider && edit.recipe == .every && longestStep > 1 {
                stepSlider.transition(partSwap)
            }
            TouchDial(touchTimes: touchTimes, edit: edit, selected: $selectedTouch,
                      pending: pendingRun.flatMap { range in pendingBall.map { (range, $0) } }) { index in
                commitBall()
                onSeek(holdTime(forTouch: index))
            }
            runFooter
            partChips
            ZStack(alignment: .top) {
                switch part {
                case .ball: ballRow.transition(partSwap)
                case .effect: effectRow.transition(partSwap)
                case .change: changeArea.transition(partSwap)
                }
            }
        }
        .onAppear { onSeek(holdTime(forTouch: selectedTouch)) }
        .onDisappear { commitBall(); applyBall?.cancel(); applyStep?.cancel() }
        .sensoryFeedback(.impact(weight: .medium), trigger: cuts)
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.7), trigger: pendingBall)
        .sensoryFeedback(.selection, trigger: part)
        .sensoryFeedback(.selection, trigger: sliderValue)
    }

    private var partSwap: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .sessionRise.animation(SessionMotion.pop.delay(0.04)),
                                              removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    // MARK: Recipes

    private var recipeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LookRecipe.allCases) { item in recipeChip(item) }
                if edit.hasLookChanges {
                    Button {
                        commitBall()
                        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                            edit.lookChanges = [:]; edit.recipe = nil
                        }
                        cuts += 1
                    } label: {
                        Label("Clear", systemImage: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(.white.opacity(0.06), in: .capsule)
                    }
                    .buttonStyle(SessionPressStyle(scale: 0.92))
                    .accessibilityIdentifier("looks-clear")
                    .transition(.sessionPop(scale: 0.4))
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private func recipeChip(_ item: LookRecipe) -> some View {
        let on = edit.recipe == item && edit.hasLookChanges
        Group {
            if item == .every {
                // Every asks how often first, in a plain menu; Custom… takes any number.
                Menu {
                    Picker("Every", selection: everyStep) {
                        ForEach(stepChoices, id: \.self) { step in
                            Text(step == 1 ? "Every touch" : "Every \(step) touches").tag(Optional(step))
                        }
                    }
                    .pickerStyle(.inline)
                    if longestStep > 1 {
                        Button("Custom…", systemImage: "slider.horizontal.3") {
                            if edit.recipe != .every || !edit.hasLookChanges { applyEvery(shownStep) }
                            sliderStep = Double(shownStep)
                            withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                                showsStepSlider = true
                            }
                        }
                    }
                } label: {
                    recipeLabel(item, on: on, menu: true)
                }
                .menuStyle(.button)
            } else {
                Button { apply(item) } label: { recipeLabel(item, on: on, menu: false) }
            }
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: on)
        .accessibilityLabel(item.title(step: shownStep))
        .accessibilityHint(item.caption)
        .accessibilityIdentifier("look-recipe-\(item.rawValue)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func recipeLabel(_ item: LookRecipe, on: Bool, menu: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.symbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolEffect(.bounce, value: recipeKicks[item, default: 0])
            Text(item.title(step: shownStep)).font(.system(size: 12, weight: .semibold))
                .contentTransition(.numericText(value: Double(shownStep)))
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(on ? SessionStyle.background : .white)
        .padding(.horizontal, 12).frame(height: 34)
        .background(on ? AnyShapeStyle(SessionStyle.mint) : AnyShapeStyle(.white.opacity(0.08)), in: .capsule)
        .overlay { Capsule().strokeBorder(.white.opacity(on ? 0 : 0.1), lineWidth: 0.75) }
        .shadow(color: on ? SessionStyle.mint.opacity(0.45) : .clear, radius: 8)
    }

    /// The menu's tick: Every's interval while Every is laid out, else none, so any pick applies it.
    private var everyStep: Binding<Int?> {
        Binding(get: { edit.recipe == .every && edit.hasLookChanges ? shownStep : nil },
                set: { step in
                    guard let step else { return }
                    withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { showsStepSlider = false }
                    applyEvery(step)
                })
    }

    /// Custom…: any interval from every touch to the longest that repeats on this clip. The looks
    /// are laid again a moment after the thumb rests, so a drag never re-lays them on every step.
    private var stepSlider: some View {
        HStack(spacing: 10) {
            Text(sliderValue == 1 ? "Every touch" : "Every \(sliderValue)")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .frame(width: 76, alignment: .leading)
                .contentTransition(.numericText(value: Double(sliderValue)))
                .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: sliderValue)
            // Continuous and rounded: a stepped slider draws a tick per step, a dotted line on long clips.
            Slider(value: $sliderStep, in: 1...Double(longestStep)) {
                Text("Touches per look")
            } minimumValueLabel: {
                Text("1").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            } maximumValueLabel: {
                Text("\(longestStep)").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            .tint(SessionStyle.mint)
            .accessibilityValue(sliderValue == 1 ? "Every touch" : "Every \(sliderValue) touches")
            .accessibilityIdentifier("look-every-slider")
            Button {
                withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { showsStepSlider = false }
            } label: {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
            }
            .appGlassButtonStyle().controlSize(.small)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("look-every-done")
        }
        .padding(.horizontal, 16)
        .onChange(of: sliderValue) { _, value in
            applyStep?.cancel()
            applyStep = Task {
                try? await Task.sleep(for: .seconds(0.3))
                guard !Task.isCancelled, value != edit.recipeStep else { return }
                applyEvery(value)
            }
        }
    }

    private var sliderValue: Int { Int(sliderStep.rounded()) }

    /// The presets that still change the look on this clip, plus a custom interval in use.
    private var stepChoices: [Int] {
        var steps = LookRecipes.steps.filter { $0 <= longestStep }
        if edit.recipe == .every, !steps.contains(shownStep) { steps.append(shownStep) }
        return steps.sorted()
    }

    /// The longest interval that still repeats on this clip; longer ones are never offered.
    private var longestStep: Int { LookRecipes.longestStep(touchCount: touchTimes.count) }
    /// The interval Every lays on this clip: a saved style's may be too long for a short one.
    private var shownStep: Int { min(edit.recipeStep, longestStep) }

    private func applyEvery(_ step: Int) {
        edit.recipeStep = step
        apply(.every)
    }

    /// Lays the recipe's runs across the clip, then plays its first change on the clip.
    private func apply(_ item: LookRecipe) {
        commitBall()
        recipeKicks[item, default: 0] += 1
        // Remix again rolls a new mix; every other recipe gives the same runs each time.
        if item == .remix && edit.recipe == .remix && edit.hasLookChanges { edit.recipeSeed += 1 }
        let result = LookRecipes.make(item, base: edit.baseLook, touchCount: touchTimes.count, seed: edit.recipeSeed,
                                      step: edit.recipeStep, lightweight: LookRecipes.prefersLightEffects)
        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
            edit.lookChanges = result.changes
            edit.swapEffect = result.moment
            if edit.intensity < 0.1 { edit.intensity = 0.85 }
            edit.recipe = item
        }
        cuts += 1
        if let first = result.changes.keys.min(), touchTimes.indices.contains(first) {
            selectedTouch = first
            onPreviewMoment(touchTimes[first])
        }
    }

    // MARK: Run line

    private var runFooter: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Look \(runNumber) of \(runStarts.count)")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText(value: Double(runNumber)))
                Text("\(rangeText) · \(name(runLook))")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.interpolate)
            }
            .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: run)
            .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: runLook)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("looks-summary")
            Spacer(minLength: 6)
            // One button that says what it does at the lens: start a look here, or remove the one starting here.
            Button(action: onLookStart ? merge : split) {
                Label(onLookStart ? "Remove look" : "New look here",
                      systemImage: onLookStart ? "minus.circle" : "plus.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            .appGlassButtonStyle().controlSize(.small)
            .disabled(!onLookStart && !canSplit)
            .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: onLookStart)
            .accessibilityHint(onLookStart ? "Touch \(selectedTouch + 1) and the touches after it go back to the look before"
                                           : "Gives touch \(selectedTouch + 1) and the touches after it a look of their own")
            .accessibilityIdentifier(onLookStart ? "looks-remove" : "looks-new")
        }
        .padding(.horizontal, 16)
    }

    private var rangeText: String {
        if run.count >= touchTimes.count { return "All \(touchTimes.count) touches" }
        let last = min(run.upperBound, touchTimes.count)
        return run.count == 1 ? "Touch \(run.lowerBound + 1)" : "Touches \(run.lowerBound + 1) to \(last)"
    }

    private func name(_ look: TouchLook) -> String {
        let ball = look.ball == .original ? "Original ball" : look.ball.title
        return look.effect == .none ? "\(ball), no effect" : "\(ball) + \(look.effect.title)"
    }

    /// A new run from the touch under the lens, starting with the same look until it is changed.
    private func split() {
        guard canSplit else { return }
        commitBall()
        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
            edit.lookChanges[selectedTouch] = edit.look(forTouch: selectedTouch)
            edit.recipe = nil
            // The change moment belongs to every look; a new look is given its ball next.
            if part == .change { part = .ball }
        }
        cuts += 1
    }

    private func merge() {
        let start = run.lowerBound
        guard start > 0 else { return }
        commitBall()
        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
            edit.lookChanges[start] = nil
            edit.recipe = nil
        }
        cuts += 1
    }

    // MARK: Pickers

    private var partChips: some View {
        HStack(spacing: 8) {
            ForEach(LookPart.allCases) { item in
                let selected = part == item
                Button {
                    commitBall()
                    withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { part = item }
                } label: {
                    HStack(spacing: 6) {
                        partIcon(item)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.rawValue.uppercased())
                                .font(.system(size: 8, weight: .bold)).tracking(0.8)
                                .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.5))
                            Text(partValue(item))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                                .contentTransition(.interpolate)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 38)
                    .frame(maxWidth: .infinity)
                    .background(selected ? SessionStyle.mint.opacity(0.13) : .white.opacity(0.05), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.3 : 0.5)
                    }
                    .contentShape(.rect(cornerRadius: 12))
                }
                .buttonStyle(SessionPressStyle(scale: 0.94))
                .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: selected)
                .accessibilityLabel("\(item.rawValue), \(partValue(item))")
                .accessibilityIdentifier("look-part-\(item.rawValue.lowercased())")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func partIcon(_ item: LookPart) -> some View {
        switch item {
        case .ball: BallThumbnail(skin: runLook.ball, size: 20)
        case .effect:
            Image(systemName: runLook.effect.symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(runLook.effect == .none ? .white.opacity(0.6) : runLook.effect.tint)
                .frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
        case .change:
            Image(systemName: edit.swapEffect.symbol).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SessionStyle.mint).frame(width: 20)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func partValue(_ item: LookPart) -> String {
        switch item {
        case .ball: runLook.ball == .original ? "Original" : runLook.ball.title
        case .effect: runLook.effect == .none ? "None" : runLook.effect.title
        case .change: edit.swapEffect.title
        }
    }

    /// One row of balls for the run under the lens, with the pick flight.
    private var ballRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(Array(skins.enumerated()), id: \.element) { index, skin in
                    ballOption(skin, direction: index < 2 ? 1 : -1).frame(width: 66)
                }
            }
            .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 2)
        }
        .scrollClipDisabled()
    }

    private func ballOption(_ skin: BallSkin, direction: CGFloat) -> some View {
        let selected = runLook.ball == skin
        return Button { pick(skin) } label: {
            VStack(spacing: 6) {
                BallPickSlot(skin: skin, selected: selected, picks: ballKicks[skin, default: 0], size: 52, direction: direction)
                Text(skin == .original ? "Original" : skin.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.9))
        .accessibilityLabel(skin == .original ? "Original ball" : skin.title)
        .accessibilityIdentifier("look-ball-\(skin.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .zIndex(selected ? 1 : 0)
    }

    private func pick(_ skin: BallSkin) {
        ballKicks[skin, default: 0] += 1
        if let pendingRun, pendingRun != run { commitBall() }
        pendingRun = run
        withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { pendingBall = skin }
        applyBall?.cancel()
        applyBall = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            commitBall(preview: true)
        }
    }

    private func commitBall(preview: Bool = false) {
        applyBall?.cancel(); applyBall = nil
        guard let pendingBall, let pendingRun else { return }
        var look = edit.look(forTouch: pendingRun.lowerBound)
        look.ball = pendingBall
        edit.setLook(look, forRunStartingAt: pendingRun.lowerBound)
        if pendingRun.lowerBound > 0 { edit.recipe = nil }
        self.pendingBall = nil; self.pendingRun = nil
        if preview, touchTimes.indices.contains(pendingRun.lowerBound) { onPreviewMoment(touchTimes[pendingRun.lowerBound]) }
    }

    /// Every effect, drawn on this run's ball.
    private var effectRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(BallStyle.selectableCases) { style in effectOption(style).id(style) }
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
            .scrollClipDisabled()
            .onAppear { proxy.scrollTo(runLook.effect, anchor: .center) }
        }
        .frame(height: 80)
    }

    private func effectOption(_ style: BallStyle) -> some View {
        let selected = runLook.effect == style
        return Button {
            effectKicks[style, default: 0] += 1
            commitBall()
            var look = edit.look(forTouch: run.lowerBound)
            look.effect = style
            withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) {
                edit.setLook(look, forRunStartingAt: run.lowerBound)
                if style != .none && edit.intensity < 0.1 { edit.intensity = 0.85 }
                if run.lowerBound > 0 { edit.recipe = nil }
            }
            if touchTimes.indices.contains(run.lowerBound) { onPreviewMoment(touchTimes[run.lowerBound]) }
        } label: {
            VStack(spacing: 5) {
                EffectIcon(style: style, ball: runLook.ball)
                    .frame(width: 62)
                    .aspectRatio(EffectIconRenderer.aspect, contentMode: .fit)
                    .background(selected ? SessionStyle.mint.opacity(0.1) : .white.opacity(0.04), in: .rect(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(selected ? SessionStyle.mint : .white.opacity(0.08), lineWidth: selected ? 1.5 : 0.5)
                    }
                    .sessionKick(effectKicks[style, default: 0], amount: 0.08)
                Text(style == .none ? "None" : style.title)
                    .font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? SessionStyle.mint : .white.opacity(0.8))
                    .lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(width: 66)
            .contentShape(.rect)
        }
        .buttonStyle(SessionPressStyle(scale: 0.92))
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: selected)
        .accessibilityLabel(style == .none ? "No effect" : style.title)
        .accessibilityIdentifier("look-effect-\(style.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The moment at every change, and the sound it makes.
    private var changeArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwapMomentPicker(selection: edit.swapEffect, from: momentPair.from, to: momentPair.to) { effect in
                withAnimation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion)) { edit.swapEffect = effect }
                // The moment preview plays the change sound with the picture; with no change yet, play the sound alone.
                if let change = nextChange { onPreviewMoment(change) } else { onPreviewSound(.swap(edit.swapSound)) }
            }
            HStack(spacing: 4) {
                Image(systemName: edit.swapSound == .none ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(edit.swapSound == .none ? "No sound" : edit.swapSound.title).contentTransition(.interpolate)
                if edit.swapSoundChoice == nil && edit.swapSound != .none {
                    Text("auto").foregroundStyle(SessionStyle.mint)
                }
                Text("· change it on the Sound page").foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ball-swap-sound-summary")
        }
    }

    /// The balls either side of the change at this run, for the moment previews.
    private var momentPair: (from: BallSkin, to: BallSkin) {
        let to = runLook.ball
        let from = run.lowerBound == 0 ? BallSkin.original : edit.look(forTouch: run.lowerBound - 1).ball
        if from != to { return (from, to) }
        return (.original, to == .original ? .volt : to)
    }

    /// The first change at or after this run, else the last one.
    private var nextChange: Double? {
        let swaps = edit.lookSwaps(touchTimes: touchTimes)
        return (swaps.first { $0.index >= run.lowerBound } ?? swaps.last)?.time
    }

    // MARK: Clip

    static func nearest(_ touchTimes: [Double], to time: Double) -> Int {
        guard !touchTimes.isEmpty else { return 0 }
        var best = 0
        for (index, touch) in touchTimes.enumerated() where abs(touch - time) < abs(touchTimes[best] - time) { best = index }
        return best
    }

    /// A frame just after the touch, once the change moment has cleared and the new look is in flight.
    private func holdTime(forTouch index: Int) -> Double {
        guard touchTimes.indices.contains(index) else { return currentTime }
        let next = index + 1 < touchTimes.count ? touchTimes[index + 1] - 0.03 : .infinity
        return min(touchTimes[index] + 0.22, max(touchTimes[index], next))
    }
}

/// The clip's looks in order, as small balls on a line in each look's effect colour.
struct LooksPreview: View {
    let looks: [TouchLook]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(looks.prefix(4).enumerated()), id: \.offset) { index, look in
                if index > 0 {
                    Capsule()
                        .fill(LinearGradient(colors: [TouchDial.color(for: looks[index - 1]), TouchDial.color(for: look)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 12, height: 3)
                }
                ZStack {
                    Circle().fill(TouchDial.color(for: look).opacity(0.22))
                    BallThumbnail(skin: look.ball, size: 22)
                }
                .frame(width: 30, height: 30)
                .shadow(color: TouchDial.color(for: look).opacity(0.55), radius: 5)
            }
        }
        .accessibilityHidden(true)
    }
}
