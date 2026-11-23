import CoreText
import SwiftUI
import UIKit

// ============================================================================
// Minze & Honig 2.0 – Theme-Schicht (iOS)
// Quelle: DesignGuide/tokens/design-tokens.json (semantic.light / .dark,
// typography, radius, spacing). Komponenten benutzen nur diese Rollen, nie
// Skalenwerte. Farbe ist Signal, keine Fläche: genau eine Hauptaktion
// (primary) je Ansicht, alles andere Haarlinie oder Text.
// Ab iOS 16.
// ============================================================================

/// UIKit-Farbe, die dem Farbschema folgt (hell/dunkel).
private func mhUIFarbe(_ hell: UInt32, _ dunkel: UInt32) -> UIColor {
  UIColor { merkmale in
    let wert = merkmale.userInterfaceStyle == .dark ? dunkel : hell
    return UIColor(
      red: CGFloat((wert >> 16) & 0xFF) / 255,
      green: CGFloat((wert >> 8) & 0xFF) / 255,
      blue: CGFloat(wert & 0xFF) / 255,
      alpha: 1)
  }
}

/// SwiftUI-Farbe, die dem Farbschema folgt (hell/dunkel).
private func mhFarbe(_ hell: UInt32, _ dunkel: UInt32) -> Color {
  Color(mhUIFarbe(hell, dunkel))
}

/// Die wenigen Rollen, die UIKit-Darstellungen brauchen (Navigationsleiste,
/// Segmente, Tab-Leiste) – direkt als dynamische UIColor.
enum MhUI {
  static let bg = mhUIFarbe(0xFFFFFF, 0x1F2221)
  static let surfaceSubtle = mhUIFarbe(0xF6F8F6, 0x2B302D)
  static let segmentOn = mhUIFarbe(0xFFFFFF, 0x343A36)
  static let border = mhUIFarbe(0xE7EBE8, 0x343A36)
  static let textStrong = mhUIFarbe(0x1F2221, 0xFFFFFF)
  static let textSecondary = mhUIFarbe(0x5D655F, 0xA9B0AB)
  static let link = mhUIFarbe(0x38664C, 0xA8D5BA)
  static let primary = mhUIFarbe(0x38664C, 0x82BD9B)
}

/// Rollen, Maße und Schrift des Designsystems: `Mh.primary`, `Mh.radiusMd` …
enum Mh {

  // MARK: Rollen (Namen wie in design-tokens.json)

  static let bg = mhFarbe(0xFFFFFF, 0x1F2221)
  static let surface = mhFarbe(0xFFFFFF, 0x262A28)
  static let surfaceSubtle = mhFarbe(0xF6F8F6, 0x2B302D)
  static let surfaceRaised = mhFarbe(0xFFFFFF, 0x2E3330)
  static let segmentOn = mhFarbe(0xFFFFFF, 0x343A36)
  static let fieldBg = mhFarbe(0xFFFFFF, 0x1F2221)
  static let border = mhFarbe(0xE7EBE8, 0x343A36)
  static let borderStrong = mhFarbe(0xDFE4E1, 0x454C47)
  static let text = mhFarbe(0x2E332F, 0xE6EAE7)
  static let textStrong = mhFarbe(0x1F2221, 0xFFFFFF)
  static let textSecondary = mhFarbe(0x5D655F, 0xA9B0AB)
  static let textTertiary = mhFarbe(0x7C857F, 0x8A938D)
  static let textDisabled = mhFarbe(0xA2ABA6, 0x6B736E)
  static let link = mhFarbe(0x38664C, 0xA8D5BA)
  static let primary = mhFarbe(0x38664C, 0x82BD9B)
  static let onPrimary = mhFarbe(0xFFFFFF, 0x1F2221)
  static let primaryHover = mhFarbe(0x2C4F3B, 0xA8D5BA)
  static let danger = mhFarbe(0xB3453E, 0xF0B6B1)
  static let onDanger = mhFarbe(0xFFFFFF, 0x1F2221)
  static let focusRing = mhFarbe(0x5FA07C, 0xA8D5BA)
  static let selectedBg = mhFarbe(0xE1F3E8, 0x2C4F3B)
  static let onSelected = mhFarbe(0x2C4F3B, 0xC8E8D4)
  static let tint = mhFarbe(0xF2FAF5, 0x263B2F)
  static let onTint = mhFarbe(0x38664C, 0xA8D5BA)
  static let highlight = mhFarbe(0xFBF3D3, 0x3B3524)
  static let onHighlight = mhFarbe(0x473A17, 0xF9EDBB)
  static let textGreen = mhFarbe(0x38664C, 0xA8D5BA)
  static let textYellow = mhFarbe(0x8A6F26, 0xF7E8A4)
  static let textPurple = mhFarbe(0x7D5591, 0xCDB4DB)
  static let data1 = mhFarbe(0x82BD9B, 0xA8D5BA)
  static let data2 = mhFarbe(0xEDD374, 0xF7E8A4)
  static let data3 = mhFarbe(0xB592CA, 0xCDB4DB)
  static let dataTrack = mhFarbe(0xEDF0EE, 0x343A36)
  static let successFg = mhFarbe(0x38664C, 0xA8D5BA)
  static let successBg = mhFarbe(0xE1F3E8, 0x263B2F)
  static let warningFg = mhFarbe(0x8A6F26, 0xF7E8A4)
  static let warningBg = mhFarbe(0xFBF3D3, 0x3B3524)
  static let errorFg = mhFarbe(0xB3453E, 0xF0B6B1)
  static let errorBg = mhFarbe(0xFAE3E1, 0x3F2523)
  static let infoFg = mhFarbe(0x7D5591, 0xCDB4DB)
  static let infoBg = mhFarbe(0xF1E9F6, 0x352B3C)

