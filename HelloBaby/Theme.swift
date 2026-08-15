import SwiftUI

/// Farbwelt der HelloBaby-App – identisch zur Flutter-App (Seed #78B856,
/// „Baby-Grün“) inklusive der sechs Home-Aktionsfarben.
enum Hb {

  static let seed = Color(hex: 0x78B856)
  static let accentDeep = Color(hex: 0x5A9A3C)
  static let gold = Color(hex: 0xE0A920)

  // Aktionsfarben der Home-Buttons (Reihenfolge wie in der Flutter-App).
  static let aktionErstellen = Color(hex: 0x5A9A3C)
  static let aktionTag = Color(hex: 0x4F86C6)
  static let aktionMonat = Color(hex: 0x8E7CC3)
  static let aktionZufall = Color(hex: 0x6FAF53)
  static let aktionFavoriten = Color(hex: 0xDAA520)
  static let aktionGalerie = Color(hex: 0xCB6CA8)

  // Flächen hell/dunkel wie das Flutter-Theme.
  static let scaffoldHell = Color(hex: 0xF5F7F0)
  static let scaffoldDunkel = Color(hex: 0x0F1310)
  static let karteHell = Color.white
  static let karteDunkel = Color(hex: 0x1A1F1B)
  static let outlineHell = Color(hex: 0xE3E7DD)
  static let outlineDunkel = Color(hex: 0x2C332D)
  static let chipHell = Color(hex: 0xEDF3E6)
  static let chipDunkel = Color(hex: 0x20271F)

  /// Vorder­grundfarbe nach Helligkeit der Fläche (wie die Flutter-App).
  static func vordergrund(fuer farbe: Color) -> Color {
    UIColor(farbe).luminanz > 0.6 ? .black : .white
  }
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

extension UIColor {
  /// Relative Luminanz (vereinfacht, wie Flutters computeLuminance-Schwelle).
  var luminanz: CGFloat {
    var rot: CGFloat = 0
    var gruen: CGFloat = 0
    var blau: CGFloat = 0
    getRed(&rot, green: &gruen, blue: &blau, alpha: nil)
    return 0.299 * rot + 0.587 * gruen + 0.114 * blau
  }
}

// MARK: - Gemeinsame Bausteine

/// Hintergrund je nach Farbschema.
struct HbHintergrund: ViewModifier {
  @Environment(\.colorScheme) private var schema
  func body(content: Content) -> some View {
    content.background(
      (schema == .dark ? Hb.scaffoldDunkel : Hb.scaffoldHell).ignoresSafeArea())
  }
}

extension View {
  func hbHintergrund() -> some View { modifier(HbHintergrund()) }
}

/// Kartenfläche je nach Farbschema.
struct HbKarte: ViewModifier {
  @Environment(\.colorScheme) private var schema
  func body(content: Content) -> some View {
    content
      .background(schema == .dark ? Hb.karteDunkel : Hb.karteHell)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .overlay(
        RoundedRectangle(cornerRadius: 16)
          .stroke(schema == .dark ? Hb.outlineDunkel : Hb.outlineHell, lineWidth: 1))
  }
}

extension View {
  func hbKarte() -> some View { modifier(HbKarte()) }
}

/// Deutsche Datumsformate wie die Flutter-App (dd.MM.yyyy).
enum HbDatum {
  static func anzeige(_ isoDatum: String) -> String {
    formatiert(isoDatum, muster: "dd.MM.yyyy")
  }

  static func mitWochentag(_ isoDatum: String) -> String {
    formatiert(isoDatum, muster: "EEEE, dd.MM.yyyy")
  }

  private static func formatiert(_ isoDatum: String, muster: String) -> String {
    let leser = DateFormatter()
    leser.locale = Locale(identifier: "en_US_POSIX")
    leser.dateFormat = "yyyy-MM-dd"
    guard let datum = leser.date(from: isoDatum) else { return isoDatum }
    let schreiber = DateFormatter()
    schreiber.locale = Locale(identifier: "de_DE")
    schreiber.dateFormat = muster
    return schreiber.string(from: datum)
  }
}
