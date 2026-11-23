import SwiftUI

// MARK: - Reiter „Galerie“ (alle Einträge mit Medien, 3er-Raster nach Tagen)

struct ImageFeedView: View {

  let diary: String
  let schluessel: String
  let onNeuLaden: () async -> Void

  @State private var gruppen: [Tagesgruppe] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var vollbild: VollbildKontext?
  @State private var intern = 0

  private let api = ApiClient.shared
  private let spalten = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: "Die Galerie konnte nicht geladen werden. \(fehler)") { intern += 1 }
      } else {
        ScrollView {
          Group {
            if gruppen.isEmpty {
              LeerAnsicht(text: "Noch keine Einträge mit Fotos oder Videos")
            } else {
              LazyVGrid(columns: spalten, spacing: 6) {
                ForEach(gruppen) { gruppe in
                  Section {
                    ForEach(gruppe.kacheln) { kachel in
                      zelle(kachel)
                    }
                  } header: {
                    MhGruppenLabel(HbDatum.mitWochentag(gruppe.datum))
                      .frame(maxWidth: .infinity, alignment: .leading)
                  }
                }
              }
            }
          }
          .padding(.horizontal, Mh.rand)
          .padding(.bottom, Mh.abstand8)
          .hbBreite()
        }
        .refreshable { await onNeuLaden() }
      }
    }
    .task(id: "\(schluessel)/\(intern)") { await laden() }
    .fullScreenCover(item: $vollbild) { kontext in
      FullscreenGalleryView(
        folder: kontext.folder, dateien: kontext.dateien, start: kontext.start)
    }
  }

  @ViewBuilder
  private func zelle(_ kachel: Tagesgruppe.Kachel) -> some View {
    let thumb = MediaThumb(folder: kachel.entry.bilder, file: kachel.datei)
    if isVideoFile(kachel.datei) {
      NavigationLink(value: Ziel.video(url: thumb.quelle)) {
        MedienKachel(thumb: thumb)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Video")
    } else {
      Button {
        let bilder = kachel.entry.bilderFiles.filter(isImageFile)
        vollbild = VollbildKontext(
          folder: kachel.entry.bilder,
          dateien: bilder,
          start: bilder.firstIndex(of: kachel.datei) ?? 0)
      } label: {
        MedienKachel(thumb: thumb)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Foto")
    }
  }

  private func laden() async {
    laedt = gruppen.isEmpty
    fehler = nil
    do {
      let eintraege = try await api.getEntriesWithImages(diary: diary)
      guard !Task.isCancelled else { return }
      gruppen = Tagesgruppe.aus(eintraege)
    } catch {
      guard !Task.isCancelled else { return }
      fehler = error.localizedDescription
      gruppen = []
    }
    laedt = false
  }
}

/// Quadratische Medienkachel mit kleinem Radius.
struct MedienKachel: View {
  let thumb: MediaThumb

  var body: some View {
    thumb
      .aspectRatio(1, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(Mh.surfaceSubtle)
      .clipShape(RoundedRectangle(cornerRadius: Mh.radiusSm, style: .continuous))
  }
}

/// Ein Tag der Galerie mit seinen Kacheln.
///
/// Wird einmal in `laden()` gebaut statt als computed property aus `body`:
/// dort liefen Gruppierung und Sortierung bei jeder Recomposition erneut –
/// also auch beim Scrollen und bei jedem Antippen.
struct Tagesgruppe: Identifiable {

  struct Kachel: Identifiable {
    let id: String
    let entry: Entry
    let datei: String
  }

  let datum: String
  let kacheln: [Kachel]

  var id: String { datum }

  static func aus(_ eintraege: [Entry]) -> [Tagesgruppe] {
    Dictionary(grouping: eintraege, by: \.kalenderDatum)
      .sorted { $0.key > $1.key }
      .map { datum, tagesEintraege in
        Tagesgruppe(
          datum: datum,
          kacheln: tagesEintraege.flatMap { eintrag in
            eintrag.bilderFiles.filter { isImageFile($0) || isVideoFile($0) }.map {
              Kachel(id: "\(eintrag.id)/\($0)", entry: eintrag, datei: $0)
            }
          })
      }
  }
}

struct VollbildKontext: Identifiable {
  let id = UUID()
  let folder: String
  let dateien: [String]
  let start: Int
}

// MARK: - Galerie eines Eintrags

struct GalleryView: View {

  let folder: String

  @State private var dateien: [String] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var vollbild: VollbildKontext?
  @State private var meldung: String?

  private let api = ApiClient.shared
  private let spalten = Array(repeating: GridItem(.flexible(), spacing: 6), count: 2)

  private var medien: [String] { dateien.filter { isImageFile($0) || isVideoFile($0) } }
  private var andere: [String] { dateien.filter { !isImageFile($0) && !isVideoFile($0) } }

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: "Die Fotos konnten nicht geladen werden. \(fehler)") {
          Task { await laden() }
        }
      } else if dateien.isEmpty {
        LeerAnsicht(text: "Keine Dateien zu diesem Eintrag")
          .frame(maxHeight: .infinity, alignment: .top)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: spalten, spacing: 6) {
              ForEach(medien, id: \.self) { datei in
                zelle(datei)
              }
            }
            .padding(.top, Mh.abstand2)
            if !andere.isEmpty {
              MhGruppenLabel("Weitere Dateien")
              ForEach(Array(andere.enumerated()), id: \.element) { index, datei in
                if index > 0 { MhTrennlinie() }
                andereDatei(datei)
              }
            }
          }
          .padding(.horizontal, Mh.rand)
          .padding(.bottom, Mh.abstand8)
          .hbBreite()
        }
        .refreshable { await laden() }
      }
    }
    .background(Mh.bg.ignoresSafeArea())
    .navigationTitle("Fotos")
    .navigationBarTitleDisplayMode(.large)
    .task { await laden() }
    .fullScreenCover(item: $vollbild) { kontext in
      FullscreenGalleryView(
        folder: kontext.folder, dateien: kontext.dateien, start: kontext.start)
    }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
  }

  @ViewBuilder
  private func zelle(_ datei: String) -> some View {
    let thumb = MediaThumb(folder: folder, file: datei)
    if isVideoFile(datei) {
      NavigationLink(value: Ziel.video(url: thumb.quelle)) {
        MedienKachel(thumb: thumb)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Video")
    } else {
      Button {
        let bilder = dateien.filter(isImageFile)
        vollbild = VollbildKontext(
          folder: folder, dateien: bilder, start: bilder.firstIndex(of: datei) ?? 0)
      } label: {
        MedienKachel(thumb: thumb)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Foto")
    }
  }

  /// Dateien, die die App nicht anzeigt (HEIC, PSD …): nur zum Herunterladen.
  private func andereDatei(_ datei: String) -> some View {
    let endung = (datei as NSString).pathExtension.uppercased()
    return Button {
      if isLocalMediaSource(folder) {
        meldung = "Dieses Format kann nur am Rechner geöffnet werden."
      } else {
        meldung = "Download-Link: \(api.mediaUrl(folder + "/" + datei, download: true))"
      }
    } label: {
      MhListenZeile(
        datei, untertitel: endung.isEmpty ? "Nur Download" : "\(endung) – nur Download",
        symbol: "MhDownload")
    }
    .buttonStyle(.plain)
  }

  private func laden() async {
    laedt = dateien.isEmpty
    fehler = nil
    do {
      dateien = try await api.getGalleryFiles(folder: folder)
    } catch {
      fehler = error.localizedDescription
      dateien = []
    }
    laedt = false
  }
}

// MARK: - Vollbild mit Blättern und Zoom

struct FullscreenGalleryView: View {

  let folder: String
  let dateien: [String]
  let start: Int

  @Environment(\.dismiss) private var dismiss
  @State private var index = 0

  var body: some View {
    NavigationStack {
      TabView(selection: $index) {
        ForEach(Array(dateien.enumerated()), id: \.offset) { position, datei in
          ZoombaresBild(folder: folder, file: datei)
            .tag(position)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: .never))
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("\(index + 1) / \(dateien.count)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbarBackground(Color.black, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            MhSymbol("MhClose")
          }
          .tint(Color.white)
          .accessibilityLabel("Schließen")
        }
      }
    }
    .onAppear { index = start }
  }
}

