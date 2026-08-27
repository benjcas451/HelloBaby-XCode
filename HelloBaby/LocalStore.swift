import Foundation
import SQLite3

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Roh-Zeile der Tabelle `entries` für Backup-Export/-Restore (Spaltenordnung
/// identisch zur Flutter-App: id, diary, kalender_datum, bilder, von_name,
/// favorit, created_at, fields_json).
struct EntryRow {
  var id: Int
  var diary: String
  var kalenderDatum: String
  var bilder: String
  var vonName: String
  var favorit: Int
  var createdAt: String
  var fieldsJson: String
}

/// Lokaler Modus: nutzt exakt die SQLite-Datenbank weiter, die schon die
/// Flutter-App (sqflite) angelegt hat – `Documents/HelloBaby/hello_baby.sqlite`
/// mit Schema-Version 2 (PRAGMA user_version, Tabellen `entries` und
/// `remote_imports`). Medien liegen unter `Documents/HelloBaby/media/`.
///
/// In der Spalte `bilder` stehen absolute Ordnerpfade. Der Documents-Container
/// bekommt bei jedem App-Update eine neue UUID, deshalb werden die Pfade beim
/// Lesen anhand des Ordnernamens auf den aktuellen Container umgebogen.
///
/// `@unchecked Sendable`: Das einzige veränderliche Feld (`db`) wird
/// ausschließlich auf der seriellen `queue` gelesen und geschrieben.
nonisolated final class LocalStore: @unchecked Sendable {

  static let shared = LocalStore()

  private var db: OpaquePointer?
  private let queue = DispatchQueue(label: "ch.tschir.hellobaby.local-db")

  private init() {}

  // MARK: - Pfade

  static var rootDirectory: URL {
    FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("HelloBaby")
  }

  static var mediaDirectory: URL {
    rootDirectory.appendingPathComponent("media")
  }

  /// Biegt einen (womöglich veralteten) absoluten Medienordner-Pfad auf den
  /// aktuellen Documents-Container um.
  static func heileMedienPfad(_ pfad: String) -> String {
    guard !pfad.isEmpty else { return pfad }
    let name = (pfad as NSString).lastPathComponent
    return mediaDirectory.appendingPathComponent(name).path
  }

  // MARK: - Öffnen & Schema

  private func datenbank() throws -> OpaquePointer {
    if let db { return db }
    let root = Self.rootDirectory
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(
      at: Self.mediaDirectory, withIntermediateDirectories: true)

    var handle: OpaquePointer?
    guard
      sqlite3_open(root.appendingPathComponent("hello_baby.sqlite").path, &handle) == SQLITE_OK,
      let handle
    else {
      throw ServiceError(message: "Lokale Datenbank ließ sich nicht öffnen.")
    }
    do {
      try migrieren(handle)
    } catch {
      sqlite3_close(handle)
      throw error
    }
    db = handle
    return handle
  }

  /// Identisch zur sqflite-Migration der Flutter-App (Version 1 -> 2).
  private func migrieren(_ db: OpaquePointer) throws {
    let version = skalarInt(db, "PRAGMA user_version") ?? 0
    if version == 0 {
      try ausfuehren(
        db,
        """
        CREATE TABLE IF NOT EXISTS entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          diary TEXT NOT NULL,
          kalender_datum TEXT NOT NULL,
          bilder TEXT NOT NULL DEFAULT '',
          von_name TEXT NOT NULL,
          favorit INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          fields_json TEXT NOT NULL DEFAULT '{}'
        )
        """)
      try ausfuehren(
        db, "CREATE INDEX IF NOT EXISTS entries_diary_date ON entries(diary, kalender_datum)")
    }
    if version < 2 {
      try ausfuehren(
        db,
        """
        CREATE TABLE IF NOT EXISTS remote_imports (
          local_id INTEGER NOT NULL,
          diary TEXT NOT NULL,
          server_base TEXT NOT NULL,
          remote_id INTEGER NOT NULL,
          imported_at TEXT NOT NULL,
          PRIMARY KEY (local_id, server_base)
        )
        """)
      try ausfuehren(db, "PRAGMA user_version = 2")
    }
  }

  // MARK: - Abfragen

  func getStats(diary: String) async throws -> StatsResult {
    try await auf { db in
      let rows = try self.abfragen(
        db,
        "SELECT MIN(kalender_datum) AS first, MAX(kalender_datum) AS last "
          + "FROM entries WHERE diary = ?",
        parameter: [diary])
      let first = rows.first?["first"] as? String
      let last = rows.first?["last"] as? String
      return StatsResult(first: first, last: last, randomDate: nil)
    }
  }

  func distinctDates(diary: String) async throws -> [String] {
    try await auf { db in
      try self.abfragen(
        db,
        "SELECT DISTINCT kalender_datum FROM entries WHERE diary = ? "
          + "ORDER BY kalender_datum",
        parameter: [diary]
      ).compactMap { $0["kalender_datum"] as? String }
    }
  }

  func entriesByDate(_ date: String, diary: String) async throws -> [Entry] {
    try await eintraege(
      "SELECT * FROM entries WHERE diary = ? AND kalender_datum = ? ORDER BY created_at",
      parameter: [diary, date])
  }

  func entriesByMonth(year: Int, month: Int, diary: String) async throws -> [Entry] {
    let muster = String(format: "%04d-%02d-%%", year, month)
    return try await eintraege(
      "SELECT * FROM entries WHERE diary = ? AND kalender_datum LIKE ? "
        + "ORDER BY kalender_datum, created_at",
      parameter: [diary, muster])
  }

  func favorites(diary: String) async throws -> [Entry] {
    try await eintraege(
      "SELECT * FROM entries WHERE diary = ? AND favorit = 1 "
        + "ORDER BY kalender_datum DESC, created_at DESC",
      parameter: [diary])
  }

  func entriesWithImages(diary: String) async throws -> [Entry] {
    try await eintraege(
      "SELECT * FROM entries WHERE diary = ? AND bilder <> '' "
        + "ORDER BY kalender_datum DESC, created_at DESC",
      parameter: [diary])
  }

  func allEntries() async throws -> [Entry] {
    try await eintraege("SELECT * FROM entries ORDER BY id", parameter: [])
  }

  /// Listet die Dateien eines lokalen Medienordners (sortiert, ohne versteckte).
  static func galleryFiles(folder: String) -> [String] {
    guard !folder.isEmpty else { return [] }
    let geheilt = heileMedienPfad(folder)
    let namen = (try? FileManager.default.contentsOfDirectory(atPath: geheilt)) ?? []
    return namen.filter { !$0.hasPrefix(".") }.sorted()
  }

  // MARK: - Schreiben

  func createEntry(
    kalenderDatum: String, fields: [String: String], vonName: String,
    images: [URL], diary: String
  ) async throws -> Int {
    try await auf { db in
      let createdAt = Self.isoJetzt()
      let fieldsJson = Self.jsonText(fields)
      try self.ausfuehren(
        db,
        "INSERT INTO entries (diary, kalender_datum, von_name, created_at, fields_json) "
          + "VALUES (?, ?, ?, ?, ?)",
        parameter: [diary, kalenderDatum, vonName, createdAt, fieldsJson])
      let id = Int(sqlite3_last_insert_rowid(db))
      guard !images.isEmpty else { return id }

      let ordner = Self.mediaDirectory.appendingPathComponent("\(diary)_\(id)")
      do {
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        for (index, quelle) in images.enumerated() {
          let original = quelle.lastPathComponent
          let sicher = original.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
          let name = String(format: "%03d_%@", index, sicher)
          try FileManager.default.copyItem(
            at: quelle, to: ordner.appendingPathComponent(name))
        }
        try self.ausfuehren(
          db, "UPDATE entries SET bilder = ? WHERE id = ?",
          parameter: [ordner.path, id])
      } catch {
        // Halb angelegte Einträge zurückrollen, damit kein Datenmüll bleibt.
        try? FileManager.default.removeItem(at: ordner)
        try? self.ausfuehren(db, "DELETE FROM entries WHERE id = ?", parameter: [id])
        throw ServiceError(message: "Medien konnten nicht gespeichert werden: \(error.localizedDescription)")
      }
      return id
    }
  }

  func deleteEntry(id: Int, diary: String) async throws {
    try await auf { db in
      let rows = try self.abfragen(
        db, "SELECT bilder FROM entries WHERE id = ? AND diary = ?", parameter: [id, diary])
      if let folder = rows.first?["bilder"] as? String, !folder.isEmpty {
        try? FileManager.default.removeItem(atPath: Self.heileMedienPfad(folder))
      }
      try self.ausfuehren(
        db, "DELETE FROM entries WHERE id = ? AND diary = ?", parameter: [id, diary])
      try self.ausfuehren(
        db, "DELETE FROM remote_imports WHERE local_id = ? AND diary = ?",
        parameter: [id, diary])
    }
  }

  /// Kehrt den Favoriten-Status um und liefert den neuen Wert.
  func toggleFavorite(id: Int, diary: String) async throws -> Int {
    try await auf { db in
      try self.ausfuehren(
        db, "UPDATE entries SET favorit = 1 - favorit WHERE id = ? AND diary = ?",
        parameter: [id, diary])
      let rows = try self.abfragen(
        db, "SELECT favorit FROM entries WHERE id = ? AND diary = ?", parameter: [id, diary])
      return (rows.first?["favorit"] as? Int) ?? 0
    }
  }

  // MARK: - Import-Buchhaltung (lokal -> Server)

  func importedLocalIds(server: String) async throws -> Set<Int> {
    try await auf { db in
      Set(
        try self.abfragen(
          db, "SELECT local_id FROM remote_imports WHERE server_base = ?", parameter: [server]
        ).compactMap { $0["local_id"] as? Int })
    }
  }

  func markImported(localId: Int, diary: String, server: String, remoteId: Int) async throws {
    try await auf { db in
      try self.ausfuehren(
        db,
        "INSERT OR REPLACE INTO remote_imports "
          + "(local_id, diary, server_base, remote_id, imported_at) VALUES (?, ?, ?, ?, ?)",
        parameter: [localId, diary, server, remoteId, Self.isoJetzt()])
    }
  }

  // MARK: - Backup

  func exportRows() async throws -> [EntryRow] {
    try await auf { db in
      try self.abfragen(db, "SELECT * FROM entries ORDER BY id", parameter: []).map {
        Self.rohzeile($0)
      }
    }
  }

  /// Ersetzt Datenbank und Medien durch ein zuvor vollständig geprüftes Backup.
  /// `stagedMedia` enthält die entpackten Medienordner; `bilder` in den Zeilen
  /// ist bereits auf den Ziel-Medienordner umgeschrieben.
  func restoreRows(_ rows: [EntryRow], stagedMedia: URL) async throws {
    try await auf { db in
      let fm = FileManager.default
      let media = Self.mediaDirectory
      let alt = Self.rootDirectory.appendingPathComponent("media_alt_\(UUID().uuidString)")

      // Medien tauschen; das alte Verzeichnis bleibt bis zum Erfolg liegen.
      // Es muss zum atomaren Verschieben im selben Ordner liegen, gehört als
      // Zwischenstand aber nicht ins iCloud-Backup – sonst wandert bei einem
      // Absturz mitten im Restore die gesamte Mediensammlung doppelt hinein.
      if fm.fileExists(atPath: media.path) {
        try fm.moveItem(at: media, to: alt)
        var werte = URLResourceValues()
        werte.isExcludedFromBackup = true
        var markierbar = alt
        try? markierbar.setResourceValues(werte)
      }
      do {
        try fm.moveItem(at: stagedMedia, to: media)
      } catch {
        try? fm.moveItem(at: alt, to: media)
        throw ServiceError(message: "Medien konnten nicht übernommen werden.")
      }

      do {
        try self.ausfuehren(db, "BEGIN IMMEDIATE")
        try self.ausfuehren(db, "DELETE FROM entries")
        try self.ausfuehren(db, "DELETE FROM remote_imports")
        for row in rows {
          try self.ausfuehren(
            db,
            "INSERT INTO entries (id, diary, kalender_datum, bilder, von_name, "
              + "favorit, created_at, fields_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            parameter: [
              row.id, row.diary, row.kalenderDatum, row.bilder, row.vonName,
              row.favorit, row.createdAt, row.fieldsJson,
            ])
        }
        try self.ausfuehren(db, "COMMIT")
      } catch {
        try? self.ausfuehren(db, "ROLLBACK")
        // Auch die Medien zurücklegen, damit DB und Dateien zusammenpassen.
        try? fm.removeItem(at: media)
        try? fm.moveItem(at: alt, to: media)
        throw ServiceError(message: "Backup konnte nicht eingespielt werden.")
      }
      try? fm.removeItem(at: alt)
    }
  }

  // MARK: - SQLite-Handwerk

  private func auf<T: Sendable>(
    _ arbeit: @escaping @Sendable (OpaquePointer) throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          continuation.resume(returning: try arbeit(try self.datenbank()))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private func eintraege(_ sql: String, parameter: [any Sendable]) async throws -> [Entry] {
    try await auf { db in
      try self.abfragen(db, sql, parameter: parameter).map { Self.eintrag($0) }
    }
  }

  private static func eintrag(_ zeile: [String: Any]) -> Entry {
    let row = rohzeile(zeile)
    var fields: [String: String] = [:]
    if let data = row.fieldsJson.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      for (key, value) in json {
        fields[key] = value is NSNull ? "" : (value as? String ?? "\(value)")
      }
    }
    let geheilt = row.bilder.isEmpty ? "" : heileMedienPfad(row.bilder)
    return Entry(
      id: row.id,
      diary: row.diary,
      kalenderDatum: row.kalenderDatum,
      bilder: geheilt,
      vonName: row.vonName,
      favorit: row.favorit,
      createdAt: row.createdAt,
      fields: fields,
      bilderFiles: galleryFiles(folder: geheilt))
  }

  private static func rohzeile(_ zeile: [String: Any]) -> EntryRow {
    EntryRow(
      id: zeile["id"] as? Int ?? 0,
      diary: zeile["diary"] as? String ?? "",
      kalenderDatum: zeile["kalender_datum"] as? String ?? "",
      bilder: zeile["bilder"] as? String ?? "",
      vonName: zeile["von_name"] as? String ?? "",
      favorit: zeile["favorit"] as? Int ?? 0,
      createdAt: zeile["created_at"] as? String ?? "",
      fieldsJson: zeile["fields_json"] as? String ?? "{}")
  }

  private func abfragen(_ db: OpaquePointer, _ sql: String, parameter: [any Sendable]) throws
    -> [[String: Any]]
  {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Self.fehler(db, sql)
    }
    defer { sqlite3_finalize(statement) }
    try Self.binden(statement, parameter, db: db, sql: sql)

    var zeilen: [[String: Any]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      var zeile: [String: Any] = [:]
      for spalte in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, spalte))
        switch sqlite3_column_type(statement, spalte) {
        case SQLITE_INTEGER:
          zeile[name] = Int(sqlite3_column_int64(statement, spalte))
        case SQLITE_FLOAT:
          zeile[name] = sqlite3_column_double(statement, spalte)
        case SQLITE_TEXT:
          zeile[name] = String(cString: sqlite3_column_text(statement, spalte))
        default:
          break
        }
      }
      zeilen.append(zeile)
    }
    return zeilen
  }

  private func ausfuehren(_ db: OpaquePointer, _ sql: String, parameter: [any Sendable] = []) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
      throw Self.fehler(db, sql)
    }
    defer { sqlite3_finalize(statement) }
    try Self.binden(statement, parameter, db: db, sql: sql)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw Self.fehler(db, sql)
    }
  }

  private static func binden(
    _ statement: OpaquePointer?, _ parameter: [any Sendable], db: OpaquePointer, sql: String
  ) throws {
    for (index, wert) in parameter.enumerated() {
      let position = Int32(index + 1)
      let status: Int32
      switch wert {
      case let zahl as Int:
        status = sqlite3_bind_int64(statement, position, Int64(zahl))
      case let text as String:
        status = sqlite3_bind_text(statement, position, text, -1, SQLITE_TRANSIENT)
      default:
        throw ServiceError(message: "Nicht unterstützter SQL-Parameter.")
      }
      guard status == SQLITE_OK else { throw fehler(db, sql) }
    }
  }

  private func skalarInt(_ db: OpaquePointer, _ sql: String) -> Int? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func fehler(_ db: OpaquePointer, _ sql: String) -> ServiceError {
    ServiceError(message: "Datenbankfehler: \(String(cString: sqlite3_errmsg(db)))")
  }

  /// Zeitstempel im Format von Darts `DateTime.now().toIso8601String()`.
  static func isoJetzt() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    return formatter.string(from: Date())
  }

  static func jsonText(_ fields: [String: String]) -> String {
    guard
      let data = try? JSONSerialization.data(withJSONObject: fields),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
