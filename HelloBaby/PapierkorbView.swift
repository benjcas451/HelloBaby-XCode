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
        FehlerAnsicht(text: "Der Papierkorb konnte nicht geladen werden. \(fehler)") {
          Task { await laden() }
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: Mh.abstand3) {
            Text("Gelöschte Einträge bleiben 30 Tage hier und verschwinden danach endgültig.")
              .mhText(.small)
              .foregroundStyle(Mh.textSecondary)
            if eintraege.isEmpty {
              LeerAnsicht(text: "Der Papierkorb ist leer")
            } else {
              ForEach(eintraege) { eintrag in
                karte(eintrag)
              }
            }
          }
          .padding(.horizontal, Mh.rand)
          .padding(.top, Mh.abstand1)
          .padding(.bottom, Mh.abstand8)
          .hbBreite()
        }
        .refreshable { await laden() }
      }
    }
    .background(Mh.bg.ignoresSafeArea())
    .navigationTitle("Papierkorb")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await laden() }
        } label: {
          MhSymbol("MhRefresh")
        }
        .accessibilityLabel("Neu laden")
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
      titleVisibility: .visible,
      // Der Eintrag kommt über `presenting` in die Aktion: Beim Antippen ist
      // der Zustand unter Umständen schon wieder geleert.
      presenting: endgueltig
    ) { eintrag in
      Button("Endgültig löschen", role: .destructive) {
        ausfuehren(eintrag, erfolg: "Eintrag endgültig gelöscht") {
          try await api.papierkorbLoeschen(kennung: eintrag.kennung)
        }
      }
      Button("Abbrechen", role: .cancel) {}
    } message: { _ in
      Text("Der Eintrag wird samt Medien entfernt. Das lässt sich nicht rückgängig machen.")
    }
    .confirmationDialog(
      "In welches Tagebuch?",
      isPresented: .init(get: { tagebuchWahl != nil }, set: { if !$0 { tagebuchWahl = nil } }),
      titleVisibility: .visible,
      presenting: tagebuchWahl
    ) { eintrag in
      // Der Vorschlag des Servers zuerst.
      ForEach(tagebuchAuswahl(fuer: eintrag), id: \.id) { diary in
        Button(diary.id == eintrag.diaryVorschlag ? "\(diary.label) (Vorschlag)" : diary.label) {
          ausfuehren(eintrag, erfolg: "Medien als Eintrag ohne Text wiederhergestellt") {
            _ = try await api.papierkorbWiederherstellen(
              kennung: eintrag.kennung, diary: diary.id, vonName: AppSettings.selectedUser)
          }
        }
      }
      Button("Abbrechen", role: .cancel) {}
    } message: { _ in
      Text("Zu diesen Medien gibt es keinen Text mehr. Es entsteht ein Eintrag ohne Text.")
    }
  }

  /// Beide Tagebücher, das vorgeschlagene zuerst.
  private func tagebuchAuswahl(fuer eintrag: PapierkorbEintrag) -> [Diary] {
    let vorschlag = eintrag.diaryVorschlag
    return kDiaries.values.sorted {
      ($0.id == vorschlag ? 0 : 1, $0.label) < ($1.id == vorschlag ? 0 : 1, $1.label)
    }
  }

  private func karte(_ eintrag: PapierkorbEintrag) -> some View {
    let diary = kDiaries[eintrag.diary]
    let zeile = eintrag.eintrag
    return MhKarte {
      VStack(alignment: .leading, spacing: Mh.abstand2) {
        VStack(alignment: .leading, spacing: 2) {
          Text(eintrag.titel)
            .mhText(.h3)
            .foregroundStyle(Mh.textStrong)
          if !zeile.vonName.isEmpty {
            Text("von \(zeile.vonName)")
              .mhText(.small)
              .foregroundStyle(Mh.textSecondary)
          }
        }

        if let diary {
          ForEach(diary.fields.filter(\.textarea), id: \.key) { feld in
            let wert = zeile.fields[feld.key] ?? ""
            if !wert.isEmpty {
              Text(wert)
                .mhText(.body)
                .foregroundStyle(Mh.text)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          let zahlen = hbZahlenMarken(zeile.fields, diary: diary)
          if !zahlen.isEmpty {
            HbReihe {
              ForEach(zahlen, id: \.self) { MhMarke($0) }
            }
          }
        } else {
          Text(eintrag.ohneEintragText)
            .mhText(.small)
            .foregroundStyle(Mh.text)
        }
        if eintrag.medien > 0 {
          Text(eintrag.medienText)
            .mhText(.small)
            .foregroundStyle(Mh.textSecondary)
        }
        // Vorschaubilder: zeigen, was wiederhergestellt oder gelöscht wird.
        if !eintrag.dateien.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(eintrag.dateien, id: \.self) { datei in
                vorschau(eintrag, datei)
              }
            }
          }
        }
        Text(eintrag.fristText)
          .mhText(.small)
          .foregroundStyle(Mh.textTertiary)

        HbReihe(abstand: Mh.abstand2) {
          if eintrag.wiederherstellbar {
            Button {
              if eintrag.diary.isEmpty {
                // Ohne Eintrag weiß niemand mehr, in welchem Tagebuch die
                // Medien standen.
                tagebuchWahl = eintrag
              } else {
                ausfuehren(eintrag, erfolg: "Eintrag wiederhergestellt") {
                  _ = try await api.papierkorbWiederherstellen(kennung: eintrag.kennung)
                }
              }
            } label: {
              MhButtonInhalt("Wiederherstellen", symbol: "MhUndo", symbolGroesse: 18)
            }
            .buttonStyle(.mhZweit)
          }
          HStack(spacing: Mh.abstand2) {
            Button("Endgültig löschen") {
              endgueltig = eintrag
            }
            .buttonStyle(.mhLoeschen)
            if inArbeit == eintrag.kennung {
              ProgressView().controlSize(.small).tint(Mh.primary)
            }
          }
        }
        .disabled(inArbeit != nil)
        .padding(.top, Mh.abstand1)
      }
    }
  }

  /// Vorschaubild einer Datei; bei Videos das Standbild mit Abspiel-Zeichen.
  private func vorschau(_ eintrag: PapierkorbEintrag, _ datei: String) -> some View {
    MedienBild(url: api.papierkorbVorschauUrl(kennung: eintrag.kennung, datei: datei)) { bild in
      bild.resizable().scaledToFill()
    } platzhalter: {
      ProgressView().tint(Mh.textTertiary)
    } fehler: {
      MhSymbol("MhImage").foregroundStyle(Mh.textTertiary)
    }
    .frame(width: 72, height: 72)
    .background(Mh.surfaceSubtle)
    .clipShape(RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous))
    .overlay {
      if isVideoFile(datei) {
        HbVideoMarke()
      }
    }
    .accessibilityLabel(isVideoFile(datei) ? "Standbild des Videos" : "Foto")
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
        AppMeldung.shared.zeige(erfolg)
        await laden()
      } catch {
        meldung = "Das hat nicht geklappt: \(error.localizedDescription)"
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
