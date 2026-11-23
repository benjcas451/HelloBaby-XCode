import SwiftUI

// ============================================================================
// Minze & Honig 2.0 – gemeinsame Bausteine (Guide Abschnitt 7), iOS 16+.
// Entsprechen den Web-Klassen in DesignGuide/web/components.css.
// ============================================================================

// MARK: - Symbole

/// Liniensymbol aus Assets.xcassets (Mh*.imageset), Farbe aus dem Kontext.
struct MhSymbol: View {
  let name: String
  var groesse: CGFloat = Mh.symbol

  init(_ name: String, groesse: CGFloat = Mh.symbol) {
    self.name = name
    self.groesse = groesse
  }

  var body: some View {
    Image(name)
      .renderingMode(.template)
      .resizable()
      .scaledToFit()
      .frame(width: groesse, height: groesse)
      .accessibilityHidden(true)
  }
}

/// Symbol-Knopf (`.icon-btn`): 44 × 44, ohne Rahmen, Nebentextfarbe.
struct MhSymbolButton: View {
  let symbol: String
  let beschreibung: String
  var farbe: Color = Mh.textSecondary
  let aktion: () -> Void

  init(_ symbol: String, beschreibung: String, farbe: Color = Mh.textSecondary, aktion: @escaping () -> Void) {
    self.symbol = symbol
    self.beschreibung = beschreibung
    self.farbe = farbe
    self.aktion = aktion
  }

  var body: some View {
    Button(action: aktion) {
      MhSymbol(symbol)
        .frame(width: Mh.touch, height: Mh.touch)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(farbe)
    .accessibilityLabel(beschreibung)
  }
}

// MARK: - Kopf

/// App-Kopf wie im Web (`ui_kopf()`): Titel H1 linksbündig, optional
/// Untertitel, rechts eine kleine Hauptaktion und Symbol-Knöpfe. Den
/// Zurück-Weg übernimmt die Navigationsleiste (iOS-Konvention); auf
/// Unterseiten den Kopf als ersten Inhalt der Liste/ScrollView setzen.
struct MhKopf<Symbole: View, Hauptaktion: View>: View {
  let titel: String
  var untertitel: String?
  @ViewBuilder var symbole: () -> Symbole
  @ViewBuilder var hauptaktion: () -> Hauptaktion

  init(
    _ titel: String,
    untertitel: String? = nil,
    @ViewBuilder symbole: @escaping () -> Symbole = { EmptyView() },
    @ViewBuilder hauptaktion: @escaping () -> Hauptaktion = { EmptyView() }
  ) {
    self.titel = titel
    self.untertitel = untertitel
    self.symbole = symbole
    self.hauptaktion = hauptaktion
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Mh.abstand1) {
      HStack(spacing: Mh.abstand2) {
        Text(titel)
          .mhText(.h1)
          .foregroundStyle(Mh.textStrong)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityAddTraits(.isHeader)
        hauptaktion()
        symbole()
      }
      if let untertitel {
        Text(untertitel).mhText(.small).foregroundStyle(Mh.textSecondary)
      }
    }
    .padding(.bottom, Mh.abstand3)
  }
}

// MARK: - Buttons

/// Die eine Hauptaktion einer Ansicht (`.btn-primary`).
struct MhHauptButtonStil: ButtonStyle {
  var klein = false
  var breit = false
  @Environment(\.isEnabled) private var aktiv

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .mhText(.button)
      .lineLimit(1)
      .padding(.horizontal, klein ? Mh.abstand3 : Mh.abstand4)
      .frame(minHeight: klein ? 36 : Mh.touch)
      .frame(maxWidth: breit ? .infinity : nil)
      .foregroundStyle(aktiv ? Mh.onPrimary : Mh.textDisabled)
      .background(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous)
          .fill(aktiv ? (configuration.isPressed ? Mh.primaryHover : Mh.primary) : Mh.surfaceSubtle)
      )
      .contentShape(Rectangle())
      .frame(minHeight: Mh.touch)
  }
}

