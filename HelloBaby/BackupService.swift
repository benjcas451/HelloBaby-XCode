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

    var zip = ZipWriter()
    zip.add(name: "entries.json", data: manifestJson)

    let fm = FileManager.default
    if let ordnerListe = try? fm.contentsOfDirectory(atPath: media.path) {
      for ordner in ordnerListe.sorted() where !ordner.hasPrefix(".") {
        let ordnerURL = media.appendingPathComponent(ordner)
        guard (try? ordnerURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        else { continue }
        for datei in ((try? fm.contentsOfDirectory(atPath: ordnerURL.path)) ?? []).sorted()
        where !datei.hasPrefix(".") {
          let daten = try Data(contentsOf: ordnerURL.appendingPathComponent(datei))
          zip.add(name: "media/\(ordner)/\(datei)", data: daten)
        }
      }
    }

    let ziel = FileManager.default.temporaryDirectory.appendingPathComponent(dateiname())
    try zip.finish().write(to: ziel)
    return ziel
  }

  // MARK: - Restore

  /// Prüft und übernimmt ein Backup vollständig; liefert die Eintragsanzahl.
  func restore(from url: URL) async throws -> Int {
    let hatZugriff = url.startAccessingSecurityScopedResource()
    defer { if hatZugriff { url.stopAccessingSecurityScopedResource() } }
    let daten = try Data(contentsOf: url)
    let eintraege = try ZipReader.entries(in: daten)

    let staging = LocalStore.rootDirectory
      .appendingPathComponent("restore_staging_\(UUID().uuidString)")
    let stagedMedia = staging.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: stagedMedia, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    var manifestDaten: Data?
    for eintrag in eintraege {
      let name = eintrag.name.replacingOccurrences(of: "\\", with: "/")
      if name == "entries.json" {
        manifestDaten = try ZipReader.extract(eintrag, from: daten)
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
private struct ZipWriter {

  private var daten = Data()
  private var verzeichnis = Data()
  private var anzahl: UInt16 = 0

  mutating func add(name: String, data inhalt: Data) {
    let nameDaten = Data(name.utf8)
    let offset = UInt32(daten.count)
    let crc = inhalt.withUnsafeBytes { puffer -> UInt32 in
      UInt32(crc32(0, puffer.bindMemory(to: UInt8.self).baseAddress, uInt(inhalt.count)))
    }
    let groesse = UInt32(inhalt.count)

    // Local File Header
    daten.append(le32(0x0403_4B50))
    daten.append(le16(20))              // benötigte Version
    daten.append(le16(0))               // Flags
    daten.append(le16(0))               // Methode: STORE
    daten.append(le16(0))               // Zeit
    daten.append(le16(0x21))            // Datum (1.1.1980)
    daten.append(le32(crc))
    daten.append(le32(groesse))         // komprimiert
    daten.append(le32(groesse))         // unkomprimiert
    daten.append(le16(UInt16(nameDaten.count)))
    daten.append(le16(0))               // Extra
    daten.append(nameDaten)
    daten.append(inhalt)

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
    verzeichnis.append(le32(offset))
    verzeichnis.append(nameDaten)
    anzahl += 1
  }

  func finish() -> Data {
    var ergebnis = daten
    ergebnis.append(verzeichnis)
    // End of Central Directory
    ergebnis.append(le32(0x0605_4B50))
    ergebnis.append(le16(0))
    ergebnis.append(le16(0))
    ergebnis.append(le16(anzahl))
    ergebnis.append(le16(anzahl))
    ergebnis.append(le32(UInt32(verzeichnis.count)))
    ergebnis.append(le32(UInt32(daten.count)))
    ergebnis.append(le16(0))
    return ergebnis
  }

  private func le16(_ wert: UInt16) -> Data { withUnsafeBytes(of: wert.littleEndian) { Data($0) } }
  private func le32(_ wert: UInt32) -> Data { withUnsafeBytes(of: wert.littleEndian) { Data($0) } }
}

/// Liest ZIP-Einträge über das Central Directory; unterstützt STORE und
/// DEFLATE (rohes Deflate über das Compression-Framework).
private enum ZipReader {

  struct Eintrag {
    let name: String
    let methode: UInt16
    let komprimiert: Int
    let unkomprimiert: Int
    let headerOffset: Int
  }

  static func entries(in daten: Data) throws -> [Eintrag] {
    let bytes = [UInt8](daten)
    // EOCD am Dateiende suchen (Signatur 0x06054b50, max. 64 KB Kommentar).
    var eocd = -1
    var index = bytes.count - 22
    let grenze = max(0, bytes.count - 22 - 65536)
    while index >= grenze {
      if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
        bytes[index + 2] == 0x05, bytes[index + 3] == 0x06
      {
        eocd = index
        break
      }
      index -= 1
    }
    guard eocd >= 0 else {
      throw ServiceError(message: "Die Datei ist kein ZIP-Archiv.")
    }
    let anzahl = Int(u16(bytes, eocd + 10))
    var position = Int(u32(bytes, eocd + 16))

    var eintraege: [Eintrag] = []
    for _ in 0..<anzahl {
      guard u32(bytes, position) == 0x0201_4B50 else {
        throw ServiceError(message: "Das ZIP-Verzeichnis ist beschädigt.")
      }
      let methode = u16(bytes, position + 10)
      let komprimiert = Int(u32(bytes, position + 20))
      let unkomprimiert = Int(u32(bytes, position + 24))
      let nameLaenge = Int(u16(bytes, position + 28))
      let extraLaenge = Int(u16(bytes, position + 30))
      let kommentarLaenge = Int(u16(bytes, position + 32))
      let headerOffset = Int(u32(bytes, position + 42))
      let name =
        String(bytes: bytes[(position + 46)..<(position + 46 + nameLaenge)], encoding: .utf8) ?? ""
      eintraege.append(
        Eintrag(
          name: name, methode: methode, komprimiert: komprimiert,
          unkomprimiert: unkomprimiert, headerOffset: headerOffset))
      position += 46 + nameLaenge + extraLaenge + kommentarLaenge
    }
    return eintraege
  }

  static func extract(_ eintrag: Eintrag, from daten: Data) throws -> Data {
    let bytes = [UInt8](daten)
    let header = eintrag.headerOffset
    guard u32(bytes, header) == 0x0403_4B50 else {
      throw ServiceError(message: "Ein ZIP-Eintrag ist beschädigt.")
    }
    let nameLaenge = Int(u16(bytes, header + 26))
    let extraLaenge = Int(u16(bytes, header + 28))
    let start = header + 30 + nameLaenge + extraLaenge
    guard start + eintrag.komprimiert <= bytes.count else {
      throw ServiceError(message: "Ein ZIP-Eintrag ist unvollständig.")
    }
    let roh = Data(bytes[start..<(start + eintrag.komprimiert)])

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

  private static func u16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
    UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
  }

  private static func u32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8)
      | (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
  }
}
