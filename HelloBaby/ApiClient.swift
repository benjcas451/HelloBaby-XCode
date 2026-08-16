import Foundation
import Security

/// Spricht wahlweise den lokalen Datenbestand ([LocalStore]) oder die
/// Baby-Tagebuch-REST-API an (`<serverBase>/api/...`). Endpunkte, Parameter
/// und JSON-Felder identisch zur Flutter-/Android-App.
///
/// Authentifizierung der API je nach Modus: API-Key (`X-API-Key`-Header)
/// und/oder mTLS-Client-Zertifikat. Medien und Thumbnails liefert der Server
/// ohne Authentifizierung aus.
final class ApiClient: NSObject, @unchecked Sendable {

  static let shared = ApiClient()

  private let lock = NSLock()
  // Nur unter `lock` angefasst; nonisolated(unsafe), weil URLSession-Delegates
  // auf beliebigen Queues laufen.
  nonisolated(unsafe) private var session: URLSession?
  nonisolated(unsafe) private var sessionMode: DataSourceMode?
  nonisolated(unsafe) private var identity: SecIdentity?
  nonisolated(unsafe) private var progressHandler: (@Sendable (Int64, Int64) -> Void)?

  private var local: LocalStore { .shared }

  private var isLocal: Bool { AppSettings.mode == .local }

  private var apiBase: String {
    get throws {
      let base = AppSettings.serverBase
      guard !base.isEmpty else {
        throw ServiceError(
          message: "Keine Server-URL konfiguriert. Bitte in den Einstellungen "
            + "die Basis-URL hinterlegen.")
      }
      return base + "/api"
    }
  }

  /// Verwirft Session und mTLS-Identity, z. B. nach geänderten Einstellungen.
  func reset() {
    lock.lock()
    session?.invalidateAndCancel()
    session = nil
    sessionMode = nil
    identity = nil
    lock.unlock()
  }

  // MARK: - Medien-URLs (ohne Auth)

  func mediaUrl(_ relPath: String, download: Bool = false) -> String {
    let base = (try? apiBase) ?? ""
    let pfad = relPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relPath
    return "\(base)/media.php?file=\(pfad)" + (download ? "&download=1" : "")
  }

  func thumbUrl(_ relPath: String, width: Int = 400) -> String {
    let base = (try? apiBase) ?? ""
    let pfad = relPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? relPath
    return "\(base)/thumb.php?file=\(pfad)&w=\(width)"
  }

  // MARK: - Endpunkte

  func getStats(diary: String) async throws -> StatsResult {
    if isLocal { return try await local.getStats(diary: diary) }
    let json = try await objekt("GET", pfad: "stats.php", query: ["diary": diary])
    return StatsResult(
      first: json["first"] as? String,
      last: json["last"] as? String,
      randomDate: json["random_date"] as? String)
  }

  /// Zufälliges Datum, das `excludeDate` möglichst vermeidet (bis zu 5
  /// Versuche; gibt es nur einen Tag, ist die Wiederholung erlaubt).
  func getRandomDate(diary: String, excludeDate: String?) async throws -> String? {
    if isLocal {
      let dates = try await local.distinctDates(diary: diary)
      return RandomDay.pick(dates: dates, excluding: excludeDate)
    }
    var stats = try await getStats(diary: diary)
    for _ in 0..<5 {
      guard let datum = stats.randomDate else { return nil }
      if datum != excludeDate || stats.first == stats.last { return datum }
      stats = try await getStats(diary: diary)
    }
    return stats.randomDate
  }

  func getEntriesByDate(_ date: String, diary: String) async throws -> [Entry] {
    if isLocal { return try await local.entriesByDate(date, diary: diary) }
    return try await eintraege(query: ["date": date, "diary": diary], diary: diary)
  }

  func getEntriesByMonth(year: Int, month: Int, diary: String) async throws -> [Entry] {
    if isLocal { return try await local.entriesByMonth(year: year, month: month, diary: diary) }
    return try await eintraege(
      query: ["year": String(year), "month": String(month), "diary": diary], diary: diary)
  }

  func getFavorites(diary: String) async throws -> [Entry] {
    if isLocal { return try await local.favorites(diary: diary) }
    return try await eintraege(query: ["favorites": "1", "diary": diary], diary: diary)
  }