/// Zweitaktion (`.btn-secondary`): transparent mit Haarlinie.
struct MhZweitButtonStil: ButtonStyle {
  var klein = false
  var breit = false
  @Environment(\.isEnabled) private var aktiv

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .mhText(.button)
      .lineLimit(1)
      .padding(.horizontal, klein ? Mh.abstand3 : Mh.abstand4)
      .frame(minHeight: klein ? 36 : Mh.touch)
      .frame(maxWidth: breit ? .infinity : nil)
      .foregroundStyle(aktiv ? Mh.textStrong : Mh.textDisabled)
      .background(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous)
          .fill(configuration.isPressed ? Mh.surfaceSubtle : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous)
          .stroke(aktiv ? Mh.borderStrong : Mh.border, lineWidth: 1)
      )
      .contentShape(Rectangle())
      .frame(minHeight: Mh.touch)
  }
}

/// Leise Aktion (`.btn-ghost`) bzw. Löschen (`.btn-danger`): nur Schrift.
struct MhTextButtonStil: ButtonStyle {
  var farbe: Color = Mh.link
  @Environment(\.isEnabled) private var aktiv

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .mhText(.button)
      .foregroundStyle(aktiv ? farbe : Mh.textDisabled)
      .opacity(configuration.isPressed ? 0.6 : 1)
      .frame(minHeight: Mh.touch)
      .contentShape(Rectangle())
  }
}

extension ButtonStyle where Self == MhTextButtonStil {
  static var mhLoeschen: MhTextButtonStil { MhTextButtonStil(farbe: Mh.danger) }
  static var mhText: MhTextButtonStil { MhTextButtonStil() }
}

extension ButtonStyle where Self == MhHauptButtonStil {
  static var mhHaupt: MhHauptButtonStil { MhHauptButtonStil() }
}

extension ButtonStyle where Self == MhZweitButtonStil {
  static var mhZweit: MhZweitButtonStil { MhZweitButtonStil() }
}

/// Inhalt eines Buttons: optional Symbol links, dann Text.
struct MhButtonInhalt: View {
  let text: String
  var symbol: String?
  var symbolGroesse: CGFloat = Mh.symbol

  init(_ text: String, symbol: String? = nil, symbolGroesse: CGFloat = Mh.symbol) {
    self.text = text
    self.symbol = symbol
    self.symbolGroesse = symbolGroesse
  }

  var body: some View {
    HStack(spacing: Mh.abstand2) {
      if let symbol { MhSymbol(symbol, groesse: symbolGroesse) }
      Text(text)
    }
  }
}

// MARK: - Segmentschalter, Reiter, Auswahl

/// Segmentschalter (`.segmented`) für 2–4 sich ausschließende Ansichten.
struct MhSegmente: View {
  let optionen: [String]
  @Binding var gewaehlt: Int

  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(optionen.enumerated()), id: \.offset) { index, text in
        let aktiv = index == gewaehlt
        Button {
          gewaehlt = index
        } label: {
          Text(text)
            .mhText(.label)
            .lineLimit(1)
            .foregroundStyle(aktiv ? Mh.textStrong : Mh.textSecondary)
            .padding(.horizontal, Mh.abstand3)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(
              RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(aktiv ? Mh.segmentOn : Color.clear)
                .shadow(color: aktiv ? Color.black.opacity(0.06) : .clear, radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(aktiv ? [.isSelected] : [])
      }
    }
    .padding(3)
    .background(RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).fill(Mh.surfaceSubtle))
    .overlay(RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).stroke(Mh.border, lineWidth: 1))
    .frame(minHeight: Mh.touch)
  }
}

