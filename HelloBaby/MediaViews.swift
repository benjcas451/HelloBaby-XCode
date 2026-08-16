import SwiftUI

// MARK: - Bilder-Feed (Galerie über alle Einträge)

struct ImageFeedView: View {

  @State private var eintraege: [Entry] = []
  @State private var laedt = true
  @State private var fehler: String?
  @State private var vollbild: VollbildKontext?

  private let api = ApiClient.shared
  private let spalten = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if eintraege.isEmpty {
        LeerAnsicht(symbol: "photo.on.rectangle", text: "Noch keine Bilder vorhanden.")
      } else {
        ScrollView {
          LazyVGrid(columns: spalten, spacing: 4) {
            ForEach(gruppen, id: \.datum) { gruppe in
              Section {
                ForEach(gruppe.kacheln, id: \.id) { kachel in
                  zelle(kachel)
                }
              } header: {
                Text(HbDatum.mitWochentag(gruppe.datum))
                  .font(.subheadline.bold())
                  .foregroundStyle(Hb.accentDeep)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.vertical, 6)
              }
            }
          }
          .padding(.horizontal, 8)
        }
      }
    }
    .hbHintergrund()
    .navigationTitle("Galerie")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          Task { await laden() }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    .task { await laden() }
    .fullScreenCover(item: $vollbild) { kontext in
      FullscreenGalleryView(
        folder: kontext.folder, dateien: kontext.dateien, start: kontext.start)
    }
  }

  private struct Kachel {
    let id: String
    let entry: Entry
    let datei: String
  }

  private var gruppen: [(datum: String, kacheln: [Kachel])] {
    let sortiert = Dictionary(grouping: eintraege, by: \.kalenderDatum)
      .sorted { $0.key > $1.key }
    return sortiert.map { datum, tagesEintraege in
      var kacheln: [Kachel] = []
      for eintrag in tagesEintraege {
        for datei in eintrag.bilderFiles {
          kacheln.append(Kachel(id: "\(eintrag.id)/\(datei)", entry: eintrag, datei: datei))
        }
      }
      return (datum: datum, kacheln: kacheln)
    }
  }

  @ViewBuilder
  private func zelle(_ kachel: Kachel) -> some View {
    let thumb = MediaThumb(folder: kachel.entry.bilder, file: kachel.datei)
    if isVideoFile(kachel.datei) {
      NavigationLink(value: Ziel.video(url: thumb.quelle)) {
        thumb.aspectRatio(1, contentMode: .fit)
      }
      .buttonStyle(.plain)
    } else {
      Button {
        let bilder = kachel.entry.bilderFiles.filter(isImageFile)
        vollbild = VollbildKontext(
          folder: kachel.entry.bilder,
          dateien: bilder,
          start: bilder.firstIndex(of: kachel.datei) ?? 0)
      } label: {
        thumb.aspectRatio(1, contentMode: .fit)
      }
      .buttonStyle(.plain)
    }
  }

  private func laden() async {
    laedt = eintraege.isEmpty
    fehler = nil
    do {
      eintraege = try await api.getEntriesWithImages(diary: AppSettings.activeDiary)
    } catch {
      fehler = error.localizedDescription
      eintraege = []
    }
    laedt = false
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

  var body: some View {
    Group {
      if laedt {
        LadeAnsicht()
      } else if let fehler {
        FehlerAnsicht(text: fehler) { Task { await laden() } }
      } else if dateien.isEmpty {
        LeerAnsicht(symbol: "photo", text: "Dieser Ordner enthält keine Medien.")
      } else {
        ScrollView {
          VStack(spacing: 12) {
            ForEach(dateien, id: \.self) { datei in
              zelle(datei)
            }
          }
          .padding()
        }
      }
    }
    .hbHintergrund()
    .navigationTitle("Galerie")
    .navigationBarTitleDisplayMode(.inline)
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
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if isVideoFile(datei) {
          NavigationLink(value: Ziel.video(url: thumb.quelle)) {
            thumb.frame(height: 240).frame(maxWidth: .infinity)
          }
          .buttonStyle(.plain)
        } else if isImageFile(datei) {
          Button {
            let bilder = dateien.filter(isImageFile)
            vollbild = VollbildKontext(
              folder: folder, dateien: bilder, start: bilder.firstIndex(of: datei) ?? 0)
          } label: {
            thumb.frame(height: 240).frame(maxWidth: .infinity)
          }
          .buttonStyle(.plain)
        } else {
          Button {
            if isLocalMediaSource(folder) {
              meldung = "Dieses Format kann nur am Rechner geöffnet werden."
            } else {
              meldung = "Download-Link: \(api.mediaUrl(thumb.quelle, download: true))"
            }
          } label: {
            HStack {
              Image(systemName: "arrow.down.doc")
              Text("\(datei) – nur Download")
              Spacer()
            }
            .padding()
          }
          .buttonStyle(.plain)
        }
      }
      Text(datei)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
    .hbKarte()
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
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
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
        Image(systemName: "photo").foregroundStyle(.white)
      }
    } else {
      AsyncImage(url: URL(string: ApiClient.shared.mediaUrl(folder + "/" + file))) { phase in
        switch phase {
        case .success(let bild):
          bild.resizable().scaledToFit()
        case .failure:
          Image(systemName: "photo").foregroundStyle(.white)
        default:
          ProgressView().tint(.white)
        }
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
