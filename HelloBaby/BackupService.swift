import Compression
import Foundation
import zlib

/// Erstellt und liest lokale Backups als ZIP – Dateiformat identisch zur
/// Flutter-App (package:archive): `entries.json` (Manifest, `format` = 1,
/// `bilder` portabel als `media/<ordnername>`) plus alle Mediendateien
/// unter `media/...`.
///
/// Geschrieben wird ohne Kompression (STORE); gelesen werden STORE und
/// DEFLATE, damit Backups aus der Flutter-App weiterhin funktionieren.
struct BackupService {

  func dateiname() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmm"
    return "hello_baby_backup_\(formatter.string(from: Date())).zip"
  }

  // MARK: - Export

  func export() async throws -> URL {
    let rows = try await LocalStore.shared.exportRows()
    let media = LocalStore.mediaDirectory

    var manifest: [[String: Any]] = []
    for row in rows {
      manifest.append([
        "id": row.id,
        "diary": row.diary,
        "kalender_datum": row.kalenderDatum,
        "bilder": row.bilder.isEmpty
          ? "" : "media/\((row.bilder as NSString).lastPathComponent)",
        "von_name": row.vonName,
        "favorit": row.favorit,
        "created_at": row.createdAt,
        "fields_json": row.fieldsJson,
      ])
    }
    let manifestJson = try JSONSerialization.data(
      withJSONObject: ["format": 1, "entries": manifest])

    let ziel = FileManager.default.temporaryDirectory.appendingPathComponent(dateiname())
    try? FileManager.default.removeItem(at: ziel)
    var zip = try ZipWriter(ziel: ziel)
    do {
      try zip.add(name: "entries.json", data: manifestJson)

      let fm = FileManager.default
      if let ordnerListe = try? fm.contentsOfDirectory(atPath: media.path) {
        for ordner in ordnerListe.sorted() where !ordner.hasPrefix(".") {
          let ordnerURL = media.appendingPathComponent(ordner)
          guard (try? ordnerURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
          else { continue }
          for datei in ((try? fm.contentsOfDirectory(atPath: ordnerURL.path)) ?? []).sorted()
          where !datei.hasPrefix(".") {
            try zip.add(
              name: "media/\(ordner)/\(datei)", datei: ordnerURL.appendingPathComponent(datei))
          }
        }
      }
      try zip.finish()
    } catch {
      // Kein halbes Archiv in tmp/ zurücklassen.
      try? zip.abbrechen()
      try? FileManager.default.removeItem(at: ziel)
      throw error
    }
    return ziel
  }

  // MARK: - Restore

  /// Prüft und übernimmt ein Backup vollständig; liefert die Eintragsanzahl.
  func restore(from url: URL) async throws -> Int {
    let hatZugriff = url.startAccessingSecurityScopedResource()
    defer { if hatZugriff { url.stopAccessingSecurityScopedResource() } }
    // .mappedIfSafe: der Kernel blendet das Archiv seitenweise ein, statt es
    // komplett in den Speicher zu kopieren. Bei Backups mit Videos ist das
    // der Unterschied zwischen ein paar MB und der vollen Archivgröße.
    let daten = try Data(contentsOf: url, options: .mappedIfSafe)
    let eintraege = try ZipReader.entries(in: daten)

    // Staging in tmp/, nicht in Documents: ein durch App-Kill unterbrochener
    // Restore hinterlässt sonst eine Vollkopie aller Medien im gesicherten
    // Bereich. tmp/ liegt im selben Data-Container, der abschließende
    // moveItem in LocalStore.restoreRows funktioniert also weiterhin.
    let staging = FileManager.default.temporaryDirectory
      .appendingPathComponent("restore_staging_\(UUID().uuidString)")
    let stagedMedia = staging.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: stagedMedia, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    var manifestDaten: Data?
    for eintrag in eintraege {
      let name = eintrag.name.replacingOccurrences(of: "\\", with: "/")
      if name == "entries.json" {
        manifestDaten = Data(try ZipReader.extract(eintrag, from: daten))
        continue
      }
      guard name.hasPrefix("media/"), !name.hasSuffix("/") else { continue }
      let relativ = String(name.dropFirst("media/".count))
      // Zip-Slip-Guard: keine Pfad-Ausbrüche zulassen.
      let teile = relativ.split(separator: "/").map(String.init)
      guard teile.count == 2, !teile.contains(".."), !relativ.hasPrefix("/") else {
        throw ServiceError(message: "Backup enthält einen ungültigen Pfad: \(name)")
      }
      let ordner = stagedMedia.appendingPathComponent(teile[0])
      try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
      try ZipReader.extract(eintrag, from: daten)
        .write(to: ordner.appendingPathComponent(teile[1]))
    }

    guard let manifestDaten else {
      throw ServiceError(message: "Das Backup enthält keine entries.json.")
    }
    let rows = try Self.validiere(manifest: manifestDaten, stagedMedia: stagedMedia)
    try await LocalStore.shared.restoreRows(rows, stagedMedia: stagedMedia)
    return rows.count
  }

  /// Prüft das Manifest vollständig, bevor irgendetwas ersetzt wird.
  private static func validiere(manifest: Data, stagedMedia: URL) throws -> [EntryRow] {
    guard
      let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
      json["format"] as? Int == 1,
      let eintraege = json["entries"] as? [[String: Any]]
    else {
      throw ServiceError(message: "entries.json hat ein unbekanntes Format.")
    }

    var ids = Set<Int>()
    var rows: [EntryRow] = []
    for eintrag in eintraege {
      guard let id = eintrag["id"] as? Int, id > 0, ids.insert(id).inserted else {
        throw ServiceError(message: "entries.json enthält eine ungültige oder doppelte ID.")
      }
      guard let diary = eintrag["diary"] as? String, !diary.isEmpty else {
        throw ServiceError(message: "Eintrag \(id): Tagebuch fehlt.")
      }
      guard
        let datum = eintrag["kalender_datum"] as? String,
        datum.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
      else {
        throw ServiceError(message: "Eintrag \(id): ungültiges Datum.")
      }
      let favorit = eintrag["favorit"] as? Int ?? -1
      guard favorit == 0 || favorit == 1 else {
        throw ServiceError(message: "Eintrag \(id): ungültiger Favoriten-Wert.")
      }
      let fieldsJson = eintrag["fields_json"] as? String ?? ""
      guard
        let fieldsData = fieldsJson.data(using: .utf8),
        (try? JSONSerialization.jsonObject(with: fieldsData)) is [String: Any]
      else {
        throw ServiceError(message: "Eintrag \(id): fields_json ist kein JSON-Objekt.")
      }

      let portabel = eintrag["bilder"] as? String ?? ""
      var bilder = ""
      if !portabel.isEmpty {
        guard portabel.hasPrefix("media/") else {
          throw ServiceError(message: "Eintrag \(id): ungültiger Medienpfad.")
        }
        let name = String(portabel.dropFirst("media/".count))
        guard !name.isEmpty, !name.contains("/"), name != ".." else {
          throw ServiceError(message: "Eintrag \(id): ungültiger Medienpfad.")
        }
        guard FileManager.default.fileExists(atPath: stagedMedia.appendingPathComponent(name).path)
        else {
          throw ServiceError(message: "Eintrag \(id): Medienordner \(name) fehlt im Backup.")
        }
        // Auf den Ziel-Medienordner umschreiben (absoluter Pfad wie sqflite).
        bilder = LocalStore.mediaDirectory.appendingPathComponent(name).path
      }

      rows.append(
        EntryRow(
          id: id,
          diary: diary,
          kalenderDatum: datum,
          bilder: bilder,
          vonName: eintrag["von_name"] as? String ?? "",
          favorit: favorit,
          createdAt: eintrag["created_at"] as? String ?? "",
          fieldsJson: fieldsJson))
    }
    return rows
  }
}

