import SwiftUI

/// Navigationsziele der App. Tag, Monat, Favoriten und Galerie sind Reiter
/// der Hauptansicht (`HomeView`) und keine eigenen Ziele.
enum Ziel: Hashable {
  case create(initialDate: String?)
  case gallery(folder: String)
  case video(url: String)
  case settings
  case trash
}

@main
struct HelloBabyApp: App {

  @State private var pfad: [Ziel] = []
  @ObservedObject private var appMeldung = AppMeldung.shared

  init() {
    // Figtree und die neutralen Leisten von „Minze & Honig 2.0“.
    MhDarstellung.einrichten()
    AppSettings.migrationAusfuehren()
    // Ohne mindestens eine Datei blendet iOS den App-Ordner in der
    // „Dateien“-App aus – dort liegen aber client.crt/client.key.
    AppOrdner.sichtbarMachen()
    Self.tmpAufraeumen()
  }

  /// Entfernt Zwischenkopien früherer Sitzungen aus `tmp/`.
  ///
  /// Medien aus Mediathek und Kamera werden vor dem Speichern dorthin kopiert,
  /// das Backup-ZIP ebenso. Bricht die App vorher ab, blieben sie liegen –
  /// im lokalen Modus lag damit jedes Foto und jedes Video doppelt auf dem
  /// Gerät. Der laufende Betrieb räumt seine eigenen Dateien selbst weg;
  /// hier geht es um die Altlasten.
  private static func tmpAufraeumen() {
    let praefixe = [
      "auswahl_", "film_", "kamera_", "hello_baby_backup_", "restore_staging_",
    ]
    let tmp = FileManager.default.temporaryDirectory
    let inhalt = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
    for name in inhalt where praefixe.contains(where: name.hasPrefix) {
      try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
    }
  }

  var body: some Scene {
    WindowGroup {
      NavigationStack(path: $pfad) {
        HomeView(pfad: $pfad)
          .navigationDestination(for: Ziel.self) { ziel in
            switch ziel {
            case .create(let initialDate):
              CreateView(initialDate: initialDate)
            case .gallery(let folder):
              GalleryView(folder: folder)
            case .video(let url):
              VideoPlayerView(quelle: url)
            case .settings:
              SettingsView()
            case .trash:
              PapierkorbView()
            }
          }
      }
      .tint(Mh.primary)
      // Grundschrift für alles, was keinen eigenen Stil setzt.
      .font(MhTextStil.body.font)
      .foregroundStyle(Mh.text)
      // Kurze Meldungen („Eintrag gespeichert“) über allen Ansichten.
      .overlay(alignment: .bottom) {
        if let text = appMeldung.text {
          HbToast(text: text)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      }
      .animation(.easeOut(duration: 0.2), value: appMeldung.text)
    }
  }
}