/// Reiter (`.tabs`): aktiv Textfarbe + 2 pt Linie in primary, darunter Haarlinie.
struct MhReiter: View {
  let optionen: [String]
  @Binding var gewaehlt: Int

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: Mh.abstand5) {
        ForEach(Array(optionen.enumerated()), id: \.offset) { index, text in
          let aktiv = index == gewaehlt
          Button {
            gewaehlt = index
          } label: {
            Text(text)
              .mhText(.button)
              .foregroundStyle(aktiv ? Mh.textStrong : Mh.textSecondary)
              .padding(.vertical, Mh.abstand3)
              .frame(minHeight: Mh.touch)
              .overlay(alignment: .bottom) {
                Rectangle().fill(aktiv ? Mh.primary : Color.clear).frame(height: 2)
              }
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(aktiv ? [.isSelected] : [])
        }
      }
    }
    .overlay(alignment: .bottom) { Rectangle().fill(Mh.border).frame(height: 1) }
  }
}

/// Auswahl-Option (`.choice`): Haarlinie; gewählt `selectedBg` + `onSelected`.
struct MhAuswahl: View {
  let text: String
  let gewaehlt: Bool
  var punkt: Color?
  let aktion: () -> Void

  init(_ text: String, gewaehlt: Bool, punkt: Color? = nil, aktion: @escaping () -> Void) {
    self.text = text
    self.gewaehlt = gewaehlt
    self.punkt = punkt
    self.aktion = aktion
  }

  var body: some View {
    Button(action: aktion) {
      HStack(spacing: 6) {
        if let punkt { MhPunkt(farbe: punkt) }
        Text(text)
          .font(.custom(gewaehlt ? MhSchrift.medium : MhSchrift.regular, size: 14, relativeTo: .subheadline))
          .lineLimit(1)
      }
      .foregroundStyle(gewaehlt ? Mh.onSelected : Mh.text)
      .padding(.horizontal, Mh.abstand3)
      .frame(minHeight: 36)
      .background(
        RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous)
          .fill(gewaehlt ? Mh.selectedBg : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous)
          .stroke(gewaehlt ? Color.clear : Mh.borderStrong, lineWidth: 1)
      )
      .frame(minHeight: Mh.touch)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(gewaehlt ? [.isSelected] : [])
  }
}

// MARK: - Karten, Listen, Gruppen

/// Karte (`.card`) – nur für echte Objekte, z. B. einen Tagebucheintrag.
struct MhKarte<Inhalt: View>: View {
  var innen: CGFloat = Mh.abstand4
  @ViewBuilder var inhalt: () -> Inhalt

  init(innen: CGFloat = Mh.abstand4, @ViewBuilder inhalt: @escaping () -> Inhalt) {
    self.innen = innen
    self.inhalt = inhalt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0, content: inhalt)
      .padding(innen)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: Mh.radiusLg, style: .continuous).fill(Mh.surface))
      .overlay(RoundedRectangle(cornerRadius: Mh.radiusLg, style: .continuous).stroke(Mh.border, lineWidth: 1))
  }
}

/// Haarlinie zwischen Listenzeilen und Abschnitten.
struct MhTrennlinie: View {
  var body: some View {
    Rectangle().fill(Mh.border).frame(height: 1).accessibilityHidden(true)
  }
}

/// Listenzeile (`.list-row`): ab 52 pt, Symbol/Punkt links, Meta rechts, Pfeil.
struct MhListenZeile<Rechts: View>: View {
  let titel: String
  var untertitel: String?
  var meta: String?
  var symbol: String?
  var punkt: Color?
  var pfeil = false
  var titelFarbe: Color = Mh.textStrong
  @ViewBuilder var rechts: () -> Rechts

  init(
    _ titel: String,
    untertitel: String? = nil,
    meta: String? = nil,
    symbol: String? = nil,
    punkt: Color? = nil,
    pfeil: Bool = false,
    titelFarbe: Color = Mh.textStrong,
    @ViewBuilder rechts: @escaping () -> Rechts = { EmptyView() }
  ) {
    self.titel = titel
    self.untertitel = untertitel
    self.meta = meta
    self.symbol = symbol
    self.punkt = punkt
    self.pfeil = pfeil
    self.titelFarbe = titelFarbe
    self.rechts = rechts
  }