// MARK: - Mini-ZIP

/// Schreibt ein ZIP ohne Kompression (STORE) – ausreichend, weil Fotos und
/// Videos ohnehin schon komprimiert sind.
///
/// Geschrieben wird direkt in die Zieldatei: nur das Central Directory (ein
/// Eintrag je Datei, keine Nutzdaten) wird bis zum Schluss im Speicher
/// gehalten. Ein Medienarchiv über mehrere hundert MB lag sonst komplett im
/// Arbeitsspeicher – beim Abschluss sogar doppelt.
private struct ZipWriter {

  private let griff: FileHandle
  private var verzeichnis = Data()
  private var anzahl: UInt16 = 0
  private var offset: UInt32 = 0

  init(ziel: URL) throws {
    guard
      FileManager.default.createFile(atPath: ziel.path, contents: nil),
      let griff = try? FileHandle(forWritingTo: ziel)
    else {
      throw ServiceError(message: "Die Backup-Datei ließ sich nicht anlegen.")
    }
    self.griff = griff
  }

  mutating func add(name: String, data inhalt: Data) throws {
    try schreibe(name: name, inhalt: inhalt)
  }

  /// Nimmt eine Mediendatei auf, ohne sie ganz in den Speicher zu holen:
  /// `.mappedIfSafe` blendet sie nur ein, die Seiten kann das System jederzeit
  /// wieder verwerfen.
  mutating func add(name: String, datei: URL) throws {
    try schreibe(name: name, inhalt: try Data(contentsOf: datei, options: .mappedIfSafe))
  }

