import SwiftUI

/// Startbildschirm: Tagebuch-Umschalter, Statistik-Karte und die sechs
/// Aktions-Buttons – 1:1 wie die Flutter-App.
struct HomeView: View {

  @Binding var pfad: [Ziel]

  @State private var diary = AppSettings.activeDiary
  @State private var stats: StatsResult?
  @State private var fehler: String?
  @State private var laedt = true
  @State private var zufallLaeuft = false
  @State private var letzterZufall: String?
  @State private var meldung: String?

  @ObservedObject private var offline = OfflineStatus.shared
  @Environment(\.scenePhase) private var szenenPhase

  private let api = ApiClient.shared

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        // Offline-Hinweis über allem: der Nutzer soll sofort sehen, dass er
        // zwar weiterarbeiten kann, der Stand aber noch nicht beim Server ist.
        if offline.grund != nil || offline.ausstehend > 0 {
          OfflineBanner(grund: offline.grund, ausstehend: offline.ausstehend)
        }
        Picker("Tagebuch", selection: $diary) {
          Text("Schwangerschaft").tag("schwangerschaft")
          Text("Entwicklung").tag("entwicklung")
        }
        .pickerStyle(.segmented)

        if laedt {
          ProgressView().padding(.vertical, 40)
        } else if let fehler {
          FehlerAnsicht(text: fehler) { Task { await laden() } }
            .frame(minHeight: 180)
        } else {
          statsKarte
        }

        VStack(spacing: 10) {
          aktion("Eintrag erstellen", symbol: "plus.circle", farbe: Hb.aktionErstellen) {
            pfad.append(.create(initialDate: nil))
          }
          aktion("Tagesansicht", symbol: "calendar", farbe: Hb.aktionTag) {
            pfad.append(.day(initialDate: nil))
          }
          aktion("Monatsansicht", symbol: "calendar.badge.clock", farbe: Hb.aktionMonat) {
            pfad.append(.month)
          }
          aktion(
            zufallLaeuft ? "Suche…" : "Zufälliger Tag",
            symbol: "shuffle", farbe: Hb.aktionZufall
          ) {
            zufallsTag()
          }
          aktion("Favoriten", symbol: "star.fill", farbe: Hb.aktionFavoriten) {
            pfad.append(.favorites)
          }
          aktion("Galerie", symbol: "photo.on.rectangle", farbe: Hb.aktionGalerie) {
            pfad.append(.imageFeed)
          }
        }
      }
      .padding()
    }
    .hbHintergrund()
    .navigationTitle("Hello \(AppSettings.appName)! 🍼")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await laden() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          pfad.append(.settings)
        } label: {
          Image(systemName: "gearshape")
        }
      }
    }
    .onChange(of: diary) { _, neu in
      AppSettings.activeDiary = neu
      Task { await laden() }
    }
    .task(id: pfad.isEmpty) {
      // Beim ersten Anzeigen und nach jeder Rückkehr neu laden.
      if pfad.isEmpty { await laden() }
    }
    // Rückkehr aus dem Hintergrund: nachladen und dabei die Warteschlange
    // abarbeiten – zwischendurch kann die Verbindung wiedergekommen sein,
    // ohne dass die Wache lief.
    .onChange(of: szenenPhase) { _, neu in
      if neu == .active { Task { await laden() } }
    }
    .onReceive(Verbindungswache.shared.wiederVerbunden) { _ in
      Task { await laden() }
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

  private var statsKarte: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(kDiaries[diary]?.title ?? "")
        .font(.headline)
      Divider()
      zeile("Erster Eintrag", stats?.first ?? "–")
      zeile("Letzter Eintrag", stats?.last ?? "–")
      zeile("Heute", HbDatum.anzeige(Self.heuteIso()))
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hbKarte()
  }

  private func zeile(_ links: String, _ rechts: String) -> some View {
    HStack {
      Text(links).foregroundStyle(.secondary)
      Spacer()
      Text(rechts).bold()
    }
    .font(.subheadline)
  }

  private func aktion(
    _ titel: String, symbol: String, farbe: Color, wirkung: @escaping () -> Void
  ) -> some View {
    Button(action: wirkung) {
      HStack {
        Image(systemName: symbol)
        Text(titel).bold()
      }
      .frame(maxWidth: .infinity, minHeight: 52)
    }
    .background(farbe)
    .foregroundStyle(Hb.vordergrund(fuer: farbe))
    .clipShape(RoundedRectangle(cornerRadius: 16))
  }

  private func laden() async {
    laedt = stats == nil
    fehler = nil
    // Erst das Liegengebliebene loswerden, dann laden: sonst zeigte die
    // Statistik einen Serverstand ohne die eigenen Einträge.
    let verworfen = await api.nachholen()
    if !verworfen.isEmpty {
      meldung = verworfen.count == 1
        ? "Ein wartender Eintrag wurde vom Server abgelehnt: \(verworfen[0])"
        : "\(verworfen.count) wartende Einträge wurden vom Server abgelehnt."
    }
    do {
      stats = try await api.getStats(diary: diary)
    } catch {
      fehler = error.localizedDescription
      stats = nil
    }
    laedt = false
  }

  private func zufallsTag() {
    guard !zufallLaeuft else { return }
    zufallLaeuft = true
    Task {
      do {
        if let datum = try await api.getRandomDate(diary: diary, excludeDate: letzterZufall) {
          letzterZufall = datum
          pfad.append(.day(initialDate: datum))
        } else {
          meldung = "Noch keine Einträge vorhanden."
        }
      } catch {
        meldung = "Zufälliger Tag fehlgeschlagen: \(error.localizedDescription)"
      }
      zufallLaeuft = false
    }
  }

  private static func heuteIso() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
  }
}

/// Hinweisleiste über dem Inhalt: Verbindung weg, App weiter benutzbar.
struct OfflineBanner: View {
  /// Grund der abgebrochenen Verbindung; nil heisst „wieder online, aber es
  /// wartet noch etwas auf die Übertragung“.
  let grund: String?
  let ausstehend: Int

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: grund == nil ? "arrow.up.circle" : "wifi.slash")
        .font(.system(size: 16, weight: .semibold))
      VStack(alignment: .leading, spacing: 2) {
        Text(titel).font(.subheadline.bold())
        Text(untertitel).font(.caption)
      }
      Spacer(minLength: 0)
    }
    .foregroundStyle(Hb.hinweisText)
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Hb.hinweisFlaeche)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var titel: String {
    guard let grund else { return "Übertragung läuft" }
    return "Offline-Modus – \(grund)"
  }

  private var untertitel: String {
    guard ausstehend > 0 else {
      return "Angezeigt wird der zuletzt geladene Stand."
    }
    let was = ausstehend == 1 ? "Ein Eintrag wartet" : "\(ausstehend) Einträge warten"
    return "\(was) auf die Übertragung und geht raus, sobald die Verbindung steht."
  }
}