  func getEntriesWithImages(diary: String) async throws -> [Entry] {
    if isLocal { return try await local.entriesWithImages(diary: diary) }
    return try await eintraege(query: ["images": "1", "diary": diary], diary: diary)
  }

  /// Dateien einer Galerie (Server: gallery.php, lokal: Ordnerinhalt).
  func getGalleryFiles(folder: String) async throws -> [String] {
    if isLocal || isLocalMediaSource(folder) {
      return LocalStore.galleryFiles(folder: folder)
    }
    let json = try await objekt("GET", pfad: "gallery.php", query: ["folder": folder])
    let files = (json["files"] as? [Any])?.compactMap { $0 as? String } ?? []
    return files.filter { !($0 as NSString).lastPathComponent.hasPrefix(".") }
  }

  func createEntry(
    kalenderDatum: String, fields: [String: String], vonName: String,
    images: [URL], diary: String,
    onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> Int {
    if isLocal {
      return try await local.createEntry(
        kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
        images: images, diary: diary)
    }

    // Den Multipart-Body in eine temporäre Datei streamen statt in den
    // Speicher: Videos können hunderte MB groß sein.
    let boundary = "hellobaby-\(UUID().uuidString)"
    let bodyURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("upload_\(UUID().uuidString).tmp")
    FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: bodyURL) }
    let ausgabe = try FileHandle(forWritingTo: bodyURL)
    func schreib(_ text: String) throws {
      try ausgabe.write(contentsOf: Data(text.utf8))
    }
    func feld(_ name: String, _ wert: String) throws {
      try schreib("--\(boundary)\r\n")
      try schreib("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(wert)\r\n")
    }
    do {
      try feld("diary", diary)
      try feld("kalender_datum", kalenderDatum)
      try feld("von_name", vonName)
      for (key, value) in fields { try feld(key, value) }
      for url in images {
        try schreib("--\(boundary)\r\n")
        try schreib(
          "Content-Disposition: form-data; name=\"images[]\"; "
            + "filename=\"\(url.lastPathComponent)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n")
        let quelle = try FileHandle(forReadingFrom: url)
        while let stueck = try quelle.read(upToCount: 1 << 20), !stueck.isEmpty {
          try ausgabe.write(contentsOf: stueck)
        }
        try quelle.close()
        try schreib("\r\n")
      }
      try schreib("--\(boundary)--\r\n")
      try ausgabe.close()
    } catch {
      try? ausgabe.close()
      throw ServiceError(
        message: "Medien konnten nicht vorbereitet werden: \(error.localizedDescription)")
    }

    var request = URLRequest(url: try urlFuer(pfad: "entries.php", query: [:]))
    request.httpMethod = "POST"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    // Der Session-Timeout (30 s) ist ein Leerlauf-Timer für EMPFANGENE Daten —
    // während eines langen Uploads kommt aber nichts an und die Anfrage bräche
    // ab. Für Uploads deshalb großzügig erhöhen (deckt Upload + serverseitige
    // Verarbeitung großer Videos ab).
    request.timeoutInterval = 3600
    auth(&request)

    lock.withLock { progressHandler = onSendProgress }
    defer { lock.withLock { progressHandler = nil } }

