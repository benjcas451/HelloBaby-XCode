import AVKit
import SwiftUI

/// Vollbild-Videoplayer für lokale Dateien und Server-Quellen
/// (Medien liefert der Server ohne Authentifizierung aus).
struct VideoPlayerView: View {

  /// Lokal: absoluter Dateipfad; Server: relativer `uploads/...`-Pfad.
  let quelle: String

  @State private var player: AVPlayer?

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
      } else {
        ProgressView().tint(.white)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.black.ignoresSafeArea())
    .navigationTitle("Video")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .onAppear {
      guard player == nil else { return }
      let url: URL? =
        isLocalMediaSource(quelle)
        ? URL(fileURLWithPath: quelle)
        : URL(string: ApiClient.shared.mediaUrl(quelle))
      if let url {
        let neu = AVPlayer(url: url)
        neu.play()
        player = neu
      }
    }
    .onDisappear {
      player?.pause()
    }
  }
}