  private mutating func schreibe(name: String, inhalt: Data) throws {
    let nameDaten = Data(name.utf8)
    let crc = inhalt.withUnsafeBytes { puffer -> UInt32 in
      UInt32(crc32(0, puffer.bindMemory(to: UInt8.self).baseAddress, uInt(inhalt.count)))
    }
    let start = offset
    // ZIP32 adressiert mit 32 Bit. Vorher prüfen statt beim Umrechnen zu
    // trappen – ein Medienordner jenseits von 4 GB ist nicht abwegig.
    let ende = UInt64(start) + 30 + UInt64(nameDaten.count) + UInt64(inhalt.count)
    guard ende <= UInt64(UInt32.max) else {
      throw ServiceError(
        message: "Das Backup wäre größer als 4 GB – so viel fasst das ZIP-Format nicht.")
    }
    let groesse = UInt32(inhalt.count)

    // Local File Header
    var kopf = Data()
    kopf.append(le32(0x0403_4B50))
    kopf.append(le16(20))              // benötigte Version
    kopf.append(le16(0))               // Flags
    kopf.append(le16(0))               // Methode: STORE
    kopf.append(le16(0))               // Zeit
    kopf.append(le16(0x21))            // Datum (1.1.1980)
    kopf.append(le32(crc))
    kopf.append(le32(groesse))         // komprimiert
    kopf.append(le32(groesse))         // unkomprimiert
    kopf.append(le16(UInt16(nameDaten.count)))
    kopf.append(le16(0))               // Extra
    kopf.append(nameDaten)
    try griff.write(contentsOf: kopf)
    try griff.write(contentsOf: inhalt)
    offset = UInt32(ende)

    // Central-Directory-Eintrag
    verzeichnis.append(le32(0x0201_4B50))
    verzeichnis.append(le16(20))
    verzeichnis.append(le16(20))
    verzeichnis.append(le16(0))
    verzeichnis.append(le16(0))
    verzeichnis.append(le16(0))
    verzeichnis.append(le16(0x21))
    verzeichnis.append(le32(crc))
    verzeichnis.append(le32(groesse))
    verzeichnis.append(le32(groesse))
    verzeichnis.append(le16(UInt16(nameDaten.count)))
    verzeichnis.append(le16(0))         // Extra
    verzeichnis.append(le16(0))         // Kommentar
    verzeichnis.append(le16(0))         // Disk
    verzeichnis.append(le16(0))         // interne Attribute
    verzeichnis.append(le32(0))         // externe Attribute
    verzeichnis.append(le32(start))
    verzeichnis.append(nameDaten)
    anzahl += 1
  }

  func finish() throws {
    var ende = verzeichnis
    // End of Central Directory
    ende.append(le32(0x0605_4B50))
    ende.append(le16(0))
    ende.append(le16(0))
    ende.append(le16(anzahl))
    ende.append(le16(anzahl))
    ende.append(le32(UInt32(verzeichnis.count)))
    ende.append(le32(offset))
    ende.append(le16(0))
    try griff.write(contentsOf: ende)
    try griff.close()
  }

  func abbrechen() throws {
    try griff.close()
  }

  private func le16(_ wert: UInt16) -> Data { withUnsafeBytes(of: wert.littleEndian) { Data($0) } }
  private func le32(_ wert: UInt32) -> Data { withUnsafeBytes(of: wert.littleEndian) { Data($0) } }
}

/// Liest ZIP-Einträge über das Central Directory; unterstützt STORE und
/// DEFLATE (rohes Deflate über das Compression-Framework).
///
/// Gelesen wird direkt aus der übergebenen `Data` – bei einem per
/// `.mappedIfSafe` eingeblendeten Archiv also seitenweise aus der Datei. Für
/// STORE liefert `extract` eine Slice ohne Kopie; nur DEFLATE-Einträge müssen
/// entpackt werden. Alle Offsets stammen aus der Datei und werden deshalb
/// konsequent gegen die Puffergröße geprüft.
private enum ZipReader {

  struct Eintrag {
    let name: String
    let methode: UInt16
    let komprimiert: Int
    let unkomprimiert: Int
    let headerOffset: Int
  }