  // MARK: Radien (Guide Abschnitt 5)

  static let radiusSm: CGFloat = 6
  static let radiusMd: CGFloat = 10
  static let radiusLg: CGFloat = 14
  static let radiusXl: CGFloat = 20

  // MARK: 4-pt-Raster (Guide Abschnitt 4)

  static let abstand1: CGFloat = 4
  static let abstand2: CGFloat = 8
  static let abstand3: CGFloat = 12
  static let abstand4: CGFloat = 16
  static let abstand5: CGFloat = 20
  static let abstand6: CGFloat = 24
  static let abstand8: CGFloat = 32
  static let abstand12: CGFloat = 48

  /// Seitenrand auf dem Handy.
  static let rand: CGFloat = 16
  /// Touch-Ziel auf iOS.
  static let touch: CGFloat = 44
  /// Symbolgrößen
  static let symbolKlein: CGFloat = 16
  static let symbol: CGFloat = 20
  static let symbolGross: CGFloat = 24
}

// MARK: - Schrift Figtree (400/500/600, keine Kursive)

/// Figtree liegt als TTF im Bundle und steht in `UIAppFonts`. Falls die
/// Info.plist-Eintragung fehlt, registriert [registrieren] die Dateien zur
/// Laufzeit (einmal beim Start aufrufen, schadet sonst nicht).
enum MhSchrift {
  static let regular = "Figtree-Regular"
  static let medium = "Figtree-Medium"
  static let semibold = "Figtree-SemiBold"

  static func registrieren() {
    guard UIFont(name: regular, size: 12) == nil else { return }
    for name in [regular, medium, semibold] {
      if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }
}

/// Typo-Skala aus dem Guide (Abschnitt 3), Größen in pt, mit Dynamic Type.
enum MhTextStil {
  case display, h1, h2, h3, body, label, button, small, chip, caption, number

  var groesse: CGFloat {
    switch self {
    case .display: return 30
    case .h1: return 26
    case .h2: return 19
    case .h3, .body: return 16
    case .button: return 15
    case .label, .small: return 14
    case .chip: return 13
    case .caption: return 12
    case .number: return 28
    }
  }

  var schnitt: String {
    switch self {
    case .display, .h1, .h2, .h3: return MhSchrift.semibold
    case .label, .button, .caption: return MhSchrift.medium
    case .body, .small, .chip, .number: return MhSchrift.regular
    }
  }

  /// Bezugsstil für Dynamic Type.
  var bezug: Font.TextStyle {
    switch self {
    case .display: return .largeTitle
    case .h1: return .title
    case .h2: return .title3
    case .h3: return .headline
    case .body: return .body
    case .label, .button: return .subheadline
    case .small: return .subheadline
    case .chip: return .footnote
    case .caption: return .caption
    case .number: return .title
    }
  }