  var body: some View {
    HStack(spacing: Mh.abstand3) {
      if let symbol { MhSymbol(symbol).foregroundStyle(Mh.textSecondary) }
      if let punkt { MhPunkt(farbe: punkt) }
      VStack(alignment: .leading, spacing: 2) {
        Text(titel)
          .font(.custom(MhSchrift.medium, size: 16, relativeTo: .body))
          .foregroundStyle(titelFarbe)
        if let untertitel {
          Text(untertitel).mhText(.small).foregroundStyle(Mh.textSecondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if let meta {
        Text(meta).mhText(.small).monospacedDigit().foregroundStyle(Mh.textSecondary)
      }
      rechts()
      if pfeil {
        MhSymbol("MhChevronRight", groesse: 18).foregroundStyle(Mh.textTertiary)
      }
    }
    .padding(.vertical, Mh.abstand3)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
  }
}

/// Gruppenlabel (`.group-label`): Caption in Versalien, Dritttextfarbe.
struct MhGruppenLabel: View {
  let text: String
  var rechts: String?

  init(_ text: String, rechts: String? = nil) {
    self.text = text
    self.rechts = rechts
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(text.uppercased())
        .mhText(.caption)
        .foregroundStyle(Mh.textTertiary)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      if let rechts {
        Text(rechts).mhText(.small).foregroundStyle(Mh.textSecondary)
      }
    }
    .padding(.top, Mh.abstand6)
    .padding(.bottom, Mh.abstand2)
  }
}

// MARK: - Zahlen, Balken, Punkte

/// Statistik (`.stat-value` + `.stat-label`): Wert dünn in Textfarbe.
struct MhStat: View {
  let wert: String
  let label: String
  var einheit: String?

  init(_ wert: String, label: String, einheit: String? = nil) {
    self.wert = wert
    self.label = label
    self.einheit = einheit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(wert).mhText(.number).foregroundStyle(Mh.textStrong)
        if let einheit {
          Text(einheit).mhText(.small).foregroundStyle(Mh.textSecondary)
        }
      }
      Text(label).mhText(.small).foregroundStyle(Mh.textSecondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// Balken (`.bar`): 4 pt, Spur `dataTrack`, Füllung `data1/2/3`.
struct MhBalken: View {
  let anteil: Double
  var farbe: Color = Mh.data1

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Mh.dataTrack)
        Capsule().fill(farbe).frame(width: geo.size.width * min(max(anteil, 0), 1))
      }
    }
    .frame(height: 4)
    .accessibilityHidden(true)
  }
}

/// Punkt (`.dot`): 10 pt, kennzeichnet eine Kategorie – immer mit Text.
struct MhPunkt: View {
  let farbe: Color
  var groesse: CGFloat = 10

  var body: some View {
    Circle().fill(farbe).frame(width: groesse, height: groesse).accessibilityHidden(true)
  }
}

// MARK: - Marken, Hinweise, Leerzustand

/// Marke (`.chip`): Pille in `tint`, z. B. „Gewicht 9,3 kg“.
struct MhMarke: View {
  let text: String
  var symbol: String?

  init(_ text: String, symbol: String? = nil) {
    self.text = text
    self.symbol = symbol
  }

  var body: some View {
    HStack(spacing: 6) {
      if let symbol { MhSymbol(symbol, groesse: 14) }
      Text(text).mhText(.chip)
    }
    .foregroundStyle(Mh.onTint)
    .padding(.horizontal, 10)
    .frame(minHeight: 26)
    .background(Capsule().fill(Mh.tint))
  }
}

/// Kleines Hinweis-Badge (`.badge`), sparsam.
struct MhBadge: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .mhText(.caption)
      .foregroundStyle(Mh.onHighlight)
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
      .background(Capsule().fill(Mh.highlight))
  }
}

enum MhHinweisArt { case info, erfolg, warnung, fehler }

/// Hinweis (`.notice`): getönte Fläche, Symbol in Semantikfarbe, Text in Textfarbe.
struct MhHinweis: View {
  let text: String
  var titel: String?
  var art: MhHinweisArt = .info
  var symbol: String?

