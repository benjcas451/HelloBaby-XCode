import SwiftUI

/// Papierkorb des Servers: gelöschte Einträge der letzten Tage ansehen,
/// zurückholen oder endgültig entfernen.
///
/// Zeigt beide Tagebücher zugleich — wer etwas vermisst, soll nicht erst
/// umschalten müssen.
struct PapierkorbView: View {

  @State private var eintraege: [PapierkorbEintrag] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var meldung: String?
  /// Kennung des Eintrags, an dem gerade etwas läuft: sperrt die Knöpfe.
  @State private var inArbeit: String?
  @State private var endgueltig: PapierkorbEintrag?
  /// Medien ohne Eintrag, für die gerade das Tagebuch gewählt wird.
  @State private var tagebuchWahl: PapierkorbEintrag?

  private let api = ApiClient.shared

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if eintraege.isEmpty {
        LeerAnsicht(
          symbol: "trash",
          text: "Der Papierkorb ist leer.\nGelöschte Einträge bleiben 30 Tage hier liegen "
            + "und verschwinden danach endgültig.")
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(eintraege) { eintrag in
              karte(eintrag)
            }
          }
          .padding()
        }
      }
    }
    .hbHintergrund()
    .navigationTitle("Papierkorb")
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
    .confirmationDialog(
      "Endgültig löschen?",
      isPresented: .init(get: { endgueltig != nil }, set: { if !$0 { endgueltig = nil } }),
      titleVisibility: .visible
    ) {
      Button("Endgültig löschen", role: .destructive) {
        guard let eintrag = endgueltig else { return }
        ausfuehren(eintrag, erfolg: "Der Eintrag wurde endgültig gelöscht.") {
          try await api.papierkorbLoeschen(kennung: eintrag.kennung)
        }
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Der Eintrag wird samt Medien entfernt. Das lässt sich nicht rückgängig machen.")
    }
    .confirmationDialog(
      "In welches Tagebuch?",
      isPresented: .init(get: { tagebuchWahl != nil }, set: { if !$0 { tagebuchWahl = nil } }),
      titleVisibility: .visible
    ) {
      // Der Vorschlag des Servers zuerst.
      ForEach(tagebuchAuswahl, id: \.id) { diary in
        Button(diary.id == tagebuchWahl?.diaryVorschlag ? "\(diary.label) (Vorschlag)" : diary.label) {
          guard let eintrag = tagebuchWahl else { return }
          ausfuehren(eintrag, erfolg: "Die Medien wurden als Eintrag ohne Text wiederhergestellt.") {
            _ = try await api.papierkorbWiederherstellen(
              kennung: eintrag.kennung, diary: diary.id, vonName: AppSettings.selectedUser)
          }
        }
      }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Zu diesen Medien gibt es keinen Text mehr. Es entsteht ein Eintrag ohne Text.")
    }
  }

  /// Beide Tagebücher, das vorgeschlagene zuerst.
  private var tagebuchAuswahl: [Diary] {
    let vorschlag = tagebuchWahl?.diaryVorschlag
    return kDiaries.values.sorted {
      ($0.id == vorschlag ? 0 : 1, $0.label) < ($1.id == vorschlag ? 0 : 1, $1.label)
    }
  }

  private func karte(_ eintrag: PapierkorbEintrag) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(eintrag.titel)
        .font(.subheadline.bold())
        .foregroundStyle(Hb.accentDeep)
      if !eintrag.eintrag.vonName.isEmpty {
        Text("von \(eintrag.eintrag.vonName)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let diary = kDiaries[eintrag.diary] {
        ForEach(diary.fields, id: \.key) { feld in
          let wert = eintrag.eintrag.fields[feld.key] ?? ""
          if !wert.isEmpty, !(feld.numeric && wert == "0") {
            Text("\(feld.label): \(wert)\(feld.unit.isEmpty ? "" : " " + feld.unit)")
              .font(.subheadline)
          }
        }
      } else {
        Text(eintrag.ohneEintragText)
          .font(.subheadline)
      }
      if eintrag.medien > 0 {
        Text(eintrag.medienText).font(.subheadline)
      }
      Text(eintrag.fristText)
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 10) {
        if eintrag.wiederherstellbar {
          Button {
            if eintrag.diary.isEmpty {
              // Ohne Eintrag weiß niemand mehr, in welchem Tagebuch die
              // Medien standen.
              tagebuchWahl = eintrag
            } else {
              ausfuehren(eintrag, erfolg: "Der Eintrag wurde wiederhergestellt.") {
                _ = try await api.papierkorbWiederherstellen(kennung: eintrag.kennung)
              }
            }
          } label: {
            Label("Wiederherstellen", systemImage: "arrow.uturn.backward")
          }
          .buttonStyle(.borderedProminent)
        }
        Button(role: .destructive) {
          endgueltig = eintrag
        } label: {
          Label("Endgültig löschen", systemImage: "trash.slash")
        }
        .buttonStyle(.bordered)
        if inArbeit == eintrag.kennung {
          ProgressView().controlSize(.small)
        }
      }
      .font(.subheadline)
      .disabled(inArbeit != nil)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hbKarte()
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      eintraege = try await api.getPapierkorb()
    } catch {
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
  }

  /// Führt Wiederherstellen oder endgültiges Löschen aus und lädt danach neu.
  private func ausfuehren(
    _ eintrag: PapierkorbEintrag, erfolg: String, aktion: @escaping () async throws -> Void
  ) {
    guard inArbeit == nil else { return }
    inArbeit = eintrag.kennung
    Task {
      do {
        try await aktion()
        // Sofort aus der Liste nehmen; das Neuladen bestätigt es.
        eintraege.removeAll { $0.kennung == eintrag.kennung }
        meldung = erfolg
        await laden()
      } catch {
        meldung = "Fehler: \(error.localizedDescription)"
      }
      inArbeit = nil
    }
  }
}

