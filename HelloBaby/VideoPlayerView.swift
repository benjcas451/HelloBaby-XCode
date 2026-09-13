import AVKit
import SwiftUI

/// Vollbild-Videoplayer für lokale Dateien und Server-Quellen.
///
/// Server-Quellen werden mit denselben Kopfzeilen abgerufen wie der Rest der
/// App. Ohne sie blockiert Cloudflare Access die Anfrage am Rand, und der
/// Player zeigte nur einen schwarzen Bildschirm.
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
        let neu = AVPlayer(playerItem: AVPlayerItem(asset: Self.asset(fuer: url)))
        neu.play()
        player = neu
      }
    }
    .onDisappear {
      player?.pause()
    }
  }

  /// Baut das Asset. Für Server-Quellen kommen die Kopfzeilen der App mit;
  /// `AVURLAssetHTTPHeaderFieldsKey` ist der übliche Weg dafür, weil
  /// `AVPlayer` selbst keine `URLRequest` entgegennimmt.
  private static func asset(fuer url: URL) -> AVURLAsset {
    guard !url.isFileURL else { return AVURLAsset(url: url) }
    let header = ApiClient.authHeader
    guard !header.isEmpty else { return AVURLAsset(url: url) }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": header])
  }
}
