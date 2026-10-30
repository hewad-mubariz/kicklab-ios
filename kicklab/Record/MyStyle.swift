import Combine
import Foundation

/// The editor choices a person wants on every new session: the clip's ball and effect, the
/// recipe that lays the looks (not the touch positions, so it fits each session's touches), the
/// change moment and the sounds. Counter, timer and graph settings already persist on their own.
nonisolated struct MyStyle: Codable, Equatable, Sendable {
    var ball: String
    var effect: String
    var intensity: Double
    var recipe: String?
    var recipeSeed: Int
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
            let result = LookRecipes.make(recipe, base: edit.baseLook, touchCount: touchCount, seed: recipeSeed,
                                          lightweight: lightweight)
            edit.lookChanges = result.changes
            edit.recipe = recipe
            edit.recipeSeed = recipeSeed
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
