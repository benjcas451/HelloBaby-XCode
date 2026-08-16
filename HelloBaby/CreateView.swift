import Combine
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Formular „Eintrag erstellen“: dynamische Tagebuch-Felder, Datum, Ersteller,
/// Medien (Fotomediathek + Kamera) und Upload-Fortschritt – wie die Flutter-App.
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
  @State private var zumEinstellungenNavigieren = false

  private let api = ApiClient.shared
  private var diary: Diary { kDiaries[AppSettings.activeDiary] ?? kDiaries[kDefaultDiary]! }

  var body: some View {
    Form {
      Section {
        DatePicker("Datum", selection: $datum, displayedComponents: .date)
      }

      Section("Einträge") {
        ForEach(diary.fields, id: \.key) { feld in
          if feld.textarea {
            VStack(alignment: .leading, spacing: 4) {
              Text(feld.required ? "\(feld.label) *" : feld.label)
                .font(.caption)
                .foregroundStyle(.secondary)
              TextEditor(text: bindung(feld.key))
                .frame(minHeight: 80)
            }
          } else {
            HStack {
              Text(feld.required ? "\(feld.label) *" : feld.label)
              TextField("", text: bindung(feld.key))
                .multilineTextAlignment(.trailing)
                .keyboardType(feld.numeric ? .decimalPad : .default)
              if !feld.unit.isEmpty {
                Text(feld.unit).foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      Section("Ersteller *") {
        if nutzer.isEmpty {
          Text("Noch keine Person angelegt – in den Einstellungen unter „Personen“ anlegen.")
            .font(.footnote)
            .foregroundStyle(.secondary)
          NavigationLink(value: Ziel.settings) {
            Label("Zu den Einstellungen", systemImage: "person.badge.plus")
          }
        } else {
          Picker("Ersteller", selection: $vonName) {
            Text("Bitte wählen").tag("")
            ForEach(nutzer, id: \.self) { name in
              Text(name).tag(name)
            }
          }
        }
      }

      Section("Medien") {
        PhotosPicker(
          selection: $fotoAuswahl, matching: .any(of: [.images, .videos])
        ) {
          Label("Aus der Mediathek", systemImage: "photo.on.rectangle")
        }
        Button {
          zeigeKamera = true
        } label: {
          Label("Kamera", systemImage: "camera")
        }

        if !medien.isEmpty || medienLadenAnzahl > 0 {
          ScrollView(.horizontal) {
            HStack(spacing: 8) {
              ForEach(medien) { medium in
                ZStack(alignment: .topTrailing) {
                  vorschau(medium)
                    .frame(width: 90, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                  Button {
                    medien.removeAll { $0.id == medium.id }
                  } label: {
                    Image(systemName: "xmark.circle.fill")
                      .foregroundStyle(.white, .red)
                  }
                  .padding(2)
                }
              }
              // Platzhalter für Medien, die noch übernommen werden.
              ForEach(0..<medienLadenAnzahl, id: \.self) { _ in
                VStack(spacing: 6) {
                  ProgressView()
                  Text("Übernehme…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 90, height: 90)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
              }
            }
          }
        }
        if medienLadenAnzahl > 0 {
          Text("Medien werden übernommen – bitte kurz warten.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      if speichert, !medien.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            if let fortschritt = upload.wert, fortschritt < 1 {
              Text("Medien werden hochgeladen… \(Int(fortschritt * 100))%")
              ProgressView(value: fortschritt)
            } else {
              Text(upload.wert == nil ? "Upload wird vorbereitet…" : "Medien werden verarbeitet…")
              ProgressView()
            }
          }
          .font(.footnote)
        }
      }

      Section {
        Button {
          speichern()
        } label: {
          HStack {
            if speichert {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "square.and.arrow.down")
            }
            Text(
              medienLadenAnzahl > 0
                ? "Medien werden übernommen…"
                : (speichert ? "Speichern…" : "Speichern")
            )
            .bold()
          }
          .frame(maxWidth: .infinity)
        }
        .disabled(speichert || medienLadenAnzahl > 0)
      }
    }
    .navigationTitle("\(diary.title): Eintrag")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      if let initialDate, let start = DayView.datum(initialDate) {
        datum = start
      }
      nutzer = AppSettings.users
      let standard = AppSettings.defaultUser
      let zuletzt = AppSettings.selectedUser
      if nutzer.contains(standard) {
        vonName = standard
      } else if nutzer.contains(zuletzt) {
        vonName = zuletzt
      }
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
    .alert("Kein Ersteller ausgewählt", isPresented: $zeigeErstellerHinweis) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(
        nutzer.isEmpty
          ? "Es ist noch keine Person angelegt. Lege in den Einstellungen mindestens "
            + "eine Person an, um sie hier als Ersteller auswählen zu können."
          : "Bitte wähle einen Ersteller aus.")
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
        Image(systemName: "play.circle.fill")
          .font(.title)
          .foregroundStyle(.white)
      }
    } else if let bild = UIImage(contentsOfFile: medium.url.path) {
      Image(uiImage: bild).resizable().scaledToFill()
    } else {
      Rectangle().fill(Color.black.opacity(0.1))
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
      meldung = "Bitte warten – Medien werden noch übernommen."
      return
    }
    let pflichtFehlt = diary.fields.contains {
      $0.required && (werte[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
    if pflichtFehlt {
      meldung = "Bitte alle Pflichtfelder (*) ausfüllen."
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
          kalenderDatum: DayView.iso(datum),
          fields: fields,
          vonName: vonName,
          images: medien.map(\.url),
          diary: diary.id,
          onSendProgress: progress)
        AppSettings.selectedUser = vonName
        speichert = false
        dismiss()
      } catch {
        speichert = false
        upload.wert = nil
        meldung = "Fehler: \(error.localizedDescription)"
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
