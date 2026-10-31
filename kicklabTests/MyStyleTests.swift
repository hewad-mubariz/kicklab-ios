import Foundation
import Testing
@testable import kicklab

@MainActor
struct MyStyleTests {
    private func styled() -> SessionEditState {
        var edit = SessionEditState(style: .fire, intensity: 0.734, ballSkin: .gold)
        let result = LookRecipes.make(.powerUp, base: edit.baseLook, touchCount: 120)
        edit.lookChanges = result.changes
        edit.recipe = .powerUp
        edit.swapEffect = .lightning
        edit.swapSoundChoice = .chime
        edit.touchSound = .kick
        edit.clipAudio = false
        return edit
    }

    @Test func savesTheRecipeAndRefitsItToEachSession() {
        let style = MyStyle(edit: styled())
        #expect(style.recipe == "powerUp" && style.ball == "gold" && style.effect == "fire")
        #expect(style.intensity == 0.73, "Intensity is kept to two places so tiny slider jitter still matches")
        let short = style.edit(touchCount: 30, lightweight: false)
        let long = style.edit(touchCount: 120, lightweight: false)
        #expect(short.lookChanges.keys.sorted() == [9, 24], "Power-up fits a 30-touch session")
        #expect(long.lookChanges.keys.sorted() == [9, 24, 49, 99])
        #expect(long.recipe == .powerUp && long.ballSkin == .gold && long.style == .fire)
        #expect(long.swapEffect == .lightning, "The person's change effect wins over the recipe's")
        #expect(long.swapSoundChoice == .chime && long.touchSound == .kick && !long.clipAudio)
        #expect(style.matches(long))
    }

    @Test func customRunsStayWithTheirReplay() {
        var edit = styled()
        edit.recipe = nil
        edit.lookChanges[5] = TouchLook(ball: .pearl, effect: .ice)
        let style = MyStyle(edit: edit)
        #expect(style.recipe == nil)
        #expect(style.edit(touchCount: 50).lookChanges.isEmpty)
        var plain = SessionEditState(style: .glowTrail, intensity: 0.85)
        plain.recipe = .finale
        #expect(MyStyle(edit: plain).recipe == nil, "A recipe with no runs left is not saved")
    }

    @Test func unknownSavedValuesFallBackSafely() throws {
        let json = #"{"ball":"retired","effect":"gone","intensity":3,"recipe":"newRecipe","recipeSeed":2,"swapEffect":"x","swapSound":"y","touchSound":"z","clipAudio":true}"#
        let style = try JSONDecoder().decode(MyStyle.self, from: Data(json.utf8))
        let edit = style.edit(touchCount: 40)
        #expect(edit.ballSkin == .original && edit.style == .glowTrail && edit.intensity == 1)
        #expect(edit.lookChanges.isEmpty && edit.recipe == nil)
        #expect(edit.swapEffect == .pop && edit.swapSoundChoice == nil && edit.touchSound == .none)
    }

    @Test func storeKeepsTheStyleAcrossLaunchesAndCanForgetIt() throws {
        let suite = "my-style-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MyStyleStore(defaults: defaults)
        #expect(first.saved == nil)
        #expect(first.startingEdit(touchCount: 20) == SessionEditState(style: .glowTrail, intensity: 0.85))
        first.save(MyStyle(edit: styled()))
        let relaunched = MyStyleStore(defaults: defaults)
        #expect(relaunched.saved == MyStyle(edit: styled()))
        #expect(relaunched.startingEdit(touchCount: 120).recipe == .powerUp)
        relaunched.clear()
        #expect(MyStyleStore(defaults: defaults).saved == nil)
        // Memory only: design reviews and UI tests never touch the person's style.
        let memory = MyStyleStore(defaults: nil)
        memory.save(MyStyle(edit: styled()))
        #expect(memory.saved != nil && defaults.data(forKey: MyStyleStore.key) == nil)
    }
}
