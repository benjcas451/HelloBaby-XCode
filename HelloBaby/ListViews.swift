import SwiftUI

// MARK: - Tagesansicht

struct DayView: View {

  let initialDate: String?

  @State private var datum = Date()
  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var zeigeDatumswahl = false
  @State private var meldung: String?

  private let api = ApiClient.shared

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if eintraege.isEmpty {
        LeerAnsicht(symbol: "calendar", text: "Keine Einträge an diesem Tag.")
      } else {
        ScrollView {
          VStack(spacing: 12) {
            ForEach(eintraege) { eintrag in
              karte(eintrag)
            }
          }
          .padding()
        }
      }
    }
    .hbHintergrund()
    .navigationTitle(HbDatum.anzeige(Self.iso(datum)))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button { verschiebe(-1) } label: { Image(systemName: "chevron.left") }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button { verschiebe(1) } label: { Image(systemName: "chevron.right") }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button { zeigeDatumswahl = true } label: { Image(systemName: "calendar") }
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink(value: Ziel.create(initialDate: Self.iso(datum))) {
          Image(systemName: "plus")
        }
      }
    }
    .sheet(isPresented: $zeigeDatumswahl) {
      DatePicker("Datum", selection: $datum, displayedComponents: .date)
        .datePickerStyle(.graphical)
        .padding()
        .presentationDetents([.medium])
    }
    .onChange(of: datum) { _, _ in Task { await laden() } }
    .task {
      if let initialDate, let start = Self.datum(initialDate) {
        datum = start
      }
      await laden()
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

  private func karte(_ eintrag: Entry) -> some View {
    EntryCard(
      entry: eintrag,
      onGeloescht: { Task { await laden() } },
      onMeldung: { meldung = $0 })
  }

  private func verschiebe(_ tage: Int) {
    datum = Calendar.current.date(byAdding: .day, value: tage, to: datum) ?? datum
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      eintraege = try await api.getEntriesByDate(Self.iso(datum), diary: AppSettings.activeDiary)
    } catch {
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }

  static func iso(_ datum: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: datum)
  }

  static func datum(_ iso: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: iso)
  }
}

// MARK: - Monatsansicht

struct MonthView: View {

  @State private var jahr = Calendar.current.component(.year, from: Date())
  @State private var monat = Calendar.current.component(.month, from: Date())
  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var meldung: String?

  private let api = ApiClient.shared

  private var titel: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateFormat = "LLLL yyyy"
    let komponenten = DateComponents(year: jahr, month: monat, day: 1)
    guard let datum = Calendar.current.date(from: komponenten) else { return "" }
    return formatter.string(from: datum)
  }

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if eintraege.isEmpty {
        LeerAnsicht(symbol: "calendar", text: "Keine Einträge in diesem Monat.")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(gruppen, id: \.datum) { gruppe in
              Text(HbDatum.mitWochentag(gruppe.datum))
                .font(.subheadline.bold())
                .foregroundStyle(Hb.accentDeep)
                .padding(.top, 4)
              ForEach(gruppe.eintraege) { eintrag in
                EntryCard(
                  entry: eintrag,
                  onGeloescht: { Task { await laden() } },
                  onMeldung: { meldung = $0 })
              }
            }
            Text("Gesamt: \(eintraege.count) Einträge")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.top, 8)
          }
          .padding()
        }
      }
    }
    .hbHintergrund()
    .navigationTitle(titel)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button { verschiebe(-1) } label: { Image(systemName: "chevron.left") }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button { verschiebe(1) } label: { Image(systemName: "chevron.right") }
      }
    }
    .task { await laden() }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
  }

  private var gruppen: [(datum: String, eintraege: [Entry])] {
    let sortiert = Dictionary(grouping: eintraege, by: \.kalenderDatum)
      .sorted { $0.key < $1.key }
    return sortiert.map { (datum: $0.key, eintraege: $0.value) }
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
    monat = neu
    jahr = jahrNeu
    Task { await laden() }
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      eintraege = try await api.getEntriesByMonth(
        year: jahr, month: monat, diary: AppSettings.activeDiary)
    } catch {
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }
}

// MARK: - Favoriten

struct FavoritesView: View {

  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var meldung: String?

  private let api = ApiClient.shared

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if eintraege.isEmpty {
        LeerAnsicht(symbol: "star", text: "Noch keine Favoriten markiert.")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(gruppen, id: \.datum) { gruppe in
              Text(HbDatum.mitWochentag(gruppe.datum))
                .font(.subheadline.bold())
                .foregroundStyle(Hb.accentDeep)
                .padding(.top, 4)
              ForEach(gruppe.eintraege) { eintrag in
                EntryCard(
                  entry: eintrag,
                  onGeloescht: { Task { await laden() } },
                  onMeldung: { meldung = $0 })
              }
            }
          }
          .padding()
        }
      }
    }
    .hbHintergrund()
    .navigationTitle("Favoriten")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await laden() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    .task { await laden() }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
  }

  private var gruppen: [(datum: String, eintraege: [Entry])] {
    let sortiert = Dictionary(grouping: eintraege, by: \.kalenderDatum)
      .sorted { $0.key > $1.key }
    return sortiert.map { (datum: $0.key, eintraege: $0.value) }
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      eintraege = try await api.getFavorites(diary: AppSettings.activeDiary)
    } catch {
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }
}
