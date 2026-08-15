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

  private let api = ApiClient.shared

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
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
