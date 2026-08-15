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
