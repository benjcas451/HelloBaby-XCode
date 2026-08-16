import AVFoundation
import SwiftUI

/// Karte eines Tagebuch-Eintrags: Kopfzeile (erstellt am / von), dynamische
/// Tagebuch-Felder, Favoriten-Stern, Galerie-Link und Löschen – wie die
/// Flutter-App.
struct EntryCard: View {

  let entry: Entry
  var onGeloescht: () -> Void
  var onMeldung: (String) -> Void

  @State private var favorit: Bool
  @State private var favoritLaeuft = false
  @State private var loeschenBestaetigen = false
  @State private var loeschenLaeuft = false

  private let api = ApiClient.shared

  init(
    entry: Entry,
    onGeloescht: @escaping () -> Void,
    onMeldung: @escaping (String) -> Void
  ) {
    self.entry = entry
    self.onGeloescht = onGeloescht
    self.onMeldung = onMeldung
    _favorit = State(initialValue: entry.favorit == 1)
  }

  private var diary: Diary? { kDiaries[entry.diary] }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Erstellt am \(entry.createdAt)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        if !entry.vonName.isEmpty {
          Text("von \(entry.vonName)")
            .font(.caption.bold())
            .foregroundStyle(Hb.accentDeep)
        }
      }

      ForEach(diary?.fields ?? [], id: \.key) { feld in
        let wert = entry.fields[feld.key] ?? ""
        if feld.numeric, !wert.isEmpty, wert != "0" {
          HStack(spacing: 8) {
            Image(systemName: Self.symbol(fuer: feld.key))
              .foregroundStyle(Hb.accentDeep)
            Text("\(feld.label):").bold()
            Text("\(wert) \(feld.unit)")
          }
          .font(.subheadline)
        } else if feld.textarea, !wert.isEmpty {
          VStack(alignment: .leading, spacing: 2) {
            Text("\(feld.label):").bold()
            Text(wert)
          }
          .font(.subheadline)
        }
      }

      HStack {
        Button {
          favoritUmschalten()
        } label: {
          if favoritLaeuft {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: favorit ? "star.fill" : "star")
              .foregroundStyle(favorit ? Hb.gold : .secondary)
          }
        }
        .buttonStyle(.plain)

        if !entry.bilder.isEmpty {
          NavigationLink(value: Ziel.gallery(folder: entry.bilder)) {
            Text("Galerie").font(.subheadline.bold())
          }
        }

        Spacer()

        Button(role: .destructive) {
          loeschenBestaetigen = true
        } label: {
          if loeschenLaeuft {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "trash")
          }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red.opacity(0.7))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .hbKarte()
    .confirmationDialog(
      "Eintrag löschen?", isPresented: $loeschenBestaetigen, titleVisibility: .visible
    ) {
      Button("Löschen", role: .destructive) { loeschen() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text("Der Eintrag und seine Medien werden dauerhaft entfernt.")
    }
  }

  private func favoritUmschalten() {
    guard !favoritLaeuft else { return }
    favoritLaeuft = true
    Task {
      do {
        let neu = try await api.toggleFavorite(id: entry.id, diary: entry.diary)
        favorit = neu == 1
      } catch {
        onMeldung("Favorit fehlgeschlagen: \(error.localizedDescription)")
      }
      favoritLaeuft = false
    }
  }

  private func loeschen() {
    guard !loeschenLaeuft else { return }
    loeschenLaeuft = true
    Task {
      do {
        try await api.deleteEntry(id: entry.id, diary: entry.diary)
        onGeloescht()
      } catch {
        onMeldung("Löschen fehlgeschlagen: \(error.localizedDescription)")
      }
      loeschenLaeuft = false
    }
  }

  private static func symbol(fuer key: String) -> String {
    switch key {
    case "gewicht": return "scalemass"
    case "kopfumfang": return "face.smiling"
    default: return "ruler"
    }
  }
}

// MARK: - Medien-Kachel

/// Zeigt ein Vorschaubild für eine lokale Datei oder eine Server-Quelle;
/// Videos bekommen ein Play-Symbol (lokal mit generiertem Standbild).
struct MediaThumb: View {

  /// Lokal: absoluter Ordnerpfad; Server: `uploads/<ordner>`.
  let folder: String
  let file: String

  @State private var lokalesBild: UIImage?

  private var istVideo: Bool { isVideoFile(file) }
  private var lokal: Bool { isLocalMediaSource(folder) }

  /// Quelle als String für die Navigation (Pfad oder relative Server-Datei).
  var quelle: String { lokal ? folder + "/" + file : folder + "/" + file }

  var body: some View {
    // Color.clear nimmt exakt den zugewiesenen Rahmen an; das Bild wird als
    // Overlay hineingelegt und zuverlässig auf diesen Rahmen beschnitten –
    // sonst überlaufen scaledToFill-Bilder ihre Grid-Zelle.
    Color.clear
      .overlay {
        if lokal {
          if let lokalesBild {
            Image(uiImage: lokalesBild)
              .resizable()
              .scaledToFill()
          } else {
            Rectangle().fill(Color.black.opacity(istVideo ? 0.85 : 0.08))
          }
        } else {
          AsyncImage(url: URL(string: ApiClient.shared.thumbUrl(quelle))) { phase in
            switch phase {
            case .success(let bild):
              bild.resizable().scaledToFill()
            case .failure:
              Rectangle().fill(Color.black.opacity(0.1))
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            default:
              Rectangle().fill(Color.black.opacity(0.05))
                .overlay(ProgressView())
            }
          }
        }
      }
      .overlay {
        if istVideo {
          Image(systemName: "play.circle.fill")
            .font(.title)
            .foregroundStyle(.white)
            .shadow(radius: 4)
        }
      }
      .clipped()
      .contentShape(Rectangle())
      .task(id: quelle) {
      guard lokal, lokalesBild == nil else { return }
      let pfad = quelle
      if istVideo {
        lokalesBild = await Self.videoStandbild(pfad: pfad)
      } else {
        lokalesBild = await Task.detached { UIImage(contentsOfFile: pfad) }.value
      }
      }
  }

  private static func videoStandbild(pfad: String) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: pfad)))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 600, height: 600)
    guard let bild = try? await generator.image(at: .zero).image else { return nil }
    return UIImage(cgImage: bild)
  }
}

// MARK: - Kleine Zustands-Ansichten

struct LadeAnsicht: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Wird geladen…").foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct FehlerAnsicht: View {
  let text: String
  var erneut: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: AppSettings.mode == .local ? "internaldrive" : "wifi.slash")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(text)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Button("Erneut versuchen", action: erneut)
        .buttonStyle(.borderedProminent)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

struct LeerAnsicht: View {
  let symbol: String
  let text: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(text)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
