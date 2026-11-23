import Foundation
import UIKit

/// Erfundene Testdaten für die Bildschirmfotos (Workflow „Bildschirmfotos“).
///
/// Greift nur, wenn die App mit dem Launch-Argument `-MhBildschirmfotos 1`
/// gestartet wird, nur im lokalen Modus und nur, solange die lokale
/// Datenbank leer ist. Vorhandene Einträge werden nie angefasst; im normalen
/// Betrieb ist der Schalter nie gesetzt und hier passiert nichts.
///
/// Name im Titel und Personen kommen beim Bildschirmfoto-Lauf ebenfalls über
/// Launch-Argumente (`-app_display_name Lina` …). Die gelten nur für diesen
/// Start und landen nicht in den gespeicherten Einstellungen.
enum Bildschirmfotodaten {

  private static var arbeit: Task<Void, Never>?

  static var aktiv: Bool {
    UserDefaults.standard.bool(forKey: "MhBildschirmfotos") && AppSettings.mode == .local
  }

  /// Legt die Testdaten einmal an; weitere Aufrufe warten nur darauf.
  static func vorbereiten() async {
    guard aktiv else { return }
    if arbeit == nil {
      arbeit = Task { await anlegen() }
    }
    await arbeit?.value
  }

  private struct Vorlage {
    let diary: String
    let vorTagen: Int
    let von: String
    let felder: [String: String]
    let bilder: [Int]
    let favorit: Bool
  }

  private static let vorlagen: [Vorlage] = [
    Vorlage(
      diary: "schwangerschaft", vorTagen: 230, von: "Anna",
      felder: [
        "empfinden": "Heute zum ersten Mal deutlich gespürt, wie sie tritt.",
        "gewicht": "68.5", "bauchumfang": "96",
      ],
      bilder: [], favorit: false),
    Vorlage(
      diary: "entwicklung", vorTagen: 33, von: "Ben",
      felder: ["notiz": "Lina lacht laut, wenn der Hund durchs Zimmer läuft."],
      bilder: [], favorit: true),
    Vorlage(
      diary: "entwicklung", vorTagen: 11, von: "Anna",
      felder: [
        "notiz": "Heute zum ersten Mal Brei probiert. Karotte war noch nicht ganz ihr Fall.",
        "sonstiges": "Danach hat sie fast zwei Stunden geschlafen.",
        "gewicht": "8.1",
      ],
      bilder: [2], favorit: false),
    Vorlage(
      diary: "entwicklung", vorTagen: 3, von: "Ben",
      felder: [
        "notiz": "Erster Ausflug in den Park. Die Enten fand sie spannender als alles andere.",
        "groesse": "68", "kopfumfang": "42",
      ],
      bilder: [], favorit: false),
    Vorlage(
      diary: "entwicklung", vorTagen: 0, von: "Anna",
      felder: [
        "notiz": "Lina dreht sich jetzt von allein auf den Bauch und schaut sich alles ganz genau an.",
        "gewicht": "8.4",
      ],
      bilder: [0, 1], favorit: true),
  ]

  private static func anlegen() async {
    let store = LocalStore.shared
    guard let vorhanden = try? await store.allEntries(), vorhanden.isEmpty else { return }
    let tag = DateFormatter()
    tag.locale = Locale(identifier: "en_US_POSIX")
    tag.dateFormat = "yyyy-MM-dd"
    for vorlage in vorlagen {
      let datum =
        Calendar.current.date(byAdding: .day, value: -vorlage.vorTagen, to: Date()) ?? Date()
      let dateien = vorlage.bilder.compactMap(testbild)
      defer { dateien.forEach { try? FileManager.default.removeItem(at: $0) } }
      var felder = vorlage.felder
      for feld in kDiaries[vorlage.diary]?.fields ?? [] where felder[feld.key] == nil {
        felder[feld.key] = ""
      }
      guard
        let id = try? await store.createEntry(
          kalenderDatum: tag.string(from: datum), fields: felder, vonName: vorlage.von,
          images: dateien, diary: vorlage.diary)
      else { continue }
      if vorlage.favorit {
        _ = try? await store.toggleFavorite(id: id, diary: vorlage.diary)
      }
    }
  }

  /// Ein erzeugtes Bild: Farbverlauf mit Hügel und Sonne, als JPEG in `tmp/`.
  private static func testbild(_ art: Int) -> URL? {
    let farben: [(UInt32, UInt32)] = [
      (0xF9EDBB, 0xEDD374), (0xE2D2EB, 0xB592CA), (0xE1F3E8, 0xA8D5BA),
    ]
    let (oben, unten) = farben[art % farben.count]
    let kante: CGFloat = 900
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let bild = UIGraphicsImageRenderer(size: CGSize(width: kante, height: kante), format: format)
      .image { kontext in
        let c = kontext.cgContext
        if let verlauf = CGGradient(
          colorsSpace: CGColorSpaceCreateDeviceRGB(),
          colors: [farbe(oben).cgColor, farbe(unten).cgColor] as CFArray,
          locations: [0, 1])
        {
          c.drawLinearGradient(
            verlauf, start: .zero, end: CGPoint(x: 0, y: kante), options: [])
        }
        UIColor(white: 1, alpha: 0.9).setFill()
        c.fillEllipse(in: CGRect(x: 560, y: 170, width: 190, height: 190))
        if art != 1 {
          let huegel = UIBezierPath()
          huegel.move(to: CGPoint(x: 0, y: kante))
          huegel.addLine(to: CGPoint(x: 0, y: 650))
          huegel.addLine(to: CGPoint(x: 250, y: 430))
          huegel.addLine(to: CGPoint(x: 480, y: 620))
          huegel.addLine(to: CGPoint(x: 650, y: 500))
          huegel.addLine(to: CGPoint(x: kante, y: 720))
          huegel.addLine(to: CGPoint(x: kante, y: kante))
          huegel.close()
          farbe(0x5FA07C).setFill()
          huegel.fill()
        }
      }
    guard let daten = bild.jpegData(compressionQuality: 0.85) else { return nil }
    let ziel = FileManager.default.temporaryDirectory
      .appendingPathComponent("testbild-\(art)-\(UUID().uuidString.prefix(8)).jpg")
    do {
      try daten.write(to: ziel)
      return ziel
    } catch {
      return nil
    }
  }

  private static func farbe(_ wert: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((wert >> 16) & 0xFF) / 255,
      green: CGFloat((wert >> 8) & 0xFF) / 255,
      blue: CGFloat(wert & 0xFF) / 255,
      alpha: 1)
  }
}
