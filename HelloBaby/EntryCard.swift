import AVFoundation
import ImageIO
import SwiftUI

/// Karte eines Tagebucheintrags wie im Web: Kopfzeile „[Datum ·] 07:01 ·
/// Name“ mit Stern, Haupttext ohne Label, weitere Texte mit kleinem Label,
/// Zahlen als Marken, Fotos als Raster, „Löschen“ als roter Text.
struct EntryCard: View {

  let entry: Entry
  var mitDatum: Bool
  var onGeloescht: () -> Void
  var onMeldung: (String) -> Void

  @State private var favorit: Bool
  @State private var favoritLaeuft = false
  @State private var loeschenBestaetigen = false
  @State private var loeschenLaeuft = false

  private let api = ApiClient.shared

  init(
    entry: Entry,
    mitDatum: Bool = false,
    onGeloescht: @escaping () -> Void,
    onMeldung: @escaping (String) -> Void
  ) {
    self.entry = entry
    self.mitDatum = mitDatum
    self.onGeloescht = onGeloescht
    self.onMeldung = onMeldung
    _favorit = State(initialValue: entry.favorit == 1)
  }

  private var diary: Diary? { kDiaries[entry.diary] ?? kDiaries[AppSettings.activeDiary] }

  /// Texte des Tagebuchs, die etwas enthalten.
  private var texte: [DiaryField] {
    (diary?.fields ?? []).filter {
      $0.textarea && !(entry.fields[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var medien: [String] {
    entry.bilderFiles.filter { isImageFile($0) || isVideoFile($0) }
  }

  private var kopfzeile: String {
    var teile: [String] = []
    if mitDatum, !entry.kalenderDatum.isEmpty { teile.append(HbDatum.anzeige(entry.kalenderDatum)) }
    let zeit = HbDatum.uhrzeit(entry.createdAt)
    if !zeit.isEmpty { teile.append(zeit) }
    if !entry.vonName.isEmpty { teile.append(entry.vonName) }
    return teile.joined(separator: " · ")
  }

  var body: some View {
    MhKarte {
      VStack(alignment: .leading, spacing: Mh.abstand3) {
        HStack(spacing: Mh.abstand2) {
          Text(kopfzeile)
            .mhText(.small)
            .monospacedDigit()
            .foregroundStyle(Mh.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
          stern
        }
        .padding(.vertical, -Mh.abstand2)
        .padding(.trailing, -Mh.abstand3)

        ForEach(Array(texte.enumerated()), id: \.element.key) { index, feld in
          VStack(alignment: .leading, spacing: 2) {
            // Das Pflichtfeld ist der Haupttext und braucht kein Label.
            if index > 0 || !feld.required {
              Text(feld.label).mhText(.label).foregroundStyle(Mh.textSecondary)
            }
            Text(entry.fields[feld.key] ?? "")
              .mhText(.body)
              .foregroundStyle(Mh.text)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        let zahlen = hbZahlenMarken(entry.fields, diary: diary)
        if !zahlen.isEmpty {
          HbReihe {
            ForEach(zahlen, id: \.self) { MhMarke($0) }
          }
        }

        if !medien.isEmpty {
          NavigationLink(value: Ziel.gallery(folder: entry.bilder)) {
            fotoRaster
          }
          .buttonStyle(.plain)
          .accessibilityLabel(medien.count == 1 ? "Foto ansehen" : "\(medien.count) Fotos ansehen")
        } else if !entry.bilder.isEmpty {
          NavigationLink(value: Ziel.gallery(folder: entry.bilder)) {
            MhButtonInhalt("Fotos ansehen", symbol: "MhImage", symbolGroesse: 16)
          }
          .buttonStyle(.mhText)
          .padding(.vertical, -Mh.abstand2)
        }

        HStack(spacing: Mh.abstand2) {
          Spacer(minLength: 0)
          if loeschenLaeuft {
            ProgressView().controlSize(.small).tint(Mh.danger)
          }
          Button("Löschen") { loeschenBestaetigen = true }
            .buttonStyle(.mhLoeschen)
            .disabled(loeschenLaeuft)
        }
        .padding(.vertical, -Mh.abstand2)
      }
    }
    .confirmationDialog(
      "Eintrag löschen?", isPresented: $loeschenBestaetigen, titleVisibility: .visible
    ) {
      Button("Löschen", role: .destructive) { loeschen() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      // Der Server hebt Gelöschtes auf, die lokale Ablage nicht.
      Text(
        api.hatPapierkorb
          ? "Der Eintrag wandert samt Medien in den Papierkorb und lässt sich dort 30 Tage lang wiederherstellen."
          : "Der Eintrag und seine Medien werden dauerhaft entfernt.")
    }
  }

  /// Favoritenstern: gesetzt gefüllt in Honig, sonst Linie in Nebentextfarbe.
  @ViewBuilder
  private var stern: some View {
    if favoritLaeuft {
      ProgressView()
        .controlSize(.small)
        .tint(Mh.primary)
        .frame(width: Mh.touch, height: Mh.touch)
    } else {
      MhSymbolButton(
        favorit ? "MhStarGefuellt" : "MhStar",
        beschreibung: favorit ? "Favorit entfernen" : "Als Favorit markieren",
        farbe: favorit ? Mh.textYellow : Mh.textSecondary
      ) {
        favoritUmschalten()
      }
    }
  }

  /// Bis zu drei Vorschaubilder; bei mehr Medien trägt das dritte „+n“.
  private var fotoRaster: some View {
    HStack(spacing: 6) {
      ForEach(0..<3, id: \.self) { index in
        if index < medien.count {
          MediaThumb(folder: entry.bilder, file: medien[index])
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Mh.surfaceSubtle)
            .overlay {
              if index == 2, medien.count > 3 {
                ZStack {
                  Color.black.opacity(0.6)
                  Text("+\(medien.count - 3)").mhText(.h3).foregroundStyle(Color.white)
                }
              }
            }
            .clipShape(RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous))
        } else {
          Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
      }
    }
    .contentShape(Rectangle())
  }

  private func favoritUmschalten() {
    guard !favoritLaeuft else { return }
    favoritLaeuft = true
    Task {
      do {
        // Den aktuellen Stand mitgeben: ohne Verbindung bildet der Client
        // den neuen Wert daraus selbst, die API liefert ihn sonst erst in
        // ihrer Antwort.
        let neu = try await api.toggleFavorite(
          id: entry.id, diary: entry.diary, aktuell: favorit ? 1 : 0)
        favorit = neu == 1
      } catch {
        onMeldung("Favorit nicht gespeichert: \(error.localizedDescription)")
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
        AppMeldung.shared.zeige("Eintrag gelöscht")
        onGeloescht()
      } catch {
        onMeldung("Löschen fehlgeschlagen: \(error.localizedDescription)")
      }
      loeschenLaeuft = false
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
  var quelle: String { folder + "/" + file }

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
            Rectangle().fill(istVideo ? Color.black.opacity(0.85) : Mh.surfaceSubtle)
          }
        } else {
          MedienBild(url: ApiClient.shared.thumbUrl(quelle)) { bild in
            bild.resizable().scaledToFill()
          } platzhalter: {
            Rectangle().fill(Mh.surfaceSubtle)
              .overlay(ProgressView().tint(Mh.textTertiary))
          } fehler: {
            Rectangle().fill(Mh.surfaceSubtle)
              .overlay(MhSymbol("MhImage").foregroundStyle(Mh.textTertiary))
          }
        }
      }
      .overlay {
        if istVideo {
          HbVideoMarke()
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
        lokalesBild = await Task.detached { Self.vorschaubild(pfad: pfad) }.value
      }
      }
  }

  /// Kantenlänge der Vorschau in Pixeln. Die Kachel ist im 3-spaltigen Grid
  /// keine 150 pt breit; 600 px decken auch @3x mit Reserve ab.
  ///
  /// nonisolated, damit `vorschaubild` sie auch ausserhalb des MainActor
  /// lesen darf.
  nonisolated static let vorschauKante = 600

  /// Rechnet das Bild schon beim Dekodieren herunter.
  ///
  /// `UIImage(contentsOfFile:)` dekodiert die volle Kameraauflösung – ein
  /// 12-MP-Foto belegt so rund 48 MB, und im Grid sind schnell mehrere Dutzend
  /// gleichzeitig im Speicher. Genau das ist der klassische Weg, wie iOS eine
  /// Galerie wegen Speichermangels beendet. Videos waren über
  /// `AVAssetImageGenerator.maximumSize` längst gedeckelt, Standbilder nicht.
  // nonisolated, weil der Aufrufer ein Task.detached ist: ohne das ist der
  // Zugriff von ausserhalb des MainActor in Swift 6 ein Fehler.
  nonisolated static func vorschaubild(pfad: String) -> UIImage? {
    let quelle = CGImageSourceCreateWithURL(URL(fileURLWithPath: pfad) as CFURL, nil)
    guard let quelle else { return nil }
    let optionen: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: vorschauKante,
    ]
    guard
      let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, optionen as CFDictionary)
    else { return nil }
    return UIImage(cgImage: bild)
  }

  private static func videoStandbild(pfad: String) async -> UIImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: pfad)))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: CGFloat(vorschauKante), height: CGFloat(vorschauKante))
    guard let bild = try? await generator.image(at: .zero).image else { return nil }
    return UIImage(cgImage: bild)
  }
}
