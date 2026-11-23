import SwiftUI

/// Reiter der Hauptansicht – wie im Web-HelloBaby.
enum Reiter: Int, CaseIterable {
  case start, tag, monat, favoriten, galerie

  var titel: String {
    switch self {
    case .start: return "Start"
    case .tag: return "Tag"
    case .monat: return "Monat"
    case .favoriten: return "Favoriten"
    case .galerie: return "Galerie"
    }
  }
}

/// Hauptansicht wie im Web-HelloBaby: Kopf „Hello <Name>!“ mit der einen
/// Hauptaktion „+ Eintrag“ und den Einstellungen als Symbol,
/// Tagebuch-Wahl als Segmentschalter, darunter die Reiter Start, Tag, Monat,
/// Favoriten und Galerie.
struct HomeView: View {

  @Binding var pfad: [Ziel]

  @State private var diary = AppSettings.activeDiary
  @State private var reiter: Reiter = .start
  /// Tag im Reiter „Tag“; bleibt beim Wechsel der Reiter erhalten.
  @State private var tagDatum = Date()
  @State private var letzterZufall: String?
  /// Zählt jedes Neuladen; 0 heißt: die Warteschlange wurde noch nicht
  /// abgearbeitet, die Reiter laden noch nicht.
  @State private var ladeZaehler = 0
  @State private var meldung: String?

  @ObservedObject private var offline = OfflineStatus.shared
  @Environment(\.scenePhase) private var szenenPhase

  private let api = ApiClient.shared

  private static let tagebuecher = ["schwangerschaft", "entwicklung"]

  /// Ändert sich bei jedem Neuladen und bei einem anderen Tagebuch.
  private var schluessel: String { "\(diary)/\(ladeZaehler)" }

