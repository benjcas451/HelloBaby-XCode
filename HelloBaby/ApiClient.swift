import Foundation
import Security

/// Spricht wahlweise den lokalen Datenbestand ([LocalStore]) oder die
/// Baby-Tagebuch-REST-API an (`<serverBase>/api/...`). Endpunkte, Parameter
/// und JSON-Felder identisch zur Flutter-/Android-App.
///
/// Authentifizierung der API je nach Modus: API-Key (`X-API-Key`-Header),
/// mTLS-Client-Zertifikat und/oder Cloudflare-Access-Service-Token — auch in
/// Kombination. Medien und Thumbnails laufen seit 3.1.0 über dieselben
/// Kopfzeilen (`authHeader`), weil Cloudflare Access sonst auch sie am Rand
/// abweist.
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

  /// Ablage für Zwischenspeicher und Warteschlange des aktuellen Zugangs;
  /// nil im lokalen Modus, der ohnehin ohne Server auskommt.
  private var speicher: OfflineSpeicher? {
    let modus = AppSettings.mode
    guard modus != .local else { return nil }
    let basis = AppSettings.serverBase
    guard !basis.isEmpty else { return nil }
    return OfflineSpeicher(zugang: "\(modus.rawValue)|\(basis)")
  }

  /// Verwirft Session und mTLS-Identity, z. B. nach geänderten Einstellungen.
  func reset() {
    // Medien hängen an denselben Zugangsdaten – ihr Cache muss mit weg,
    // sonst zeigt die App nach einem Serverwechsel weiter alte Bilder.
    MedienLader.shared.reset()
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
    // Reihenfolge wahren: Steht schon etwas an, gehört auch das Neue hinten
    // dran, statt es am Stau vorbeizuschicken.
    if !(aktuelleWarteschlange?.istLeer ?? true) {
      return try await vormerken(
        kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
        images: images, diary: diary, grund: OfflineStatus.letzterGrund)
    }
    do {
      return try await ladeHoch(
        kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
        images: images, diary: diary, onSendProgress: onSendProgress)
    } catch {
      guard Netzfehler.aus(error) == .nieGesendet else { throw error }
      return try await vormerken(
        kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
        images: images, diary: diary, grund: Netzfehler.meldung(error))
    }
  }

  /// Lädt einen Eintrag samt Medien hoch. Ohne Offline-Logik — so benutzt ihn
  /// auch das Nachholen, das sonst in einer Schleife wieder vormerken würde.
  ///
  /// Medien gehen seit 3.2.0 in Stücken voraus (`ladeInStuecken`); der Eintrag
  /// selbst ist danach eine kleine Anfrage, die nur noch die Kennungen der
  /// fertigen Uploads nennt. Kennt der Server das Verfahren noch nicht,
  /// bleibt es bei der einen großen Anfrage von früher.
  private func ladeHoch(
    kalenderDatum: String, fields: [String: String], vonName: String,
    images: [URL], diary: String,
    onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> Int {
    var uploads: [String] = []
    if !images.isEmpty {
      guard let kennungen = try await ladeInStuecken(images, onSendProgress: onSendProgress)
      else {
        return try await ladeHochKlassisch(
          kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
          images: images, diary: diary, onSendProgress: onSendProgress)
      }
      uploads = kennungen
    }

    var felder: [(String, String)] = [
      ("diary", diary), ("kalender_datum", kalenderDatum), ("von_name", vonName),
    ]
    for (key, value) in fields { felder.append((key, value)) }
    for kennung in uploads { felder.append(("uploads[]", kennung)) }

    var request = URLRequest(url: try urlFuer(pfad: "entries.php", query: [:]))
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Self.formular(felder)
    request.timeoutInterval = 120
    auth(&request)
    let anfrage = request

    let data: Data
    let response: URLResponse
    if uploads.isEmpty {
      (data, response) = try await aktuelleSession().data(for: anfrage)
    } else {
      // Mit Uploads ist die Anfrage wiederholbar: Der Server merkt sich, in
      // welchen Eintrag sie eingegangen sind, und liefert bei einem zweiten
      // Versuch denselben zurück statt einen weiteren anzulegen.
      (data, response) = try await mitWiederholung {
        try await self.aktuelleSession().data(for: anfrage)
      }
    }
    let json = try Self.pruefen(data: data, response: response)
    guard let objekt = json as? [String: Any] else {
      throw ServiceError(message: "Unerwartete Antwort beim Erstellen.")
    }
    OfflineStatus.shared.melde(grund: nil)
    return objekt["id"] as? Int ?? Int("\(objekt["id"] ?? "")") ?? 0
  }

  /// Der Weg vor 3.2.0: Eintrag und alle Medien in einer einzigen
  /// multipart-Anfrage. Bleibt für Server, die das Hochladen in Stücken noch
  /// nicht kennen — hinter Cloudflare scheitert er ab 100 MB.
  private func ladeHochKlassisch(
    kalenderDatum: String, fields: [String: String], vonName: String,
    images: [URL], diary: String,
    onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil
  ) async throws -> Int {
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
    OfflineStatus.shared.melde(grund: nil)
    return objekt["id"] as? Int ?? Int("\(objekt["id"] ?? "")") ?? 0
  }

  // MARK: - Hochladen in Stücken

  /// Stückgröße, falls der Server keine nennt.
  private static let stueckStandard: Int64 = 8 * 1024 * 1024
  private static let stueckMin: Int64 = 256 * 1024
  /// Obergrenze des Servers je Stück; weit unter Cloudflares 100 MB.
  private static let stueckMax: Int64 = 64 * 1024 * 1024
  /// Versuche je Anfrage, bevor ein Verbindungsfehler durchschlägt.
  private static let versuche = 5
  private static let verarbeitungMaxSekunden: TimeInterval = 120 * 60
  /// Was der Server als Video umwandelt (wie `upload_chunks.php`).
  private static let videoEndungen: Set<String> = ["mov", "mp4", "m4v", "webm"]

  /// Antwort auf einen Upload-Schritt: Status und JSON, noch unbewertet —
  /// auch aus einem 409 liest die App noch den Stand heraus.
  private struct UploadAntwort {
    let status: Int
    let json: [String: Any]
    let data: Data

    var ok: Bool { (200..<300).contains(status) }

    func zahl(_ feld: String) -> Int64? {
      (json[feld] as? NSNumber)?.int64Value
    }
  }

  /// Lädt die Medien einzeln und in Stücken hoch und liefert ihre
  /// Upload-Kennungen in der Reihenfolge der Auswahl — oder nil, wenn der
  /// Server das Verfahren nicht kennt.
  ///
  /// Warum Stücke: Vor dem Server steht meist Cloudflare, das jede Anfrage auf
  /// 100 MB begrenzt und nach 100 Sekunden ohne Antwort abbricht. Ein längeres
  /// Video passt weder in eine Anfrage, noch darf seine Umwandlung in der
  /// Anfrage laufen, die den Eintrag anlegt. Deshalb drei Schritte am
  /// Endpunkt `entries.php`:
  ///
  /// 1. `?upload=init` meldet die Datei an und liefert Kennung und Stückgröße,
  /// 2. `?upload=chunk&id=…&offset=…` nimmt die Stücke der Reihe nach entgegen,
  /// 3. `?upload=status&id=…` sagt, wann ein Video fertig umgewandelt ist.
  ///
  /// Bis hierhin existiert der Eintrag nachweislich nicht. Ein
  /// Verbindungsabbruch wird deshalb als `UploadUnterbrochen` gemeldet — das
  /// darf in die Warteschlange, ohne ein Duplikat zu riskieren.
  private func ladeInStuecken(
    _ images: [URL], onSendProgress: (@Sendable (Int64, Int64) -> Void)?
  ) async throws -> [String]? {
    var groessen: [Int64] = []
    for url in images {
      guard let groesse = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw ServiceError(message: "Medien konnten nicht gelesen werden: \(url.lastPathComponent)")
      }
      groessen.append(Int64(groesse))
    }
    let gesamt = groessen.reduce(0, +)

    do {
      var erledigt: Int64 = 0
      var kennungen: [String] = []
      var videos: [String] = []
      for (index, url) in images.enumerated() {
        let groesse = groessen[index]
        guard
          let sitzung = try await meldeAn(
            name: url.lastPathComponent, groesse: groesse, erste: index == 0)
        else { return nil }
        let basis = erledigt
        try await sendeStuecke(
          datei: url, kennung: sitzung.kennung, groesse: groesse, stueck: sitzung.stueck
        ) { stand in
          onSendProgress?(basis + stand, gesamt)
        }
        erledigt += groesse
        kennungen.append(sitzung.kennung)
        if Self.videoEndungen.contains(url.pathExtension.lowercased()) {
          videos.append(sitzung.kennung)
        }
      }
      // Ab hier zeigt die Oberfläche „Medien werden verarbeitet…“.
      onSendProgress?(gesamt, gesamt)
      for kennung in videos {
        try await warteAufVerarbeitung(kennung)
      }
      return kennungen
    } catch {
      guard Netzfehler.aus(error) != nil else { throw error }
      throw UploadUnterbrochen(ursache: error)
    }
  }

  /// Meldet eine Datei an. Liefert nil, wenn der Server das Verfahren nicht
  /// kennt: Ein älterer Stand hält die Anfrage für einen Eintrag ohne
  /// Pflichtfelder und antwortet mit 400 — ohne das Kennzeichen
  /// `upload_fehler`, das der neue Server jeder Ablehnung mitgibt.
  ///
  /// Die erste Anmeldung wird bei einem Verbindungsfehler nicht wiederholt:
  /// Ist das Gerät schlicht offline, soll der Eintrag sofort in die
  /// Warteschlange und nicht erst nach mehreren Anläufen.
  private func meldeAn(name: String, groesse: Int64, erste: Bool) async throws
    -> (kennung: String, stueck: Int64)?
  {
    let body = Self.formular([("name", name), ("size", String(groesse))])
    let antwort: UploadAntwort
    if erste {
      antwort = try await uploadAnfrage(
        "POST", query: ["upload": "init"], body: body,
        contentType: "application/x-www-form-urlencoded")
    } else {
      antwort = try await mitWiederholung {
        try await self.uploadAnfrage(
          "POST", query: ["upload": "init"], body: body,
          contentType: "application/x-www-form-urlencoded")
      }
    }
    if antwort.ok, let kennung = antwort.json["upload_id"] as? String, !kennung.isEmpty {
      let stueck = min(
        max(antwort.zahl("chunk_size") ?? Self.stueckStandard, Self.stueckMin), Self.stueckMax)
      return (kennung, stueck)
    }
    let unbekannt =
      [400, 404, 405].contains(antwort.status)
      && (antwort.json["upload_fehler"] as? Bool) != true
    if unbekannt && erste { return nil }
    throw Self.uploadFehler(antwort)
  }

  /// Sendet die Stücke einer Datei. Nach einem Verbindungsabbruch geht es an
  /// der Stelle weiter, die der Server zuletzt bestätigt hat — nicht von vorn.
  private func sendeStuecke(
    datei: URL, kennung: String, groesse: Int64, stueck: Int64,
    melde: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let quelle: FileHandle
    do {
      quelle = try FileHandle(forReadingFrom: datei)
    } catch {
      throw ServiceError(
        message: "Medien konnten nicht gelesen werden: \(error.localizedDescription)")
    }
    defer { try? quelle.close() }

    var stand: Int64 = 0
    var fehlversuche = 0
    while stand < groesse {
      let von = stand
      let daten = try Self.lies(quelle, ab: von, laenge: Int(min(stueck, groesse - von)))
      do {
        let antwort = try await uploadAnfrage(
          "POST", query: ["upload": "chunk", "id": kennung, "offset": String(von)],
          body: daten, contentType: "application/octet-stream",
          fortschritt: { gesendet in melde(von + gesendet) })
        let bestaetigt = antwort.zahl("received")
        if antwort.ok, let bestaetigt, bestaetigt > von {
          stand = bestaetigt
        } else if antwort.status == 409, let bestaetigt, bestaetigt != von {
          // Der Server ist schon weiter, weil die Antwort auf ein Stück
          // verloren ging — dort weitermachen.
          stand = bestaetigt
        } else {
          throw Self.uploadFehler(antwort)
        }
        fehlversuche = 0
      } catch {
        guard Netzfehler.aus(error) != nil else { throw error }
        fehlversuche += 1
        if fehlversuche >= Self.versuche { throw error }
        try await Task.sleep(nanoseconds: UInt64(fehlversuche) * 2_000_000_000)
        // Ob das Stück noch ankam, weiß nur der Server.
        do {
          stand = try await uploadStatus(kennung).zahl("received") ?? von
        } catch {
          guard Netzfehler.aus(error) != nil else { throw error }
          stand = von
        }
      }
      melde(stand)
    }
  }

  /// Liest genau `laenge` Bytes ab `ab` — ein einzelner Lesezugriff darf
  /// weniger liefern, als verlangt war.
  private static func lies(_ quelle: FileHandle, ab: Int64, laenge: Int) throws -> Data {
    var daten = Data(capacity: laenge)
    do {
      try quelle.seek(toOffset: UInt64(ab))
      while daten.count < laenge {
        guard let block = try quelle.read(upToCount: laenge - daten.count), !block.isEmpty
        else { break }
        daten.append(block)
      }
    } catch {
      throw ServiceError(
        message: "Medien konnten nicht gelesen werden: \(error.localizedDescription)")
    }
    guard daten.count == laenge else {
      throw ServiceError(message: "Die Datei ist kürzer als erwartet.")
    }
    return daten
  }

  /// Wartet, bis der Server ein Video umgewandelt hat. Das läuft dort nach
  /// dem letzten Stück im Hintergrund weiter — bei langen Videos dauert es
  /// länger, als eine einzelne Anfrage offen bleiben darf.
  private func warteAufVerarbeitung(_ kennung: String) async throws {
    let ende = Date().addingTimeInterval(Self.verarbeitungMaxSekunden)
    while true {
      let stand = try await mitWiederholung { try await self.uploadStatus(kennung) }
      if (stand.json["bereit"] as? Bool) == true { return }
      if Date() > ende {
        throw ServiceError(
          message: "Der Server braucht ungewöhnlich lange für die Umwandlung des Videos.")
      }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
  }

  private func uploadStatus(_ kennung: String) async throws -> UploadAntwort {
    let antwort = try await uploadAnfrage("GET", query: ["upload": "status", "id": kennung])
    guard antwort.ok else { throw Self.uploadFehler(antwort) }
    return antwort
  }

  /// Eine Anfrage an `entries.php`, deren Antwort der Aufrufer selbst bewertet
  /// – für die Upload-Schritte und den Papierkorb. Wirft nur bei
  /// Verbindungsproblemen und einer Abweisung durch Cloudflare Access.
  private func uploadAnfrage(
    _ methode: String, query: [String: String], body: Data? = nil,
    contentType: String? = nil, fortschritt: (@Sendable (Int64) -> Void)? = nil
  ) async throws -> UploadAntwort {
    var request = URLRequest(url: try urlFuer(pfad: "entries.php", query: query))
    request.httpMethod = methode
    if let contentType {
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }
    // Der Session-Timeout (30 s) zählt die Pause zwischen EMPFANGENEN Daten —
    // während ein Stück über eine langsame Leitung hinausgeht, kommt nichts an.
    request.timeoutInterval = body == nil ? 30 : 300
    auth(&request)

    let data: Data
    let response: URLResponse
    if let body {
      // Der Delegate meldet (gesendet, erwartet) je Anfrage; hier zählt nur,
      // wie viel vom aktuellen Stück draußen ist.
      let handler: (@Sendable (Int64, Int64) -> Void)?
      if let fortschritt {
        handler = { gesendet, _ in fortschritt(gesendet) }
      } else {
        handler = nil
      }
      lock.withLock { progressHandler = handler }
      defer { lock.withLock { progressHandler = nil } }
      (data, response) = try await aktuelleSession().upload(for: request, from: body)
    } else {
      (data, response) = try await aktuelleSession().data(for: request)
    }

    guard let http = response as? HTTPURLResponse else {
      throw ServiceError(message: "Unerwartete Antwort des Servers.")
    }
    if let hinweis = CloudflareServiceToken.abweisung(http) {
      throw ServiceError(message: hinweis, statusCode: http.statusCode)
    }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return UploadAntwort(status: http.statusCode, json: json, data: data)
  }

  private static func uploadFehler(_ antwort: UploadAntwort) -> ServiceError {
    if antwort.ok { return ServiceError(message: "Unerwartete Antwort des Servers.") }
    return ServiceError(
      message: "Fehler \(antwort.status): \(meldung(aus: antwort.data))",
      statusCode: antwort.status)
  }

  /// Wiederholt einen Aufruf bei Verbindungsproblemen mit wachsender Pause.
  /// Nur für Anfragen, die der Server beliebig oft verträgt.
  private func mitWiederholung<T>(_ aufruf: () async throws -> T) async throws -> T {
    var versuch = 1
    while true {
      do {
        return try await aufruf()
      } catch {
        guard Netzfehler.aus(error) != nil, versuch < Self.versuche else { throw error }
        try await Task.sleep(nanoseconds: UInt64(versuch) * 2_000_000_000)
        versuch += 1
      }
    }
  }

  /// Kodiert Formularfelder als `application/x-www-form-urlencoded`.
  private static func formular(_ felder: [(String, String)]) -> Data {
    let erlaubt = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let paare = felder.map { feld -> String in
      let name = feld.0.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? feld.0
      let wert = feld.1.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? feld.1
      return "\(name)=\(wert)"
    }
    return Data(paare.joined(separator: "&").utf8)
  }

  /// Merkt einen Eintrag samt seiner Medien für später vor und liefert die
  /// negative lokale Kennung.
  private func vormerken(
    kalenderDatum: String, fields: [String: String], vonName: String,
    images: [URL], diary: String, grund: String
  ) async throws -> Int {
    guard let speicher else { throw ServiceError(message: grund) }
    let medien = try speicher.uebernehmeMedien(images)
    var id = -1
    schreibeWarteschlange { warteschlange in
      id = warteschlange.lege(
        kalenderDatum: kalenderDatum, fields: fields, vonName: vonName, diary: diary,
        medienOrdner: medien.ordner, medien: medien.dateien)
    }
    OfflineStatus.shared.melde(grund: grund)
    return id
  }

  func deleteEntry(id: Int, diary: String) async throws {
    if isLocal { return try await local.deleteEntry(id: id, diary: diary) }
    // Negative IDs kennt nur die App: der Eintrag wartet noch. Und solange
    // etwas ansteht, bleibt die Reihenfolge gewahrt.
    if id < 0 || !(aktuelleWarteschlange?.istLeer ?? true) {
      loescheVorgemerkt(id: id, diary: diary)
      return
    }
    do {
      try await loescheDirekt(id: id, diary: diary)
    } catch {
      guard Netzfehler.aus(error) == .nieGesendet else { throw error }
      loescheVorgemerkt(id: id, diary: diary)
      OfflineStatus.shared.melde(grund: Netzfehler.meldung(error))
    }
  }

  /// Löscht ohne Offline-Logik — so benutzt es auch das Nachholen.
  private func loescheDirekt(id: Int, diary: String) async throws {
    _ = try await senden(
      "DELETE", pfad: "entries.php", query: ["id": String(id), "diary": diary])
  }

  private func loescheVorgemerkt(id: Int, diary: String) {
    var ordner: String?
    schreibeWarteschlange { ordner = $0.loesche(id: id, diary: diary) }
    // Die Medien eines nie hochgeladenen Eintrags können gleich mit weg.
    if let ordner { speicher?.raeumeMedien(ordner: ordner) }
  }

  /// Kehrt den Favoriten-Status um und liefert den neuen Wert.
  ///
  /// `aktuell` braucht es nur für den Offline-Fall: Die API kennt lediglich
  /// „umschalten“ und liefert den neuen Wert erst in ihrer Antwort — ohne
  /// Verbindung muss die App ihn selbst bilden.
  @discardableResult
  func toggleFavorite(id: Int, diary: String, aktuell: Int = 0) async throws -> Int {
    if isLocal { return try await local.toggleFavorite(id: id, diary: diary) }
    if id < 0 || !(aktuelleWarteschlange?.istLeer ?? true) {
      schreibeWarteschlange { $0.schalteFavorit(id: id, diary: diary) }
      return aktuell == 1 ? 0 : 1
    }
    do {
      let neu = try await favoritDirekt(id: id, diary: diary)
      OfflineStatus.shared.melde(grund: nil)
      return neu
    } catch {
      guard Netzfehler.aus(error) == .nieGesendet else { throw error }
      schreibeWarteschlange { $0.schalteFavorit(id: id, diary: diary) }
      OfflineStatus.shared.melde(grund: Netzfehler.meldung(error))
      return aktuell == 1 ? 0 : 1
    }
  }

  /// Schaltet ohne Offline-Logik um — so benutzt es auch das Nachholen.
  @discardableResult
  private func favoritDirekt(id: Int, diary: String) async throws -> Int {
    var request = URLRequest(url: try urlFuer(pfad: "favorite.php", query: [:]))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "diary": diary])
    auth(&request)
    let (data, response) = try await aktuelleSession().data(for: request)
    let json = try Self.pruefen(data: data, response: response)
    return ((json as? [String: Any])?["favorit"] as? Int) ?? 0
  }

  // MARK: - Papierkorb

  /// Ob es einen Papierkorb gibt. Nur der Server hebt Gelöschtes auf; im
  /// lokalen Modus ist ein gelöschter Eintrag sofort weg.
  var hatPapierkorb: Bool { !isLocal }

  /// Die gelöschten Einträge beider Tagebücher, zuletzt Gelöschtes zuerst.
  ///
  /// Bewusst ohne Zwischenspeicher und Warteschlange: Der Papierkorb soll den
  /// Stand des Servers zeigen, und Wiederherstellen wie endgültiges Löschen
  /// sind Entscheidungen, die nicht später still nachgeholt werden.
  func getPapierkorb() async throws -> [PapierkorbEintrag] {
    let antwort = try await uploadAnfrage("GET", query: ["papierkorb": "liste"])
    guard antwort.ok, let eintraege = antwort.json["eintraege"] as? [[String: Any]] else {
      throw Self.papierkorbFehler(antwort)
    }
    return eintraege.map { PapierkorbEintrag.fromJson($0) }
  }

  /// Holt einen Eintrag samt Medien zurück und liefert seine Kennung.
  ///
  /// `diary` und `vonName` zählen nur bei Medien ohne Eintrag: Sie werden zu
  /// einem Eintrag ohne Text in diesem Tagebuch und mit diesem Ersteller.
  @discardableResult
  func papierkorbWiederherstellen(
    kennung: String, diary: String? = nil, vonName: String = ""
  ) async throws -> Int {
    var felder: [(String, String)] = []
    if let diary { felder.append(("diary", diary)) }
    if !vonName.isEmpty { felder.append(("von_name", vonName)) }
    let antwort = try await papierkorbAktion("wiederherstellen", kennung: kennung, felder: felder)
    return (antwort.json["id"] as? NSNumber)?.intValue ?? 0
  }

  /// Entfernt einen Eintrag samt Medien endgültig.
  func papierkorbLoeschen(kennung: String) async throws {
    _ = try await papierkorbAktion("loeschen", kennung: kennung)
  }

  private func papierkorbAktion(
    _ aktion: String, kennung: String, felder: [(String, String)] = []
  ) async throws -> UploadAntwort {
    let antwort = try await uploadAnfrage(
      "POST", query: ["papierkorb": aktion],
      body: Self.formular([("kennung", kennung)] + felder),
      contentType: "application/x-www-form-urlencoded")
    guard antwort.ok else { throw Self.papierkorbFehler(antwort) }
    return antwort
  }

  /// Ein Server ohne Papierkorb hält die Anfrage für eine gewöhnliche Abfrage
  /// ohne Filter und antwortet mit 400 — ohne das Kennzeichen
  /// `papierkorb_fehler`, das der neue Server jeder Ablehnung mitgibt.
  private static func papierkorbFehler(_ antwort: UploadAntwort) -> ServiceError {
    if antwort.ok || (antwort.json["papierkorb_fehler"] as? Bool) != true {
      return ServiceError(
        message: "Der Server kennt den Papierkorb noch nicht.", statusCode: antwort.status)
    }
    return uploadFehler(antwort)
  }

  // MARK: - Warteschlange

  /// Die offenen Schreibzugriffe des aktuellen Zugangs; nil im lokalen Modus.
  private var aktuelleWarteschlange: Warteschlange? {
    speicher?.ladeWarteschlange()
  }

  private func schreibeWarteschlange(_ aenderung: (inout Warteschlange) -> Void) {
    guard let speicher else { return }
    var warteschlange = speicher.ladeWarteschlange()
    aenderung(&warteschlange)
    speicher.speichere(warteschlange)
    let anzahl = warteschlange.anzahl
    Task { @MainActor in OfflineStatus.shared.melde(ausstehend: anzahl) }
  }

  /// Arbeitet die Warteschlange von vorn ab.
  ///
  /// Bricht beim ersten Verbindungsfehler ab — der Rest bleibt in der
  /// Reihenfolge stehen. Weist der Server eine Aktion inhaltlich zurück (etwa
  /// einen längst gelöschten Eintrag), fliegt sie raus und wird gemeldet;
  /// sonst blockierte sie die Warteschlange für immer.
  ///
  /// Liefert die Meldungen zu verworfenen Aktionen.
  @discardableResult
  func nachholen() async -> [String] {
    guard let speicher, !isLocal else { return [] }
    // Medienordner ohne zugehörige Aktion aufräumen – etwa nach einem
    // Absturz zwischen Kopieren und Vormerken.
    speicher.raeumeVerwaisteMedien(behalte: medienOrdnerDerWarteschlange(speicher))

    var verworfen: [String] = []
    while let naechste = speicher.ladeWarteschlange().aktionen.first {
      do {
        try await sende(naechste, speicher: speicher)
        erledige(naechste, speicher: speicher)
      } catch {
        if Netzfehler.aus(error) != nil {
          OfflineStatus.shared.melde(grund: Netzfehler.meldung(error))
          return verworfen
        }
        erledige(naechste, speicher: speicher)
        verworfen.append(error.localizedDescription)
      }
    }
    OfflineStatus.shared.melde(grund: nil)
    return verworfen
  }

  private func sende(_ aktion: Warteaktion, speicher: OfflineSpeicher) async throws {
    switch aktion {
    case .anlegen(let a):
      _ = try await ladeHoch(
        kalenderDatum: a.kalenderDatum, fields: a.fields, vonName: a.vonName,
        images: speicher.medienUrls(ordner: a.medienOrdner, dateien: a.medien),
        diary: a.diary)
    case .loeschen(let id, let diary):
      try await loescheDirekt(id: id, diary: diary)
    case .favorit(let id, let diary):
      try await favoritDirekt(id: id, diary: diary)
    }
  }

  /// Nimmt die erledigte (oder verworfene) Aktion aus der Warteschlange und
  /// räumt ihre Medien weg.
  private func erledige(_ aktion: Warteaktion, speicher: OfflineSpeicher) {
    schreibeWarteschlange { $0.entferneErste() }
    if case .anlegen(let a) = aktion { speicher.raeumeMedien(ordner: a.medienOrdner) }
  }

  private func medienOrdnerDerWarteschlange(_ speicher: OfflineSpeicher) -> Set<String> {
    var ordner = Set<String>()
    for aktion in speicher.ladeWarteschlange().aktionen {
      if case .anlegen(let a) = aktion { ordner.insert(a.medienOrdner) }
    }
    return ordner
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

  /// Führt eine Anfrage aus. Lesende Anfragen landen im Zwischenspeicher und
  /// werden bei einem Netzwerkfehler von dort beantwortet — ob die Anfrage
  /// ankam, spielt beim Lesen keine Rolle.
  private func senden(_ methode: String, pfad: String, query: [String: String])
    async throws -> Any
  {
    var request = URLRequest(url: try urlFuer(pfad: pfad, query: query))
    request.httpMethod = methode
    auth(&request)
    let lesend = methode == "GET"
    do {
      let (data, response) = try await aktuelleSession().data(for: request)
      let json = try Self.pruefen(data: data, response: response)
      if lesend {
        speicher?.speichereAntwort(data, pfad: pfad, query: query)
        OfflineStatus.shared.melde(grund: nil)
      }
      return json
    } catch {
      guard lesend, Netzfehler.aus(error) != nil,
        let daten = speicher?.ladeAntwort(pfad: pfad, query: query),
        let json = try? JSONSerialization.jsonObject(with: daten)
      else { throw error }
      OfflineStatus.shared.melde(grund: Netzfehler.meldung(error))
      return json
    }
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
    for (feld, wert) in Self.authHeader {
      request.setValue(wert, forHTTPHeaderField: feld)
    }
  }

  /// Die Kopfzeilen, mit denen sich die App ausweist – als Wörterbuch, weil
  /// auch Medien darüber laufen (`AVURLAsset` und `MedienLader` nehmen keine
  /// `URLRequest` entgegen).
  ///
  /// Der API-Key geht in jedem Server-Modus mit, sofern hinterlegt; im
  /// Cloudflare-Modus kommen die beiden Hälften des Service Tokens dazu.
  static var authHeader: [String: String] {
    var header: [String: String] = [:]
    let key = AppSettings.apiKey
    if !key.isEmpty {
      header["X-API-Key"] = key
    }
    if AppSettings.mode == .cloudflare, let token = CloudflareServiceToken.ausEinstellungen {
      header.merge(token.header) { _, neu in neu }
    }
    return header
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
    if let http = response as? HTTPURLResponse,
      let hinweis = CloudflareServiceToken.abweisung(http)
    {
      throw ServiceError(message: hinweis, statusCode: http.statusCode)
    }
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
