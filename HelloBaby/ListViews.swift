import SwiftUI

// MARK: - Reiter „Tag“

struct TagInhalt: View {

  let diary: String
  let schluessel: String
  @Binding var datum: Date
  let onMeldung: (String) -> Void
  let onNeuLaden: () async -> Void

  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var zeigeDatumswahl = false
  @State private var intern = 0

  private let api = ApiClient.shared

  var body: some View {
    VStack(spacing: 0) {
      HbBlaetterer(
        titel: HbDatum.anzeige(HbDatum.iso(datum)),
        untertitel: HbDatum.wochentag(datum),
        zurueck: "Vortag",
        weiter: "Folgetag",
        onZurueck: { verschiebe(-1) },
        onWeiter: { verschiebe(1) },
        onTitel: { zeigeDatumswahl = true })
        .padding(.horizontal, Mh.abstand2)
        .padding(.top, Mh.abstand1)
        .hbBreite()
      Group {
        if laedt {
          LadeAnsicht()
        } else if let fehler {
          FehlerAnsicht(text: "Der Tag konnte nicht geladen werden. \(fehler)") { intern += 1 }
        } else {
          ScrollView {
            Group {
              if eintraege.isEmpty {
                LeerAnsicht(text: "Keine Einträge an diesem Tag")
              } else {
                VStack(spacing: Mh.abstand3) {
                  ForEach(eintraege) { eintrag in
                    EntryCard(
                      entry: eintrag,
                      onGeloescht: { intern += 1 },
                      onMeldung: onMeldung)
                  }
                }
              }
            }
            .padding(.horizontal, Mh.rand)
            .padding(.top, Mh.abstand2)
            .padding(.bottom, Mh.abstand8)
            .hbBreite()
          }
          .refreshable { await onNeuLaden() }
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .task(id: "\(schluessel)/\(HbDatum.iso(datum))/\(intern)") { await laden() }
    .sheet(isPresented: $zeigeDatumswahl) {
      HbDatumswahl(datum: $datum)
    }
  }

  private func verschiebe(_ tage: Int) {
    datum = Calendar.current.date(byAdding: .day, value: tage, to: datum) ?? datum
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      let neu = try await api.getEntriesByDate(HbDatum.iso(datum), diary: diary)
      guard !Task.isCancelled else { return }
      eintraege = neu
    } catch {
      guard !Task.isCancelled else { return }
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }
}

// MARK: - Reiter „Monat“

struct MonatInhalt: View {

  let diary: String
  let schluessel: String
  let onMeldung: (String) -> Void
  let onNeuLaden: () async -> Void

  @State private var jahr = Calendar.current.component(.year, from: Date())
  @State private var monat = Calendar.current.component(.month, from: Date())
  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var intern = 0

  private let api = ApiClient.shared

  private var titel: String {
    let komponenten = DateComponents(year: jahr, month: monat, day: 1)
    guard let datum = Calendar.current.date(from: komponenten) else { return "" }
    return HbDatum.monatJahr(datum)
  }

  private var anzahl: String? {
    guard !laedt, fehler == nil else { return nil }
    return eintraege.count == 1 ? "1 Eintrag" : "\(eintraege.count) Einträge"
  }

  var body: some View {
    VStack(spacing: 0) {
      HbBlaetterer(
        titel: titel,
        untertitel: anzahl,
        zurueck: "Vormonat",
        weiter: "Folgemonat",
        onZurueck: { verschiebe(-1) },
        onWeiter: { verschiebe(1) })
        .padding(.horizontal, Mh.abstand2)
        .padding(.top, Mh.abstand1)
        .hbBreite()
      Group {
        if laedt {
          LadeAnsicht()
        } else if let fehler {
          FehlerAnsicht(text: "Der Monat konnte nicht geladen werden. \(fehler)") { intern += 1 }
        } else {
          ScrollView {
            Group {
              if eintraege.isEmpty {
                LeerAnsicht(text: "Keine Einträge in diesem Monat")
              } else {
                NachTagen(
                  gruppen: Self.gruppen(eintraege, neuesteZuerst: false),
                  onGeloescht: { intern += 1 },
                  onMeldung: onMeldung)
              }
            }
            .padding(.horizontal, Mh.rand)
            .padding(.bottom, Mh.abstand8)
            .hbBreite()
          }
          .refreshable { await onNeuLaden() }
        }
      }
      .frame(maxHeight: .infinity, alignment: .top)
    }
    .task(id: "\(schluessel)/\(jahr)-\(monat)/\(intern)") { await laden() }
  }

  /// Einträge je Tag, Tage auf- oder absteigend.
  static func gruppen(_ eintraege: [Entry], neuesteZuerst: Bool) -> [(datum: String, eintraege: [Entry])] {
    Dictionary(grouping: eintraege, by: \.kalenderDatum)
      .sorted { neuesteZuerst ? $0.key > $1.key : $0.key < $1.key }
      .map { (datum: $0.key, eintraege: $0.value) }
  }

  private func verschiebe(_ schritte: Int) {
    var neu = monat + schritte
    var jahrNeu = jahr
    if neu < 1 {
      neu = 12
      jahrNeu -= 1
    } else if neu > 12 {
      neu = 1
      jahrNeu += 1
    }
    eintraege = []
    monat = neu
    jahr = jahrNeu
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      let neu = try await api.getEntriesByMonth(year: jahr, month: monat, diary: diary)
      guard !Task.isCancelled else { return }
      eintraege = neu
    } catch {
      guard !Task.isCancelled else { return }
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }
}

// MARK: - Reiter „Favoriten“

struct FavoritenInhalt: View {

  let diary: String
  let schluessel: String
  let onMeldung: (String) -> Void
  let onNeuLaden: () async -> Void

  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var intern = 0

  private let api = ApiClient.shared

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: "Die Favoriten konnten nicht geladen werden. \(fehler)") { intern += 1 }
      } else {
        ScrollView {
          Group {
            if eintraege.isEmpty {
              LeerAnsicht(
                text: "Noch keine Favoriten",
                untertitel: "Markiere Einträge mit dem Stern, um sie hier zu sammeln.")
            } else {
              NachTagen(
                gruppen: MonatInhalt.gruppen(eintraege, neuesteZuerst: true),
                onGeloescht: { intern += 1 },
                onMeldung: onMeldung)
            }
          }
          .padding(.horizontal, Mh.rand)
          .padding(.bottom, Mh.abstand8)
          .hbBreite()
        }
        .refreshable { await onNeuLaden() }
      }
    }
    .task(id: "\(schluessel)/\(intern)") { await laden() }
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      let neu = try await api.getFavorites(diary: diary)
      guard !Task.isCancelled else { return }
      eintraege = neu
    } catch {
      guard !Task.isCancelled else { return }
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }
}

// MARK: - Gemeinsames

/// Eintragskarten unter einem Gruppenlabel je Tag.
private struct NachTagen: View {
  let gruppen: [(datum: String, eintraege: [Entry])]
  let onGeloescht: () -> Void
  let onMeldung: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(gruppen, id: \.datum) { gruppe in
        MhGruppenLabel(HbDatum.mitWochentag(gruppe.datum))
        VStack(spacing: Mh.abstand3) {
          ForEach(gruppe.eintraege) { eintrag in
            EntryCard(entry: eintrag, onGeloescht: onGeloescht, onMeldung: onMeldung)
          }
        }
      }
    }
  }
}
