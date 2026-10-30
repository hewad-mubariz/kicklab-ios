import XCTest

/// Tests rendered localized strings and navigation, without sign-in requests or
/// public leaderboard writes. The fixture also carries an old review ID to
/// ensure the postponed review flow stays hidden in every supported language.
final class LeaderboardLocalizationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSignInBoardRulesAndDetailsInEveryLanguage() {
        let languages = [
            ["en", "Continue with email", "Your best streak counts.", "Best streak", "Counted automatically from a recorded session.", "Done", "This week", "All time", "Counted for you after every recorded session."],
            ["de", "Weiter mit E-Mail", "Deine beste Serie zählt.", "Beste Serie", "Automatisch aus einem aufgenommenen Training gezählt.", "Fertig", "Diese Woche", "Gesamt", "Wird nach jedem aufgenommenen Training für dich gezählt."],
            ["es", "Continuar con correo", "Cuenta tu mejor racha.", "Mejor racha", "Contada automáticamente a partir de una sesión grabada.", "Listo", "Esta semana", "Histórico", "Se cuenta por ti después de cada sesión grabada."],
            ["fr", "Continuer avec l’e-mail", "Ta meilleure série compte.", "Meilleure série", "Comptée automatiquement à partir d’une séance enregistrée.", "Terminé", "Cette semaine", "Depuis toujours", "Comptée pour toi après chaque séance enregistrée."],
            ["pt-BR", "Continuar com e-mail", "Vale a sua melhor sequência.", "Melhor sequência", "Contada automaticamente a partir de um treino gravado.", "Concluído", "Esta semana", "Geral", "Contada para você depois de cada treino gravado."]
        ]
        for (index, text) in languages.enumerated() {
            let app = XCUIApplication()
            app.launchArguments = ["--reset-welcome", "--leaderboard-review-count", "1",
                "--leaderboard-legacy-review", "-AppleLanguages", "(\(text[0]))",
                "-kicklab.appearance", index % 2 == 0 ? "light" : "dark"]
            app.launch()
            let email = app.buttons["signin-email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15), text[0])
            XCTAssertTrue(email.label.contains(text[1]), "\(text[0]): \(email.label)")
            XCTAssertTrue(app.buttons["signin-apple"].exists)
            XCTAssertFalse(app.buttons["signin-google"].exists)
            email.tap()
            XCTAssertTrue(app.textFields["email-address"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["email-send"].isEnabled)
            attach(app, "\(text[0])-email")
            app.buttons["email-close"].tap()
            app.buttons["signin-guest"].tap()
            XCTAssertTrue(app.buttons["home-leaderboard"].waitForExistence(timeout: 10))
            app.buttons["home-leaderboard"].tap()
            let first = app.descendants(matching: .any)["leaderboard-pennant-1"]
            XCTAssertTrue(first.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["leaderboard-period-week"].label.localizedCaseInsensitiveContains(text[6]))
            XCTAssertTrue(app.buttons["leaderboard-period-all-time"].label.localizedCaseInsensitiveContains(text[7]))
            XCTAssertFalse(app.buttons["leaderboard-my-submissions"].exists)
            app.buttons["leaderboard-rules-link"].tap()
            XCTAssertTrue(app.staticTexts[text[2]].waitForExistence(timeout: 5), text[0])
            XCTAssertTrue(app.staticTexts[text[8]].exists, text[0])
            attach(app, "\(text[0])-rules")
            app.buttons[text[5]].tap()
            XCTAssertTrue(first.waitForExistence(timeout: 5))
            first.tap()
            XCTAssertTrue(app.buttons["leaderboard-player-close"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[text[3]].exists, text[0])
            XCTAssertTrue(app.staticTexts[text[4]].exists, text[0])
            attach(app, "\(text[0])-detail")
            app.terminate()
        }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "leaderboard-localization-" + name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
