import SwiftUI
import UIKit

// ============================================================================
// App-eigene Bausteine auf Grundlage von „Minze & Honig 2.0“ (MhTheme.swift,
// MhBausteine.swift). Farben nur über die Rollen in `Mh`.
// ============================================================================

// MARK: - Datum und Zahlen

/// Deutsche Datumsformate (dd.MM.yyyy) wie im Web.
enum HbDatum {
  static func anzeige(_ isoDatum: String) -> String {
    formatiert(isoDatum, muster: "dd.MM.yyyy")
  }

  static func mitWochentag(_ isoDatum: String) -> String {
    formatiert(isoDatum, muster: "EEEE, dd.MM.yyyy")
  }

  /// Wochentag allein („Montag“).
  static func wochentag(_ datum: Date) -> String {
    schreiber("EEEE").string(from: datum)
  }

  /// Monat und Jahr („November 2026“).
  static func monatJahr(_ datum: Date) -> String {
    schreiber("LLLL yyyy").string(from: datum)
  }

  /// Tag des Eintrags als `yyyy-MM-dd`.
  static func iso(_ datum: Date) -> String {
    leser().string(from: datum)
  }

  static func datum(_ iso: String) -> Date? {
    leser().date(from: iso)
  }

  /// Uhrzeit „07:01“ aus `created_at` (Server „2026-11-15 07:01:00“,
  /// lokal ISO 8601 „2026-11-15T07:01:00.000“).
  static func uhrzeit(_ createdAt: String) -> String {
    guard let treffer = createdAt.range(of: "[ T][0-9]{2}:[0-9]{2}", options: .regularExpression)
    else { return "" }
    return String(createdAt[treffer].dropFirst())
  }

  private static func formatiert(_ isoDatum: String, muster: String) -> String {
    guard let datum = leser().date(from: isoDatum) else { return isoDatum }
    return schreiber(muster).string(from: datum)
  }

  private static func leser() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }

  private static func schreiber(_ muster: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateFormat = muster
    return formatter
  }
}

/// Zahl in deutscher Schreibweise („9.3“ → „9,3“).
func hbDeutscheZahl(_ wert: String) -> String {
  wert.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: ",")
}

/// Die Zahlenfelder eines Eintrags als Marken-Texte („Gewicht 8,4 kg“).
func hbZahlenMarken(_ felder: [String: String], diary: Diary?) -> [String] {
  (diary?.fields ?? []).filter(\.numeric).compactMap { feld in
    let wert = (felder[feld.key] ?? "").trimmingCharacters(in: .whitespaces)
    guard !wert.isEmpty, wert != "0" else { return nil }
    let einheit = feld.unit.isEmpty ? "" : " \(feld.unit)"
    return "\(feld.label) \(hbDeutscheZahl(wert))\(einheit)"
  }
}

// MARK: - Meldungen

/// Kurze Meldung („Eintrag gespeichert“), die auch dann noch zu sehen ist,
/// wenn sich die auslösende Ansicht gleich schließt. Angezeigt wird sie als
/// Toast über der ganzen App (siehe `HelloBabyApp`).
final class AppMeldung: ObservableObject {

  static let shared = AppMeldung()

  @Published private(set) var text: String?

  private var ausblenden: Task<Void, Never>?

  func zeige(_ neu: String) {
    text = neu
    UIAccessibility.post(notification: .announcement, argument: neu)
    ausblenden?.cancel()
    ausblenden = Task {
      try? await Task.sleep(nanoseconds: 2_600_000_000)
      guard !Task.isCancelled else { return }
      text = nil
    }
  }
}

/// Toast (`.toast`): dunkel auf hell bzw. hell auf dunkel, unten mittig.
struct HbToast: View {
  let text: String

  var body: some View {
    Text(text)
      .mhText(.label)
      .multilineTextAlignment(.center)
      .foregroundStyle(Mh.bg)
      .padding(.horizontal, Mh.abstand4)
      .padding(.vertical, Mh.abstand3)
      .background(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).fill(Mh.textStrong)
      )
      .shadow(color: Color.black.opacity(0.08), radius: 10, y: 6)
      .padding(.horizontal, Mh.rand)
      .padding(.bottom, Mh.abstand6)
      .accessibilityHidden(true)
  }
}

// MARK: - Layout-Helfer

extension View {
  /// Höchstbreite für Inhalte (`--width-app`), auf dem iPad mittig.
  func hbBreite() -> some View {
    self
      .frame(maxWidth: 640 + 2 * Mh.rand, alignment: .leading)
      .frame(maxWidth: .infinity)
  }

  /// Rahmen eines Eingabefelds (`input`): 44 pt, Radius 10, Haarlinie
  /// `borderStrong`, Grund `fieldBg`. Auch für Felder mit Einheit rechts.
  func hbFeldRahmen(mehrzeilig: Bool = false) -> some View {
    self
      .mhText(.body)
      .foregroundStyle(Mh.text)
      .tint(Mh.primary)
      .padding(.horizontal, Mh.abstand3)
      .padding(.vertical, mehrzeilig ? Mh.abstand2 : 0)
      .frame(minHeight: Mh.touch)
      .background(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous).fill(Mh.fieldBg)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Mh.radiusMd, style: .continuous)
          .stroke(Mh.borderStrong, lineWidth: 1)
      )
  }
}