  static func entries(in daten: Data) throws -> [Eintrag] {
    // EOCD am Dateiende suchen (Signatur 0x06054b50, max. 64 KB Kommentar).
    var eocd = -1
    var index = daten.count - 22
    let grenze = max(0, daten.count - 22 - 65536)
    while index >= grenze {
      if try u32(daten, index) == 0x0605_4B50 {
        eocd = index
        break
      }
      index -= 1
    }
    guard eocd >= 0 else {
      throw ServiceError(message: "Die Datei ist kein ZIP-Archiv.")
    }
    let anzahl = Int(try u16(daten, eocd + 10))
    var position = Int(try u32(daten, eocd + 16))

    var eintraege: [Eintrag] = []
    for _ in 0..<anzahl {
      guard try u32(daten, position) == 0x0201_4B50 else {
        throw ServiceError(message: "Das ZIP-Verzeichnis ist beschädigt.")
      }
      let methode = try u16(daten, position + 10)
      let komprimiert = Int(try u32(daten, position + 20))
      let unkomprimiert = Int(try u32(daten, position + 24))
      let nameLaenge = Int(try u16(daten, position + 28))
      let extraLaenge = Int(try u16(daten, position + 30))
      let kommentarLaenge = Int(try u16(daten, position + 32))
      let headerOffset = Int(try u32(daten, position + 42))
      let name = String(decoding: try scheibe(daten, position + 46, nameLaenge), as: UTF8.self)
      eintraege.append(
        Eintrag(
          name: name, methode: methode, komprimiert: komprimiert,
          unkomprimiert: unkomprimiert, headerOffset: headerOffset))
      position += 46 + nameLaenge + extraLaenge + kommentarLaenge
    }
    return eintraege
  }

  static func extract(_ eintrag: Eintrag, from daten: Data) throws -> Data {
    let header = eintrag.headerOffset
    guard try u32(daten, header) == 0x0403_4B50 else {
      throw ServiceError(message: "Ein ZIP-Eintrag ist beschädigt.")
    }
    let nameLaenge = Int(try u16(daten, header + 26))
    let extraLaenge = Int(try u16(daten, header + 28))
    // Der lokale Header darf eigene Längen führen; deshalb hier neu lesen und
    // nicht die aus dem Central Directory wiederverwenden.
    let start = header + 30 + nameLaenge + extraLaenge
    let roh = try scheibe(daten, start, eintrag.komprimiert)

    switch eintrag.methode {
    case 0:
      return roh
    case 8:
      return try inflate(roh, erwartet: eintrag.unkomprimiert)
    default:
      throw ServiceError(
        message: "Nicht unterstützte ZIP-Kompression (Methode \(eintrag.methode)).")
    }
  }

  private static func inflate(_ quelle: Data, erwartet: Int) throws -> Data {
    guard erwartet > 0 else { return Data() }
    // baseAddress ist bei leerem Puffer nil – das darf nicht als Absturz enden.
    guard !quelle.isEmpty else {
      throw ServiceError(message: "Ein ZIP-Eintrag ließ sich nicht entpacken.")
    }
    var ziel = Data(count: erwartet)
    let geschrieben = ziel.withUnsafeMutableBytes { zielPuffer in
      quelle.withUnsafeBytes { quellPuffer in
        compression_decode_buffer(
          zielPuffer.bindMemory(to: UInt8.self).baseAddress!, erwartet,
          quellPuffer.bindMemory(to: UInt8.self).baseAddress!, quelle.count,
          nil, COMPRESSION_ZLIB)
      }
    }
    guard geschrieben == erwartet else {
      throw ServiceError(message: "Ein ZIP-Eintrag ließ sich nicht entpacken.")
    }
    return ziel
  }

  // MARK: - Begrenztes Lesen
  //
  // Alle Offsets kommen aus dem Archiv und können beschädigt oder bösartig
  // sein. Ohne diese Prüfungen beendet ein abgeschnittenes ZIP die App, statt
  // eine Fehlermeldung zu zeigen.

  /// Liefert die Bytes ab `offset`, oder wirft, wenn sie nicht vollständig im
  /// Puffer liegen. Die Slice teilt sich den Speicher mit `daten`.
  private static func scheibe(_ daten: Data, _ offset: Int, _ laenge: Int) throws -> Data {
    guard offset >= 0, laenge >= 0, offset <= daten.count, laenge <= daten.count - offset else {
      throw ServiceError(message: "Das ZIP-Archiv ist unvollständig oder beschädigt.")
    }
    let start = daten.startIndex + offset
    return daten[start..<(start + laenge)]
  }

  private static func u16(_ daten: Data, _ offset: Int) throws -> UInt16 {
    let bytes = try scheibe(daten, offset, 2)
    let start = bytes.startIndex
    return UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
  }

  private static func u32(_ daten: Data, _ offset: Int) throws -> UInt32 {
    let bytes = try scheibe(daten, offset, 4)
    let start = bytes.startIndex
    return UInt32(bytes[start]) | (UInt32(bytes[start + 1]) << 8)
      | (UInt32(bytes[start + 2]) << 16) | (UInt32(bytes[start + 3]) << 24)
  }
}
