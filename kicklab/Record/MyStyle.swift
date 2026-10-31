import Combine
import Foundation
import SwiftUI

/// The editor choices a person wants on every new session: the clip's ball and effect, the
/// recipe that lays the looks (not the touch positions, so it fits each session's touches), the
/// change moment and the sounds. Counter, timer and graph settings already persist on their own.
nonisolated struct MyStyle: Codable, Equatable, Sendable {
    var ball: String
    var effect: String
    var intensity: Double
    var recipe: String?
    var recipeSeed: Int
    /// Every's interval; nil for the other recipes and for styles saved before it could change.
    var recipeStep: Int?
    var swapEffect: String
    var swapSound: String?
    var touchSound: String
    var clipAudio: Bool

    init(edit: SessionEditState) {
        ball = edit.ballSkin.rawValue
        effect = edit.style.rawValue
        intensity = (edit.intensity * 100).rounded() / 100
        // Custom runs belong to one clip's touches; only a recipe carries over.
        recipe = edit.hasLookChanges ? edit.recipe?.rawValue : nil
        recipeSeed = recipe == nil ? 1 : edit.recipeSeed
        recipeStep = recipe == LookRecipe.every.rawValue ? edit.recipeStep : nil
        swapEffect = edit.swapEffect.rawValue
        swapSound = edit.swapSoundChoice?.rawValue
        touchSound = edit.touchSound.rawValue
        clipAudio = edit.clipAudio
    }

    /// The edit for a session with `touchCount` touches; unknown saved values fall back to defaults.
    func edit(touchCount: Int, lightweight: Bool = LookRecipes.prefersLightEffects) -> SessionEditState {
        var edit = SessionEditState(style: BallStyle(rawValue: effect) ?? .glowTrail, intensity: max(0, min(1, intensity)),
                                    ballSkin: BallSkin(rawValue: ball) ?? .original)
        edit.touchSound = TouchSound(rawValue: touchSound) ?? .none
        edit.swapSoundChoice = swapSound.flatMap(BallSwapSound.init(rawValue:))
        edit.clipAudio = clipAudio
        if let recipe = recipe.flatMap(LookRecipe.init(rawValue:)) {
            let step = recipeStep ?? LookRecipes.defaultStep
            let result = LookRecipes.make(recipe, base: edit.baseLook, touchCount: touchCount, seed: recipeSeed,
                                          step: step, lightweight: lightweight)
            edit.lookChanges = result.changes
            edit.recipe = recipe
            edit.recipeSeed = recipeSeed
            edit.recipeStep = step
        }
        edit.swapEffect = BallSwapEffect(rawValue: swapEffect) ?? .pop
        return edit
    }

    /// Whether `edit` is what My style would make.
    func matches(_ edit: SessionEditState) -> Bool { MyStyle(edit: edit) == self }
}

/// Where My style is kept. Design reviews and UI tests use memory only, so they never change
/// a person's saved style and always start clean.
@MainActor
final class MyStyleStore: ObservableObject {
    static let shared = MyStyleStore()
    static let key = "juggledude.myStyle.v1"

    @Published private(set) var saved: MyStyle?
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = ProcessInfo.processInfo.arguments.contains("--session-design") ? nil : .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.key) {
            saved = try? JSONDecoder().decode(MyStyle.self, from: data)
        }
    }

    func save(_ style: MyStyle) {
        saved = style
        if let data = try? JSONEncoder().encode(style) { defaults?.set(data, forKey: Self.key) }
    }

    func clear() {
        saved = nil
        defaults?.removeObject(forKey: Self.key)
    }

    /// The starting edit for a new session: My style if there is one, else the editor default.
    func startingEdit(touchCount: Int) -> SessionEditState {
        saved?.edit(touchCount: touchCount) ?? SessionEditState(style: .glowTrail, intensity: 0.85)
    }
}

/// Offered once a replay is saved, when the person has just decided they like it: one tap makes
/// this edit the start of every new session, and Record another opens straight into it.
struct MyStyleShareRow: View {
    let edit: SessionEditState
    @ObservedObject private var store = MyStyleStore.shared
    @State private var saves = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let saved = store.saved
        let matches = saved?.matches(edit) == true
        HStack(spacing: 12) {
            Image(systemName: matches ? "bookmark.fill" : "bookmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(matches ? SessionStyle.background : SessionStyle.mint)
                .frame(width: 34, height: 34)
                .background(matches ? SessionStyle.mint : SessionStyle.mint.opacity(0.14), in: .circle)
                .symbolEffect(.bounce, value: saves)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(matches ? "This is your style" : saved == nil ? "Start every session with this look" : "Make this my new style")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .contentTransition(.interpolate)
                Text(matches ? "New sessions open with it" : "Ball, effects, looks and sounds")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.66))
                    .contentTransition(.interpolate)
            }
            Spacer(minLength: 6)
            if matches {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(SessionStyle.mint)
                    .transition(.sessionPop(scale: 0.3))
                    .accessibilityLabel("Saved as My style")
                    .accessibilityIdentifier("my-style-saved")
            } else {
                Button(saved == nil ? "Save" : "Update") {
                    withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) {
                        store.save(MyStyle(edit: edit))
                    }
                    saves += 1
                }
                .font(.system(size: 13, weight: .semibold))
                .appGlassButtonStyle().controlSize(.small)
                .transition(.sessionPop(scale: 0.4))
                .accessibilityIdentifier("my-style-save")
            }
            if saved != nil {
                Menu {
                    Button("Stop using My style", systemImage: "bookmark.slash", role: .destructive) {
                        withAnimation(SessionMotion.animation(SessionMotion.pop, reduceMotion: reduceMotion)) { store.clear() }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 34).contentShape(.rect)
                }
                .accessibilityLabel("My style options")
                .accessibilityIdentifier("my-style-menu")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.white.opacity(matches ? 0.08 : 0.05), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(matches ? SessionStyle.mint.opacity(0.45) : .white.opacity(0.08), lineWidth: 0.75)
        }
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: matches)
        .animation(SessionMotion.animation(SessionMotion.snap, reduceMotion: reduceMotion), value: saved)
        .sensoryFeedback(.success, trigger: saves)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("my-style")
    }
}