/// Elemente nebeneinander; passen sie nicht in die Breite (große Schrift),
/// untereinander. Für Marken, Auswahl-Chips und Zweitbuttons.
struct HbReihe<Inhalt: View>: View {
  let abstand: CGFloat
  let inhalt: () -> Inhalt

  init(abstand: CGFloat = 6, @ViewBuilder inhalt: @escaping () -> Inhalt) {
    self.abstand = abstand
    self.inhalt = inhalt
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: abstand) { inhalt() }
      VStack(alignment: .leading, spacing: abstand) { inhalt() }
    }
  }
}

/// Kleines Abspielzeichen über Video-Vorschaubildern.
struct HbVideoMarke: View {
  var gross = false

  var body: some View {
    MhSymbol("MhPlay", groesse: gross ? 28 : 18)
      .foregroundStyle(Color.white)
      .frame(width: gross ? 56 : 32, height: gross ? 56 : 32)
      .background(Circle().fill(Color.black.opacity(0.54)))
      .accessibilityHidden(true)
  }
}

/// Blätterzeile „‹ Titel ›“; der Titel öffnet optional eine Auswahl (Datum).
struct HbBlaetterer: View {
  let titel: String
  var untertitel: String?
  let zurueck: String
  let weiter: String
  let onZurueck: () -> Void
  let onWeiter: () -> Void
  var onTitel: (() -> Void)?

  var body: some View {
    HStack(spacing: 0) {
      MhSymbolButton("MhBack", beschreibung: zurueck, aktion: onZurueck)
      if let onTitel {
        Button(action: onTitel) { beschriftung }
          .buttonStyle(.plain)
          .accessibilityHint("Datum wählen")
      } else {
        beschriftung
      }
      MhSymbolButton("MhChevronRight", beschreibung: weiter, aktion: onWeiter)
    }
  }

  private var beschriftung: some View {
    VStack(spacing: 0) {
      Text(titel)
        .mhText(.h3)
        .monospacedDigit()
        .foregroundStyle(Mh.textStrong)
      if let untertitel {
        Text(untertitel).mhText(.small).foregroundStyle(Mh.textSecondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, minHeight: Mh.touch)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }
}

/// Datumsauswahl als Blatt (iOS-Kalender), „Fertig“ schließt.
struct HbDatumswahl: View {
  @Binding var datum: Date
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        DatePicker("Datum", selection: $datum, displayedComponents: .date)
          .datePickerStyle(.graphical)
          .tint(Mh.primary)
          .padding(.horizontal, Mh.rand)
      }
      .navigationTitle("Datum wählen")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Fertig") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationBackground(Mh.surfaceRaised)
  }
}

/// Infotext als Blatt (Aufbau der API, Aufbau der Datenbank).
struct HbTextBlatt: View {
  let titel: String
  let text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView {
        Text(text)
          .mhText(.small)
          .foregroundStyle(Mh.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, Mh.rand)
          .padding(.bottom, Mh.abstand8)
          .hbBreite()
      }
      .background(Mh.bg.ignoresSafeArea())
      .navigationTitle(titel)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Schließen") { dismiss() }
        }
      }
    }
  }
}

// MARK: - Zustands-Ansichten

struct LadeAnsicht: View {
  var body: some View {
    MhLaden()
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

struct FehlerAnsicht: View {
  let text: String
  var erneut: () -> Void

  var body: some View {
    VStack(spacing: Mh.abstand4) {
      MhHinweis(text, art: .fehler)
      Button(action: erneut) {
        MhButtonInhalt("Erneut versuchen", symbol: "MhRefresh", symbolGroesse: 18)
      }
      .buttonStyle(.mhZweit)
    }
    .padding(.horizontal, Mh.rand)
    .padding(.vertical, Mh.abstand8)
    .hbBreite()
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

struct LeerAnsicht: View {
  let text: String
  var untertitel: String?

  var body: some View {
    VStack(spacing: 0) {
      MhLeer(text)
      if let untertitel {
        Text(untertitel)
          .mhText(.small)
          .foregroundStyle(Mh.textTertiary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Mh.abstand4)
          .padding(.top, -Mh.abstand6)
      }
    }
    .frame(maxWidth: .infinity)
  }
}

/// Hinweis über dem Inhalt: Verbindung weg, App weiter benutzbar.
struct OfflineBanner: View {
  /// Grund der abgebrochenen Verbindung; nil heisst „wieder online, aber es
  /// wartet noch etwas auf die Übertragung“.
  let grund: String?
  let ausstehend: Int

  var body: some View {
    MhHinweis(
      untertitel, titel: titel, art: .warnung,
      symbol: grund == nil ? "MhUpload" : "MhCloudOff")
  }

  private var titel: String {
    guard let grund else { return "Übertragung läuft" }
    return "Offline – \(grund)"
  }

  private var untertitel: String {
    guard ausstehend > 0 else {
      return "Angezeigt wird der zuletzt geladene Stand."
    }
    if ausstehend == 1 {
      return "Ein Eintrag wartet auf die Übertragung und geht raus, sobald die Verbindung steht."
    }
    return "\(ausstehend) Einträge warten auf die Übertragung und gehen raus, "
      + "sobald die Verbindung steht."
  }
}