  var body: some View {
    VStack(spacing: 0) {
      kopf
      // Offline-Hinweis über allem: weiterarbeiten geht, der Stand ist aber
      // noch nicht beim Server.
      if offline.grund != nil || offline.ausstehend > 0 {
        OfflineBanner(grund: offline.grund, ausstehend: offline.ausstehend)
          .padding(.horizontal, Mh.rand)
          .padding(.top, Mh.abstand3)
          .hbBreite()
      }
      Group {
        if ladeZaehler == 0 {
          LadeAnsicht()
        } else {
          inhalt
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .background(Mh.bg.ignoresSafeArea())
    // Beschriftet den Zurück-Knopf der Unterseiten; die Leiste selbst
    // braucht die Hauptansicht nicht, der Kopf steht im Inhalt.
    .navigationTitle("Übersicht")
    .toolbar(.hidden, for: .navigationBar)
    .onChange(of: diary) { _, neu in
      AppSettings.activeDiary = neu
    }
    .task(id: pfad.isEmpty) {
      // Beim ersten Anzeigen und nach jeder Rückkehr neu laden.
      if pfad.isEmpty { await aktualisieren() }
    }
    // Rückkehr aus dem Hintergrund: nachladen und dabei die Warteschlange
    // abarbeiten – zwischendurch kann die Verbindung wiedergekommen sein,
    // ohne dass die Wache lief.
    .onChange(of: szenenPhase) { _, neu in
      if neu == .active { Task { await aktualisieren() } }
    }
    .onReceive(Verbindungswache.shared.wiederVerbunden) { _ in
      Task { await aktualisieren() }
    }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
  }

  // MARK: - Kopf

  private var kopf: some View {
    VStack(alignment: .leading, spacing: Mh.abstand2) {
      MhKopf(
        "Hello \(AppSettings.appName)!",
        symbole: {
          // Immer erreichbar – auch ohne Verbindung.
          MhSymbolButton("MhSliders", beschreibung: "Einstellungen") {
            pfad.append(.settings)
          }
          .padding(.trailing, -Mh.abstand3)
        },
        hauptaktion: {
          Button {
            pfad.append(.create(initialDate: reiter == .tag ? HbDatum.iso(tagDatum) : nil))
          } label: {
            MhButtonInhalt("Eintrag", symbol: "MhPlus", symbolGroesse: 16)
          }
          .buttonStyle(MhHauptButtonStil(klein: true))
          .accessibilityLabel("Neuer Eintrag")
        })
      MhSegmente(
        optionen: Self.tagebuecher.map { kDiaries[$0]?.label ?? $0 },
        gewaehlt: Binding(
          get: { Self.tagebuecher.firstIndex(of: diary) ?? 0 },
          set: { diary = Self.tagebuecher[$0] }))
      MhReiter(
        optionen: Reiter.allCases.map(\.titel),
        gewaehlt: Binding(
          get: { reiter.rawValue },
          set: { reiter = Reiter(rawValue: $0) ?? .start }))
    }
    .padding(.horizontal, Mh.rand)
    .padding(.top, Mh.abstand3)
    .hbBreite()
  }

  // MARK: - Inhalt der Reiter

  @ViewBuilder
  private var inhalt: some View {
    switch reiter {
    case .start:
      StartInhalt(
        diary: diary,
        schluessel: schluessel,
        pfad: $pfad,
        letzterZufall: $letzterZufall,
        onReiter: { reiter = $0 },
        onZufallstag: { tag in
          tagDatum = tag
          reiter = .tag
        },
        onMeldung: { meldung = $0 },
        onNeuLaden: { await aktualisieren() })
    case .tag:
      TagInhalt(
        diary: diary, schluessel: schluessel, datum: $tagDatum,
        onMeldung: { meldung = $0 }, onNeuLaden: { await aktualisieren() })
    case .monat:
      MonatInhalt(
        diary: diary, schluessel: schluessel,
        onMeldung: { meldung = $0 }, onNeuLaden: { await aktualisieren() })
    case .favoriten:
      FavoritenInhalt(
        diary: diary, schluessel: schluessel,
        onMeldung: { meldung = $0 }, onNeuLaden: { await aktualisieren() })
    case .galerie:
      ImageFeedView(
        diary: diary, schluessel: schluessel, onNeuLaden: { await aktualisieren() })
    }
  }

  /// Erst das Liegengebliebene loswerden, dann laden: sonst zeigten die
  /// Reiter einen Serverstand ohne die eigenen Einträge.
  private func aktualisieren() async {
    // Nur im Bildschirmfoto-Lauf (Launch-Argument), sonst ohne Wirkung.
    await Bildschirmfotodaten.vorbereiten()
    let verworfen = await api.nachholen()
    if !verworfen.isEmpty {
      meldung = verworfen.count == 1
        ? "Ein wartender Eintrag wurde vom Server abgelehnt: \(verworfen[0])"
        : "\(verworfen.count) wartende Einträge wurden vom Server abgelehnt."
    }
    ladeZaehler += 1
  }
}

// MARK: - Reiter „Start“

/// Start: Kurzinfo, die letzten drei Einträge, darunter „Stöbern“.
private struct StartInhalt: View {

  let diary: String
  let schluessel: String
  @Binding var pfad: [Ziel]
  @Binding var letzterZufall: String?
  let onReiter: (Reiter) -> Void
  let onZufallstag: (Date) -> Void
  let onMeldung: (String) -> Void
  let onNeuLaden: () async -> Void

  @State private var stats: StatsResult?
  @State private var zuletzt: [Entry] = []
  @State private var fehler: String?
  @State private var zufallLaeuft = false
  @State private var intern = 0

  private let api = ApiClient.shared

  var body: some View {
    Group {
      if let fehler {
        FehlerAnsicht(text: fehler) { intern += 1 }
      } else if stats == nil {
        LadeAnsicht()
      } else {
        ScrollView {
          liste
            .padding(.horizontal, Mh.rand)
            .padding(.bottom, Mh.abstand8)
            .hbBreite()
        }
        .refreshable { await onNeuLaden() }
      }
    }
    .task(id: "\(schluessel)/\(intern)") { await laden() }
  }

  private var kurzinfo: String {
    var teile: [String] = []
    if let titel = kDiaries[diary]?.title { teile.append(titel) }
    if let erster = stats?.first, !erster.isEmpty { teile.append("seit \(HbDatum.anzeige(erster))") }
    if let letzter = stats?.last, !letzter.isEmpty { teile.append("zuletzt \(HbDatum.anzeige(letzter))") }
    return teile.joined(separator: " · ")
  }

  private var liste: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(kurzinfo)
        .mhText(.small)
        .foregroundStyle(Mh.textSecondary)
        .padding(.top, Mh.abstand4)

      MhGruppenLabel("Zuletzt")
      if zuletzt.isEmpty {
        MhLeer("Noch keine Einträge") {
          Button("Ersten Eintrag anlegen") { pfad.append(.create(initialDate: nil)) }
            .buttonStyle(.mhText)
        }
      } else {
        VStack(spacing: Mh.abstand3) {
          ForEach(zuletzt) { eintrag in
            EntryCard(
              entry: eintrag, mitDatum: true,
              onGeloescht: { intern += 1 },
              onMeldung: onMeldung)
          }
        }
      }

      MhGruppenLabel("Stöbern")
      Button {
        zufallsTag()
      } label: {
        MhListenZeile(
          "Zufälligen Tag zeigen", meta: zufallLaeuft ? "Suche …" : nil,
          symbol: "MhShuffle", pfeil: true)
      }
      .buttonStyle(.plain)
      MhTrennlinie()
      Button {
        onReiter(.galerie)
      } label: {
        MhListenZeile("Alle Bilder", symbol: "MhImage", pfeil: true)
      }
      .buttonStyle(.plain)
      MhTrennlinie()
      Button {
        onReiter(.favoriten)
      } label: {
        MhListenZeile("Favoriten", symbol: "MhStar", pfeil: true)
      }
      .buttonStyle(.plain)
      // Nur der Server hebt Gelöschtes auf.
      if api.hatPapierkorb {
        MhTrennlinie()
        Button {
          pfad.append(.trash)
        } label: {
          MhListenZeile("Papierkorb", symbol: "MhTrash", pfeil: true)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func laden() async {
    fehler = nil
    do {
      let neu = try await api.getStats(diary: diary)
      let eintraege = try await letzteEintraege(letzter: neu.last, anzahl: 3)
      guard !Task.isCancelled else { return }
      stats = neu
      zuletzt = eintraege
    } catch {
      guard !Task.isCancelled else { return }
      fehler = error.localizedDescription
      stats = nil
    }
  }

  /// Die letzten `anzahl` Einträge: der Monat des letzten Eintrags, bei Bedarf
  /// auch der davor. Nutzt nur die vorhandene Monatsabfrage, damit Server,
  /// lokale Ablage und Offline-Zwischenstand gleich behandelt werden.
  private func letzteEintraege(letzter: String?, anzahl: Int) async throws -> [Entry] {
    guard let letzter, var monat = HbDatum.datum(letzter) else { return [] }
    var sammlung: [Entry] = []
    for _ in 0..<2 {
      let teile = Calendar.current.dateComponents([.year, .month], from: monat)
      sammlung += try await api.getEntriesByMonth(
        year: teile.year ?? 0, month: teile.month ?? 0, diary: diary)
      if sammlung.count >= anzahl { break }
      monat = Calendar.current.date(byAdding: .month, value: -1, to: monat) ?? monat
    }
    let sortiert = sammlung.sorted {
      ($0.kalenderDatum, $0.createdAt) > ($1.kalenderDatum, $1.createdAt)
    }
    return Array(sortiert.prefix(anzahl))
  }

  private func zufallsTag() {
    guard !zufallLaeuft else { return }
    zufallLaeuft = true
    Task {
      do {
        if let datum = try await api.getRandomDate(diary: diary, excludeDate: letzterZufall),
          let tag = HbDatum.datum(datum)
        {
          letzterZufall = datum
          onZufallstag(tag)
        } else {
          onMeldung("Noch keine Einträge vorhanden.")
        }
      } catch {
        onMeldung("Zufälliger Tag fehlgeschlagen: \(error.localizedDescription)")
      }
      zufallLaeuft = false
    }
  }
}
