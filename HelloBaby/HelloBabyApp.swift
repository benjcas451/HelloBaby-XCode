import SwiftUI

/// Navigationsziele der App.
enum Ziel: Hashable {
  case create(initialDate: String?)
  case day(initialDate: String?)
  case month
  case favorites
  case imageFeed
  case gallery(folder: String)
  case video(url: String)
  case settings
}

@main
struct HelloBabyApp: App {

  @State private var pfad: [Ziel] = []

  init() {
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
            case .day(let initialDate):
              DayView(initialDate: initialDate)
            case .month:
              MonthView()
            case .favorites:
              FavoritesView()
            case .imageFeed:
              ImageFeedView()
            case .gallery(let folder):
              GalleryView(folder: folder)
            case .video(let url):
              VideoPlayerView(quelle: url)
            case .settings:
              SettingsView()
            }
          }
      }
      .tint(Hb.accentDeep)
    }
  }
}