  /// Zeilenhöhe als Faktor der Schriftgröße.
  var zeilenhoehe: CGFloat {
    switch self {
    case .display: return 1.15
    case .h1: return 1.2
    case .h2: return 1.3
    case .h3, .label, .chip, .caption, .button: return 1.4
    case .body: return 1.55
    case .small: return 1.5
    case .number: return 1.1
    }
  }

  /// Laufweite in em.
  var laufweite: CGFloat {
    switch self {
    case .display: return -0.025
    case .h1, .h2: return -0.015
    case .caption: return 0.08
    case .number: return -0.02
    default: return 0
    }
  }

  var font: Font { .custom(schnitt, size: groesse, relativeTo: bezug) }

  /// UIFont für UIKit-Darstellungen (Navigationsleiste, Segmente).
  var uiFont: UIFont {
    let basis = UIFont(name: schnitt, size: groesse) ?? .systemFont(ofSize: groesse)
    return UIFontMetrics(forTextStyle: bezug.uiKit).scaledFont(for: basis)
  }
}

private extension Font.TextStyle {
  var uiKit: UIFont.TextStyle {
    switch self {
    case .largeTitle: return .largeTitle
    case .title: return .title1
    case .title2: return .title2
    case .title3: return .title3
    case .headline: return .headline
    case .subheadline: return .subheadline
    case .callout: return .callout
    case .footnote: return .footnote
    case .caption: return .caption1
    case .caption2: return .caption2
    default: return .body
    }
  }
}

extension View {
  /// Schrift, Laufweite und Zeilenabstand eines Typo-Stils.
  func mhText(_ stil: MhTextStil) -> some View {
    self
      .font(stil.font)
      .tracking(stil.groesse * stil.laufweite)
      .lineSpacing(max(0, stil.groesse * (stil.zeilenhoehe - 1.25)))
      .mhTabellenziffern(stil == .number)
  }

  /// Ziffern gleich breit (Statistiken, Uhrzeiten).
  @ViewBuilder
  func mhTabellenziffern(_ an: Bool = true) -> some View {
    if an { self.monospacedDigit() } else { self }
  }
}

// MARK: - UIKit-Teile an das Theme anpassen

enum MhDarstellung {
  /// Einmal beim Start aufrufen: Navigationsleiste, Segmente und Tab-Leiste
  /// bekommen Figtree und die neutralen Flächen des Guides.
  static func einrichten() {
    MhSchrift.registrieren()

    let leiste = UINavigationBarAppearance()
    leiste.configureWithOpaqueBackground()
    leiste.backgroundColor = MhUI.bg
    leiste.shadowColor = .clear
    leiste.titleTextAttributes = [
      .font: MhTextStil.h3.uiFont, .foregroundColor: MhUI.textStrong,
    ]
    leiste.largeTitleTextAttributes = [
      .font: MhTextStil.h1.uiFont, .foregroundColor: MhUI.textStrong,
    ]
    let knopf = UIBarButtonItemAppearance()
    knopf.normal.titleTextAttributes = [
      .font: MhTextStil.button.uiFont, .foregroundColor: MhUI.link,
    ]
    leiste.buttonAppearance = knopf
    leiste.backButtonAppearance = knopf
    UINavigationBar.appearance().standardAppearance = leiste
    UINavigationBar.appearance().scrollEdgeAppearance = leiste
    UINavigationBar.appearance().compactAppearance = leiste
    UINavigationBar.appearance().tintColor = MhUI.link

    let segment = UISegmentedControl.appearance()
    segment.selectedSegmentTintColor = MhUI.segmentOn
    segment.backgroundColor = MhUI.surfaceSubtle
    segment.setTitleTextAttributes(
      [.font: MhTextStil.label.uiFont, .foregroundColor: MhUI.textSecondary], for: .normal)
    segment.setTitleTextAttributes(
      [.font: MhTextStil.label.uiFont, .foregroundColor: MhUI.textStrong], for: .selected)

    let tab = UITabBarAppearance()
    tab.configureWithOpaqueBackground()
    tab.backgroundColor = MhUI.bg
    tab.shadowColor = MhUI.border
    UITabBar.appearance().standardAppearance = tab
    UITabBar.appearance().scrollEdgeAppearance = tab
    UITabBar.appearance().tintColor = MhUI.primary
  }
}
