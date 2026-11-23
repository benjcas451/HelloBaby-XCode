import XCTest

/// Bildschirmfotos für Pull Requests (Minze & Honig 2.0).
///
/// Läuft nur im Workflow „Bildschirmfotos“; hell/dunkel und Schriftgröße
/// stellt der Workflow am Simulator ein und reicht den Namen der Variante als
/// MH_VARIANTE durch (TEST_RUNNER_MH_VARIANTE). Die App startet im lokalen
/// Modus; `-MhBildschirmfotos 1` legt dort erfundene Einträge an (Kind „Lina“,
/// Personen „Anna“ und „Ben“), solange die Datenbank leer ist.
///
/// Die Knöpfe werden über mehrere mögliche Beschriftungen gesucht, damit
/// derselbe Test auch die Ansichten vor der Umgestaltung fotografiert.
final class ScreenshotTests: XCTestCase {

  @MainActor
  func testAnsichten() throws {
    // Ein fehlender Knopf soll die übrigen Fotos nicht verhindern.
    continueAfterFailure = true
    let app = XCUIApplication()
    app.launchArguments += [
      "-MhBildschirmfotos", "1",
      "-data_source_mode", "local",
      "-app_display_name", "Lina",
      "-active_diary", "entwicklung",
      "-creator_users", "(Anna, Ben)",
      "-creator_default", "Anna",
      "-AppleLanguages", "(de)",
      "-AppleLocale", "de_DE",
    ]

    starte(app)
    foto(app, "01-start")
    app.swipeUp()
    foto(app, "02-start-unten")

    starte(app)
    if tippe(app, ["Tag", "Tagesansicht"]) { foto(app, "03-tag") }

    starte(app)
    if tippe(app, ["Monat", "Monatsansicht"]) { foto(app, "04-monat") }

    starte(app)
    if tippe(app, ["Favoriten"]) { foto(app, "05-favoriten") }

    starte(app)
    if tippe(app, ["Galerie"]) { foto(app, "06-galerie") }

    starte(app)
    if tippe(app, ["Neuer Eintrag", "Eintrag", "Eintrag erstellen"]) {
      foto(app, "07-erstellen")
      app.swipeUp()
      foto(app, "08-erstellen-unten")
    }

    starte(app)
    if tippe(app, ["Einstellungen"], ersatz: app.navigationBars.buttons) {
      foto(app, "09-einstellungen")
    }
  }

  /// Startet die App (neu); beim ersten Start entstehen die Testdaten.
  @MainActor
  private func starte(_ app: XCUIApplication) {
    app.launch()
    sleep(3)
  }

  /// Tippt den ersten vorhandenen Knopf aus `namen` an. Ohne Treffer und mit
  /// `ersatz` den letzten Knopf daraus (z. B. das Zahnrad der Leiste).
  @MainActor
  @discardableResult
  private func tippe(
    _ app: XCUIApplication, _ namen: [String], ersatz: XCUIElementQuery? = nil
  ) -> Bool {
    // Erst die genaue Beschriftung, dann enthaltene Wörter: Knöpfe mit
    // Systemsymbol tragen dessen Beschreibung mit im Namen.
    for name in namen {
      let knopf = app.buttons[name].firstMatch
      if knopf.waitForExistence(timeout: 2), knopf.isHittable {
        knopf.tap()
        return true
      }
    }
    for name in namen where name.count >= 5 {
      let knopf = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
      if knopf.exists, knopf.isHittable {
        knopf.tap()
        return true
      }
    }
    if let ersatz, ersatz.count > 0 {
      ersatz.element(boundBy: ersatz.count - 1).tap()
      return true
    }
    print("Kein Knopf gefunden: \(namen)")
    return false
  }

  @MainActor
  private func foto(_ app: XCUIApplication, _ name: String) {
    sleep(2)
    let variante = ProcessInfo.processInfo.environment["MH_VARIANTE"] ?? "standard"
    let anhang = XCTAttachment(screenshot: app.screenshot())
    anhang.name = "\(variante)-\(name)"
    anhang.lifetime = .keepAlways
    add(anhang)
  }
}
