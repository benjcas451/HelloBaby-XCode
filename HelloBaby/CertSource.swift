import Foundation

/// Quelle für client.crt / client.key.
///
/// Standard ist der Documents-Ordner der App, sichtbar in der „Dateien“-App
/// (UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace) – derselbe Ort
/// wie bei der Flutter-App. Alternativ kann ein beliebiger Ordner gewählt
/// werden; der Zugriff darauf wird als security-scoped Bookmark gespeichert
/// (Pref-Schlüssel identisch zur Flutter-App, vorhandene Bookmarks werden
/// beim Umstieg weiter genutzt).
struct CertSource {

  static let certFileName = "client.crt"
  static let keyFileName = "client.key"

  private var documents: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  /// Für die UI lesbarer Ort der Zertifikate.
  var locationLabel: String {
    let label = AppSettings.certFolderLabel
    if !AppSettings.certFolderBookmark.isEmpty, !label.isEmpty {
      return "Ordner „\(label)“"
    }
    return "App-Ordner (Dateien-App)"
  }

  /// Merkt sich einen frei gewählten Ordner als security-scoped Bookmark.
  func uebernehmeOrdner(url: URL) throws {
    let hatZugriff = url.startAccessingSecurityScopedResource()
    defer { if hatZugriff { url.stopAccessingSecurityScopedResource() } }
    let bookmark = try url.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    AppSettings.certFolderBookmark = bookmark.base64EncodedString()
    AppSettings.certFolderLabel = url.lastPathComponent
  }

  /// Zurück zum Standard (Documents-Ordner).
  func nutzeStandardOrdner() {
    AppSettings.certFolderBookmark = ""
    AppSettings.certFolderLabel = ""
  }

  var sindVorhanden: Bool {
    (try? readCredentials()) != nil
  }

  /// Liest die Bytes von Zertifikat und privatem Schlüssel.
  func readCredentials() throws -> (cert: Data, key: Data) {
    let bookmarkB64 = AppSettings.certFolderBookmark
    guard !bookmarkB64.isEmpty, let bookmark = Data(base64Encoded: bookmarkB64) else {
      return try leseAus(ordner: documents, mitScope: false)
    }
    var stale = false
    let ordner: URL
    do {
      ordner = try URL(
        resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
        bookmarkDataIsStale: &stale)
    } catch {
      throw ServiceError(
        message: "Zertifikats-Ordner nicht mehr erreichbar – bitte erneut auswählen.")
    }
    // `stale` wurde bisher berechnet und dann verworfen. Nach einer
    // Wiederherstellung auf einem neuen Gerät löst das Bookmark oft noch auf,
    // zeigt aber ins Leere – der Nutzer sah dann „client.crt nicht gefunden“
    // statt des eigentlichen Grundes.
    guard !stale else {
      throw ServiceError(
        message: "Zertifikats-Ordner nicht mehr erreichbar – bitte erneut auswählen.")
    }
    return try leseAus(ordner: ordner, mitScope: true)
  }

  private func leseAus(ordner: URL, mitScope: Bool) throws -> (cert: Data, key: Data) {
    let hatZugriff = mitScope && ordner.startAccessingSecurityScopedResource()
    defer { if hatZugriff { ordner.stopAccessingSecurityScopedResource() } }
    guard
      let cert = Self.koordiniertLesen(ordner.appendingPathComponent(Self.certFileName)),
      let key = Self.koordiniertLesen(ordner.appendingPathComponent(Self.keyFileName))
    else {
      throw ServiceError(
        message:
          "\(Self.certFileName) oder \(Self.keyFileName) nicht gefunden (\(locationLabel)).")
    }
    return (cert, key)
  }

  /// Koordiniertes Lesen; stößt bei iCloud-Platzhaltern den Download an.
  private static func koordiniertLesen(_ url: URL) -> Data? {
    if !FileManager.default.fileExists(atPath: url.path) {
      try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
    var fehler: NSError?
    var daten: Data?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &fehler) { url in
      daten = try? Data(contentsOf: url)
    }
    return daten
  }
}