    let (data, response) = try await aktuelleSession().upload(for: request, fromFile: bodyURL)
    let json = try Self.pruefen(data: data, response: response)
    guard let objekt = json as? [String: Any] else {
      throw ServiceError(message: "Unerwartete Antwort beim Erstellen.")
    }
    return objekt["id"] as? Int ?? Int("\(objekt["id"] ?? "")") ?? 0
  }

  func deleteEntry(id: Int, diary: String) async throws {
    if isLocal { return try await local.deleteEntry(id: id, diary: diary) }
    _ = try await senden(
      "DELETE", pfad: "entries.php", query: ["id": String(id), "diary": diary])
  }

  /// Kehrt den Favoriten-Status um und liefert den neuen Wert.
  @discardableResult
  func toggleFavorite(id: Int, diary: String) async throws -> Int {
    if isLocal { return try await local.toggleFavorite(id: id, diary: diary) }
    var request = URLRequest(url: try urlFuer(pfad: "favorite.php", query: [:]))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "diary": diary])
    auth(&request)
    let (data, response) = try await aktuelleSession().data(for: request)
    let json = try Self.pruefen(data: data, response: response)
    return ((json as? [String: Any])?["favorit"] as? Int) ?? 0
  }

  // MARK: - Transport

  private func eintraege(query: [String: String], diary: String) async throws -> [Entry] {
    let json = try await senden("GET", pfad: "entries.php", query: query)
    guard let array = json as? [Any] else {
      throw ServiceError(message: "Unerwartete Antwort (keine Liste).")
    }
    return array.compactMap { ($0 as? [String: Any]).map { Entry.fromJson($0, diary: diary) } }
  }

  private func objekt(_ methode: String, pfad: String, query: [String: String])
    async throws -> [String: Any]
  {
    guard let json = try await senden(methode, pfad: pfad, query: query) as? [String: Any] else {
      throw ServiceError(message: "Unerwartete Antwort (kein JSON-Objekt).")
    }
    return json
  }

  private func senden(_ methode: String, pfad: String, query: [String: String])
    async throws -> Any
  {
    var request = URLRequest(url: try urlFuer(pfad: pfad, query: query))
    request.httpMethod = methode
    auth(&request)
    let (data, response) = try await aktuelleSession().data(for: request)
    return try Self.pruefen(data: data, response: response)
  }

  private func urlFuer(pfad: String, query: [String: String]) throws -> URL {
    var komponenten = URLComponents(string: "\(try apiBase)/\(pfad)")
    if !query.isEmpty {
      komponenten?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = komponenten?.url else {
      throw ServiceError(message: "Ungültige Server-URL.")
    }
    return url
  }

  private func auth(_ request: inout URLRequest) {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let key = AppSettings.apiKey
    if !key.isEmpty {
      request.setValue(key, forHTTPHeaderField: "X-API-Key")
    }
  }

  /// Baut die Session lazily; bei Moduswechsel (mTLS an/aus) neu.
  private func aktuelleSession() throws -> URLSession {
    let modus = AppSettings.mode
    lock.lock()
    defer { lock.unlock() }
    if let session, sessionMode == modus { return session }

    if modus == .mtls {
      let (cert, key) = try CertSource().readCredentials()
      identity = try ClientIdentity.make(certPEM: cert, keyPEM: key)
    } else {
      identity = nil
    }
    let konfiguration = URLSessionConfiguration.ephemeral
    konfiguration.timeoutIntervalForRequest = 30
    let neu = URLSession(configuration: konfiguration, delegate: self, delegateQueue: nil)
    session?.invalidateAndCancel()
    session = neu
    sessionMode = modus
    return neu
  }

  private static func pruefen(data: Data, response: URLResponse) throws -> Any {
    guard let http = response as? HTTPURLResponse else {
      throw ServiceError(message: "Unerwartete Antwort des Servers.")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ServiceError(
        message: "Fehler \(http.statusCode): \(meldung(aus: data))",
        statusCode: http.statusCode)
    }
    if data.isEmpty { return [String: Any]() }
    guard let json = try? JSONSerialization.jsonObject(with: data) else {
      throw ServiceError(message: "Unerwartete Antwort (kein JSON).")
    }
    return json
  }

  /// Zieht `{"error": "..."}` heraus bzw. kürzt eine HTML-Fehlerseite.
  private static func meldung(aus data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = json["error"] as? String, !text.isEmpty
    {
      return text
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if clean.isEmpty { return "Anfrage fehlgeschlagen" }
    return clean.count > 200 ? String(clean.prefix(200)) + "…" : clean
  }
}

extension ApiClient: URLSessionTaskDelegate {

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    lock.lock()
    let handler = progressHandler
    lock.unlock()
    handler?(totalBytesSent, totalBytesExpectedToSend)
  }

  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    lock.lock()
    let identity = identity
    lock.unlock()
    guard
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
      let identity
    else {
      // Server-Zertifikat weiterhin normal gegen den System-Trust-Store prüfen.
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(
      .useCredential,
      URLCredential(identity: identity, certificates: nil, persistence: .forSession))
  }
}
