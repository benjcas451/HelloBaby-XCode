import Foundation

struct ImportErgebnis {
  let imported: Int
  let skipped: Int
}

/// Überträgt noch nicht importierte lokale Einträge zur gewählten Server-API.
/// Pro Server-Basis-URL wird in `remote_imports` Buch geführt, damit ein
/// erneuter Import keine Duplikate erzeugt.
struct ImportService {

  func importieren(
    api: ApiClient, server: String,
    onProgress: (@Sendable (Int, Int) -> Void)? = nil
  ) async throws -> ImportErgebnis {
    var normalisiert = server.trimmingCharacters(in: .whitespaces)
    while normalisiert.hasSuffix("/") { normalisiert.removeLast() }
    guard !normalisiert.isEmpty else {
      throw ServiceError(message: "Bitte zuerst eine Server-URL eintragen.")
    }

    let store = LocalStore.shared
    let eintraege = try await store.allEntries()
    let importiert = try await store.importedLocalIds(server: normalisiert)
    let offen = eintraege.filter { !importiert.contains($0.id) }

    var anzahl = 0
    for eintrag in offen {
      onProgress?(anzahl, offen.count)
      let medien = eintrag.bilderFiles
        .map { URL(fileURLWithPath: eintrag.bilder).appendingPathComponent($0) }
        .filter { FileManager.default.fileExists(atPath: $0.path) }
      let remoteId = try await api.createEntry(
        kalenderDatum: eintrag.kalenderDatum,
        fields: eintrag.fields,
        vonName: eintrag.vonName,
        images: medien,
        diary: eintrag.diary)
      do {
        if eintrag.favorit == 1 {
          try await api.toggleFavorite(id: remoteId, diary: eintrag.diary)
        }
        try await store.markImported(
          localId: eintrag.id, diary: eintrag.diary,
          server: normalisiert, remoteId: remoteId)
      } catch {
        // Ein unvollständiger Remote-Eintrag würde beim Fortsetzen ein
        // Duplikat erzeugen — nach Möglichkeit serverseitig zurückrollen.
        try? await api.deleteEntry(id: remoteId, diary: eintrag.diary)
        throw error
      }
      anzahl += 1
      onProgress?(anzahl, offen.count)
    }

    return ImportErgebnis(imported: anzahl, skipped: eintraege.count - offen.count)
  }
}