// MARK: - Texte (ohne SwiftUI, damit sie sich prüfen lassen)

extension PapierkorbEintrag {

  /// Überschrift einer Karte: Tagebuch und Tag des Eintrags.
  var titel: String {
    let tag = eintrag.kalenderDatum
    let datum = tag.isEmpty ? "" : HbDatum.anzeige(tag)
    guard let diary = kDiaries[diary] else {
      return datum.isEmpty ? "Medien ohne Eintrag" : "Medien ohne Eintrag vom \(datum)"
    }
    return "\(diary.label): Eintrag vom \(datum)"
  }

  /// Hinweis auf Karten ohne Eintrag: was Wiederherstellen dort bedeutet.
  var ohneEintragText: String {
    wiederherstellbar
      ? "Zu diesen Medien gibt es keinen Text mehr. Wiederherstellen legt einen Eintrag ohne Text an."
      : "Der Ordner ist leer; hier gibt es nichts wiederherzustellen."
  }

  var medienText: String {
    let groesse = String(
      format: "%.1f MB", locale: Locale(identifier: "de_DE"), Double(bytes) / 1_048_576)
    return medien == 1 ? "1 Foto/Video (\(groesse))" : "\(medien) Fotos/Videos (\(groesse))"
  }

  /// „Gelöscht am … · wird am … endgültig entfernt (noch n Tage)“.
  var fristText: String {
    let leser = DateFormatter()
    leser.locale = Locale(identifier: "en_US_POSIX")
    leser.dateFormat = "yyyy-MM-dd HH:mm:ss"
    var wann = geloescht
    if let datum = leser.date(from: geloescht) {
      leser.dateFormat = "dd.MM.yyyy HH:mm"
      wann = leser.string(from: datum)
    }
    let tage = tageUebrig == 1 ? "noch 1 Tag" : "noch \(tageUebrig) Tage"
    return "Gelöscht am \(wann) · wird am \(HbDatum.anzeige(verfaellt)) endgültig entfernt (\(tage))"
  }
}