/// Ein Bild mit Pinch-Zoom und Verschieben.
private struct ZoombaresBild: View {

  let folder: String
  let file: String

  @State private var zoom: CGFloat = 1
  @State private var basisZoom: CGFloat = 1
  @State private var versatz: CGSize = .zero
  @State private var basisVersatz: CGSize = .zero

  var body: some View {
    GeometryReader { geometrie in
      inhalt
        .frame(width: geometrie.size.width, height: geometrie.size.height)
        .scaleEffect(zoom)
        .offset(versatz)
        .gesture(
          MagnifyGesture()
            .onChanged { wert in
              zoom = max(1, min(5, basisZoom * wert.magnification))
            }
            .onEnded { _ in
              basisZoom = zoom
              if zoom <= 1.01 { zuruecksetzen() }
            }
        )
        .simultaneousGesture(
          DragGesture()
            .onChanged { wert in
              guard zoom > 1 else { return }
              versatz = CGSize(
                width: basisVersatz.width + wert.translation.width,
                height: basisVersatz.height + wert.translation.height)
            }
            .onEnded { _ in basisVersatz = versatz }
        )
        .onTapGesture(count: 2) {
          if zoom > 1 { zuruecksetzen() } else {
            zoom = 2
            basisZoom = 2
          }
        }
    }
    .background(Color.black)
  }

  @ViewBuilder
  private var inhalt: some View {
    if isLocalMediaSource(folder) {
      if let bild = UIImage(contentsOfFile: folder + "/" + file) {
        Image(uiImage: bild).resizable().scaledToFit()
      } else {
        MhSymbol("MhImage", groesse: Mh.symbolGross).foregroundStyle(Color.white)
      }
    } else {
      MedienBild(url: ApiClient.shared.mediaUrl(folder + "/" + file)) { bild in
        bild.resizable().scaledToFit()
      } platzhalter: {
        ProgressView().tint(.white)
      } fehler: {
        MhSymbol("MhImage", groesse: Mh.symbolGross).foregroundStyle(Color.white)
      }
    }
  }

  private func zuruecksetzen() {
    zoom = 1
    basisZoom = 1
    versatz = .zero
    basisVersatz = .zero
  }
}
