import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Formular „Neuer Eintrag“ wie im Web: Felder mit Label darüber, Optionales
/// als „optional“ markiert, Ersteller als Auswahl, Medien (Fotomediathek und
/// Kamera) als Zweitbuttons, Upload-Fortschritt und genau eine Hauptaktion
/// „Eintrag speichern“.
struct CreateView: View {

  let initialDate: String?

  @Environment(\.dismiss) private var dismiss

  @State private var datum = Date()
  @State private var werte: [String: String] = [:]
  @State private var vonName = ""
  @State private var nutzer: [String] = []
  @State private var medien: [GewaehltesMedium] = []
  @State private var fotoAuswahl: [PhotosPickerItem] = []
  /// Anzahl Medien, die gerade aus der Mediathek übernommen werden – Videos
  /// brauchen dafür mehrere Sekunden (Kopie/iCloud-Download).
  @State private var medienLadenAnzahl = 0
  @State private var zeigeKamera = false
  @State private var speichert = false
  @StateObject private var upload = UploadFortschritt()
  @State private var meldung: String?
  @State private var zeigeErstellerHinweis = false
  @State private var zeigeDatumswahl = false

  private let api = ApiClient.shared
  private var diary: Diary { kDiaries[AppSettings.activeDiary] ?? kDiaries[kDefaultDiary]! }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: Mh.abstand4) {
        Text(diary.title)
          .mhText(.small)
          .foregroundStyle(Mh.textSecondary)

        datumsFeld

        // Felder des Tagebuchs: Pflichtfeld ohne Zusatz, alles andere „optional“.
        ForEach(diary.fields, id: \.key) { feld in
          eingabe(feld)
        }

        erstellerFeld
        medienFeld

        if speichert, !medien.isEmpty {
          fortschritt
        }

        // Die eine Hauptaktion
        Button {
          speichern()
        } label: {
          HStack(spacing: Mh.abstand2) {
            if speichert {
              ProgressView().controlSize(.small).tint(Mh.textDisabled)
            }
            Text(
              medienLadenAnzahl > 0
                ? "Medien werden übernommen …"
                : (speichert ? "Wird gespeichert …" : "Eintrag speichern"))
          }
        }
        .buttonStyle(MhHauptButtonStil(breit: true))
        .disabled(speichert || medienLadenAnzahl > 0)
        .padding(.top, Mh.abstand2)
      }
      .padding(.horizontal, Mh.rand)
      .padding(.top, Mh.abstand1)
      .padding(.bottom, Mh.abstand8)
      .hbBreite()
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Mh.bg.ignoresSafeArea())
    .navigationTitle("Neuer Eintrag")
    .navigationBarTitleDisplayMode(.large)
    .sheet(isPresented: $zeigeDatumswahl) {
      HbDatumswahl(datum: $datum)
    }
    // Personen können in den Einstellungen dazugekommen sein.
    .onAppear {
      nutzer = AppSettings.users
      if !nutzer.contains(vonName) { vonName = Self.vorauswahl(nutzer) }
    }
    .task {
      if let initialDate, let start = HbDatum.datum(initialDate) {
        datum = start
      }
      nutzer = AppSettings.users
      if !nutzer.contains(vonName) { vonName = Self.vorauswahl(nutzer) }
      if werte.isEmpty {
        for feld in diary.fields { werte[feld.key] = "" }
      }
    }
    .onChange(of: fotoAuswahl) { _, neu in
      guard !neu.isEmpty else { return }
      fotoAuswahl = []
      medienLadenAnzahl += neu.count
      Task { await uebernehmeAuswahl(neu) }
    }
    .fullScreenCover(isPresented: $zeigeKamera) {
      KameraAufnahme { url, istVideo in
        medien.append(GewaehltesMedium(url: url, istVideo: istVideo))
      }
      .ignoresSafeArea()
    }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
    .alert("Wer schreibt den Eintrag?", isPresented: $zeigeErstellerHinweis) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        nutzer.isEmpty
          ? "Es ist noch keine Person angelegt. Lege in den Einstellungen mindestens "
            + "eine Person an, um sie hier als Ersteller auswählen zu können."
          : "Bitte wähle aus, von wem der Eintrag ist.")
    }
  }

  /// Standard-Person vor der zuletzt gewählten; sonst niemand.
  private static func vorauswahl(_ nutzer: [String]) -> String {
    let standard = AppSettings.defaultUser
    let zuletzt = AppSettings.selectedUser
    if nutzer.contains(standard) { return standard }
    if nutzer.contains(zuletzt) { return zuletzt }
    return ""
  }

  private static func datumText(_ datum: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateFormat = "EEEE, dd.MM.yyyy"
    return formatter.string(from: datum)
  }

  /// Datum: sieht aus wie ein Feld, öffnet die Datumsauswahl.
  private var datumsFeld: some View {
    MhFeld("Datum") {
      Button {
        zeigeDatumswahl = true
      } label: {
        HStack(spacing: Mh.abstand2) {
          Text(Self.datumText(datum))
            .frame(maxWidth: .infinity, alignment: .leading)
          MhSymbol("MhCalendar").foregroundStyle(Mh.textSecondary)
        }
        .hbFeldRahmen()
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Datum, \(Self.datumText(datum))")
      .accessibilityHint("Datum ändern")
    }
  }

  private func eingabe(_ feld: DiaryField) -> some View {
    MhFeld(feld.label, zusatz: feld.required ? nil : "optional") {
      if feld.textarea {
        TextEditor(text: bindung(feld.key))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 96)
          .padding(.horizontal, -5)
          .hbFeldRahmen(mehrzeilig: true)
          .accessibilityLabel(feld.label)
      } else {
        HStack(spacing: Mh.abstand2) {
          TextField("", text: bindung(feld.key))
            .keyboardType(feld.numeric ? .decimalPad : .default)
            .accessibilityLabel(feld.label)
          if !feld.unit.isEmpty {
            Text(feld.unit).foregroundStyle(Mh.textSecondary)
          }
        }
        .hbFeldRahmen()
      }
    }
  }

  /// Ersteller als Auswahl-Chips; ohne Personen der Weg in die Einstellungen.
  private var erstellerFeld: some View {
    MhFeld(
      "Von",
      hinweis: nutzer.isEmpty ? "Personen legst du in den Einstellungen an." : nil
    ) {
      if nutzer.isEmpty {
        NavigationLink(value: Ziel.settings) {
          MhButtonInhalt("Person anlegen", symbol: "MhUserPlus", symbolGroesse: 18)
        }
        .buttonStyle(.mhText)
      } else {
        HbReihe {
          ForEach(nutzer, id: \.self) { name in
            MhAuswahl(name, gewaehlt: vonName == name) { vonName = name }
          }
        }
      }
    }
  }

  private var medienFeld: some View {
    MhFeld("Fotos und Videos", zusatz: "optional") {
      VStack(alignment: .leading, spacing: Mh.abstand2) {
        HbReihe(abstand: Mh.abstand2) {
          PhotosPicker(
            selection: $fotoAuswahl, matching: .any(of: [.images, .videos])
          ) {
            MhButtonInhalt("Auswählen", symbol: "MhImage", symbolGroesse: 18)
          }
          .buttonStyle(.mhZweit)
          Button {
            zeigeKamera = true
          } label: {
            MhButtonInhalt("Kamera", symbol: "MhCamera", symbolGroesse: 18)
          }
          .buttonStyle(.mhZweit)
        }

        if !medien.isEmpty || medienLadenAnzahl > 0 {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(medien) { medium in
                vorschau(medium)
                  .frame(width: 88, height: 88)
                  .background(Mh.surfaceSubtle)
                  .clipShape(RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous))
                  .overlay(alignment: .topTrailing) {
                    Button {
                      medien.removeAll { $0.id == medium.id }
                      Self.loesche([medium])
                    } label: {
                      MhSymbol("MhClose", groesse: 14)
                        .foregroundStyle(Color.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                        .frame(width: Mh.touch, height: Mh.touch, alignment: .topTrailing)
                        .padding(4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Entfernen")
                  }
              }
              // Platzhalter für Medien, die noch übernommen werden.
              ForEach(0..<medienLadenAnzahl, id: \.self) { _ in
                ProgressView()
                  .tint(Mh.primary)
                  .frame(width: 88, height: 88)
                  .background(Mh.surfaceSubtle)
                  .clipShape(RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous))
              }
            }
          }
        }
        if medienLadenAnzahl > 0 {
          Text("Medien werden übernommen, bitte kurz warten.")
            .mhText(.small)
            .foregroundStyle(Mh.textSecondary)
        }
      }
    }
  }

  /// Upload-Fortschritt: Text in Nebentextfarbe, darunter ein dünner Balken.
  private var fortschritt: some View {
    VStack(alignment: .leading, spacing: Mh.abstand2) {
      if let wert = upload.wert, wert < 1 {
        Text("Medien werden hochgeladen · \(Int(wert * 100)) %")
          .mhText(.small)
          .monospacedDigit()
          .foregroundStyle(Mh.textSecondary)
        MhBalken(anteil: wert, farbe: Mh.primary)
      } else {
        HStack(spacing: Mh.abstand2) {
          ProgressView().controlSize(.small).tint(Mh.primary)
          Text(upload.wert == nil ? "Upload wird vorbereitet …" : "Medien werden verarbeitet …")
            .mhText(.small)
            .foregroundStyle(Mh.textSecondary)
        }
      }
    }
  }

  private func bindung(_ key: String) -> Binding<String> {
    Binding(
      get: { werte[key] ?? "" },
      set: { werte[key] = $0 })
  }

  @ViewBuilder
  private func vorschau(_ medium: GewaehltesMedium) -> some View {
    if medium.istVideo {
      ZStack {
        Rectangle().fill(Color.black.opacity(0.85))
        HbVideoMarke()
      }
    } else if let bild = MediaThumb.vorschaubild(pfad: medium.url.path) {
      // 90x90-Kachel – die volle Kameraauflösung dafür zu dekodieren, wäre
      // derselbe Speicherfehler wie früher im Galerie-Grid.
      Image(uiImage: bild).resizable().scaledToFill()
    } else {
      Rectangle().fill(Mh.surfaceSubtle)
    }
  }

  /// Räumt die Zwischenkopien in `tmp/` weg.
  ///
  /// Bewusst nicht in `onDisappear`: SwiftUI ruft das auch, wenn die Ansicht
  /// nur überdeckt wird – etwa beim Sprung in die Einstellungen von hier aus.
  /// Die Dateien eines verworfenen Formulars räumt der Sweep beim nächsten
  /// App-Start ab (`HelloBabyApp.tmpAufraeumen()`).
  private static func loesche(_ medien: [GewaehltesMedium]) {
    for medium in medien {
      try? FileManager.default.removeItem(at: medium.url)
    }
  }

  private func uebernehmeAuswahl(_ auswahl: [PhotosPickerItem]) async {
    for element in auswahl {
      defer { medienLadenAnzahl = max(0, medienLadenAnzahl - 1) }
      do {
        let istVideo = element.supportedContentTypes.contains { $0.conforms(to: .movie) }
        if istVideo {
          if let film = try await element.loadTransferable(type: FilmDatei.self) {
            medien.append(GewaehltesMedium(url: film.url, istVideo: true))
          }
        } else if let daten = try await element.loadTransferable(type: Data.self) {
          let endung =
            element.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
          let ziel = FileManager.default.temporaryDirectory
            .appendingPathComponent("auswahl_\(UUID().uuidString).\(endung)")
          try daten.write(to: ziel)
          medien.append(GewaehltesMedium(url: ziel, istVideo: false))
        }
      } catch {
        meldung = "Medium konnte nicht übernommen werden: \(error.localizedDescription)"
      }
    }
  }

  private func speichern() {
    guard medienLadenAnzahl == 0 else {
      meldung = "Bitte kurz warten, die Medien werden noch übernommen."
      return
    }
    let fehlend = diary.fields.filter {
      $0.required && (werte[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    if !fehlend.isEmpty {
      meldung = "Bitte \(fehlend.map { "„\($0.label)“" }.joined(separator: " und ")) ausfüllen."
      return
    }
    if vonName.isEmpty {
      zeigeErstellerHinweis = true
      return
    }
    speichert = true
    upload.wert = nil
    let progress: (@Sendable (Int64, Int64) -> Void)? =
      medien.isEmpty ? nil : upload.melde
    Task {
      do {
        var fields: [String: String] = [:]
        for feld in diary.fields {
          fields[feld.key] = (werte[feld.key] ?? "").trimmingCharacters(in: .whitespaces)
        }
        _ = try await api.createEntry(
          kalenderDatum: HbDatum.iso(datum),
          fields: fields,
          vonName: vonName,
          images: medien.map(\.url),
          diary: diary.id,
          onSendProgress: progress)
        AppSettings.selectedUser = vonName
        // Die Zwischenkopien haben ihren Zweck erfüllt: hochgeladen bzw. im
        // lokalen Modus nach Documents/HelloBaby/media/ kopiert. Ohne dieses
        // Aufräumen liegt jedes Foto und jedes Video dauerhaft doppelt da.
        Self.loesche(medien)
        medien = []
        speichert = false
        AppMeldung.shared.zeige("Eintrag gespeichert")
        dismiss()
      } catch {
        speichert = false
        upload.wert = nil
        meldung = "Speichern fehlgeschlagen: \(error.localizedDescription)"
      }
    }
  }
}

/// Nimmt Upload-Fortschritt von der URLSession-Delegate-Queue entgegen und
/// reicht ihn an die Oberfläche weiter.
@MainActor
final class UploadFortschritt: ObservableObject {
  @Published var wert: Double?

  nonisolated func melde(_ gesendet: Int64, _ gesamt: Int64) {
    let anteil = gesamt > 0 ? Double(gesendet) / Double(gesamt) : 0
    DispatchQueue.main.async {
      MainActor.assumeIsolated { self.wert = anteil }
    }
  }
}

/// Ein fürs Formular ausgewähltes Medium (immer als lokale Datei gepuffert).
struct GewaehltesMedium: Identifiable {
  let id = UUID()
  let url: URL
  let istVideo: Bool
}

/// Video aus dem PhotosPicker als temporäre Datei übernehmen.
private struct FilmDatei: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { film in
      SentTransferredFile(film.url)
    } importing: { empfangen in
      let ziel = FileManager.default.temporaryDirectory
        .appendingPathComponent("film_\(UUID().uuidString).\(empfangen.file.pathExtension)")
      try FileManager.default.copyItem(at: empfangen.file, to: ziel)
      return FilmDatei(url: ziel)
    }
  }
}

/// Kamera für Foto- und Videoaufnahme (UIImagePickerController).
private struct KameraAufnahme: UIViewControllerRepresentable {

  var onAufnahme: (URL, Bool) -> Void

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      picker.sourceType = .camera
      picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
    }
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Koordinator { Koordinator(self) }

  final class Koordinator: NSObject, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate
  {
    let eltern: KameraAufnahme

    init(_ eltern: KameraAufnahme) { self.eltern = eltern }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      defer { picker.dismiss(animated: true) }
      if let filmURL = info[.mediaURL] as? URL {
        let ziel = FileManager.default.temporaryDirectory
          .appendingPathComponent("kamera_\(UUID().uuidString).\(filmURL.pathExtension)")
        try? FileManager.default.copyItem(at: filmURL, to: ziel)
        eltern.onAufnahme(ziel, true)
      } else if let bild = info[.originalImage] as? UIImage,
        let daten = bild.jpegData(compressionQuality: 0.9)
      {
        let ziel = FileManager.default.temporaryDirectory
          .appendingPathComponent("kamera_\(UUID().uuidString).jpg")
        try? daten.write(to: ziel)
        eltern.onAufnahme(ziel, false)
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
    }
  }
}