  init(_ text: String, titel: String? = nil, art: MhHinweisArt = .info, symbol: String? = nil) {
    self.text = text
    self.titel = titel
    self.art = art
    self.symbol = symbol
  }

  private var farben: (grund: Color, vorne: Color) {
    switch art {
    case .info: return (Mh.infoBg, Mh.infoFg)
    case .erfolg: return (Mh.successBg, Mh.successFg)
    case .warnung: return (Mh.warningBg, Mh.warningFg)
    case .fehler: return (Mh.errorBg, Mh.errorFg)
    }
  }

  private var standardSymbol: String {
    switch art {
    case .info: return "MhInfo"
    case .erfolg: return "MhCheck"
    case .warnung, .fehler: return "MhAlert"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: Mh.abstand3) {
      MhSymbol(symbol ?? standardSymbol).foregroundStyle(farben.vorne).padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        if let titel { Text(titel).mhText(.label).foregroundStyle(Mh.textStrong) }
        Text(text).mhText(.small).foregroundStyle(Mh.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, Mh.abstand4)
    .padding(.vertical, Mh.abstand3)
    .background(RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).fill(farben.grund))
    .accessibilityElement(children: .combine)
  }
}

/// Leerzustand (`.empty`): zentriert, Nebentext, ein Satz, ohne Emoji.
struct MhLeer<Aktion: View>: View {
  let text: String
  @ViewBuilder var aktion: () -> Aktion

  init(_ text: String, @ViewBuilder aktion: @escaping () -> Aktion = { EmptyView() }) {
    self.text = text
    self.aktion = aktion
  }

  var body: some View {
    VStack(spacing: Mh.abstand2) {
      Text(text)
        .mhText(.small)
        .foregroundStyle(Mh.textSecondary)
        .multilineTextAlignment(.center)
      aktion()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Mh.abstand4)
    .padding(.vertical, Mh.abstand8)
  }
}

/// Ladeanzeige in primary.
struct MhLaden: View {
  var body: some View {
    ProgressView().tint(Mh.primary).frame(maxWidth: .infinity, minHeight: 120)
  }
}

// MARK: - Formulare

/// Feld (`.field`): Label über dem Eingabefeld, Hinweis darunter.
struct MhFeld<Inhalt: View>: View {
  let label: String
  var zusatz: String?
  var hinweis: String?
  @ViewBuilder var inhalt: () -> Inhalt

  init(
    _ label: String, zusatz: String? = nil, hinweis: String? = nil,
    @ViewBuilder inhalt: @escaping () -> Inhalt
  ) {
    self.label = label
    self.zusatz = zusatz
    self.hinweis = hinweis
    self.inhalt = inhalt
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: Mh.abstand2) {
        Text(label).mhText(.label).foregroundStyle(Mh.textStrong)
        if let zusatz { Text(zusatz).mhText(.small).foregroundStyle(Mh.textSecondary) }
      }
      inhalt()
      if let hinweis {
        Text(hinweis).mhText(.small).foregroundStyle(Mh.textSecondary)
      }
    }
  }
}

/// Eingabefeld (`input`): 44 pt, Radius 10, Haarlinie `borderStrong`, Grund `fieldBg`.
struct MhFeldStil: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .mhText(.body)
      .foregroundStyle(Mh.text)
      .tint(Mh.primary)
      .padding(.horizontal, Mh.abstand3)
      .frame(minHeight: Mh.touch)
      .background(RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).fill(Mh.fieldBg))
      .overlay(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).stroke(Mh.borderStrong, lineWidth: 1))
  }
}

extension TextFieldStyle where Self == MhFeldStil {
  static var mh: MhFeldStil { MhFeldStil() }
}

/// Seitenrahmen: Grund `bg`, Seitenrand 16 pt.
extension View {
  func mhSeite() -> some View {
    self
      .padding(.horizontal, Mh.rand)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Mh.bg.ignoresSafeArea())
  }
}
