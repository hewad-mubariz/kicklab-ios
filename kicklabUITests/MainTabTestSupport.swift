import XCTest

extension XCUIApplication {
    /// A main tab button. The localized labels are listed for reference.
    @MainActor
    func mainTab(_ name: String) -> XCUIElement {
        let labels: [String]
        switch name {
        case "home": labels = ["Home", "Inicio", "Accueil", "Início"]
        case "learn": labels = ["Learn", "Lernen", "Aprender", "Apprendre"]
        case "challenges": labels = ["Challenges", "Desafíos", "Défis", "Desafios"]
        case "wallGame": labels = ["Wall Game", "Wandspiel", "Juego de pared", "Jeu au mur", "Jogo na parede"]
        case "leaderboard": labels = ["Leaderboard", "Rangliste", "Ranking", "Classement"]
        default: preconditionFailure("Unknown tab: \(name)")
        }
        // The app draws its own tab bar (AnimatedTabBar); its buttons carry tab-<name>.
        _ = labels
        return buttons.matching(identifier: "tab-\(name)").firstMatch
    }
}

extension XCUIApplication {
    /// The five main tab buttons.
    @MainActor
    var mainTabButtons: XCUIElementQuery {
        buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab-"))
    }
}
