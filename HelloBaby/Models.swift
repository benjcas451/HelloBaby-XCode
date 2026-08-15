import Foundation

/// Fehler aus Datenlayer und API mit für Menschen lesbarer Meldung.
struct ServiceError: LocalizedError {
  let message: String
  var statusCode: Int?
  var errorDescription: String? { message }

  init(message: String, statusCode: Int? = nil) {
    self.message = message
    self.statusCode = statusCode
  }
}

/// Ein Eingabefeld eines Tagebuchs (identisch zur Flutter-App).
struct DiaryField: Hashable {
  let key: String
  let label: String
  let unit: String
  let numeric: Bool
  let textarea: Bool
  let required: Bool

  init(
    key: String, label: String, unit: String = "",
    numeric: Bool = false, textarea: Bool = false, required: Bool = false
  ) {
    self.key = key
    self.label = label
    self.unit = unit
    self.numeric = numeric
    self.textarea = textarea
    self.required = required
  }
}

/// Ein Tagebuch (Schwangerschaft oder Entwicklung).
struct Diary: Hashable {
  let id: String
  let title: String
  let fields: [DiaryField]
}

/// Beide Tagebücher mit exakt den Feldern der Flutter-App.
let kDiaries: [String: Diary] = [
  "schwangerschaft": Diary(
    id: "schwangerschaft",
    title: "Schwangerschaftstagebuch",
    fields: [
      DiaryField(key: "gewicht", label: "Gewicht", unit: "kg", numeric: true),
      DiaryField(key: "bauchumfang", label: "Bauchumfang", unit: "cm", numeric: true),
      DiaryField(key: "empfinden", label: "Empfinden", textarea: true, required: true),
      DiaryField(key: "gelueste", label: "Gelüste", textarea: true),
      DiaryField(key: "sonstiges", label: "Sonstiges", textarea: true),
    ]),
  "entwicklung": Diary(
    id: "entwicklung",
    title: "Entwicklungstagebuch",
    fields: [
      DiaryField(key: "gewicht", label: "Gewicht", unit: "kg", numeric: true),
      DiaryField(key: "groesse", label: "Größe", unit: "cm", numeric: true),
      DiaryField(key: "kopfumfang", label: "Kopfumfang", unit: "cm", numeric: true),
      DiaryField(key: "notiz", label: "Meilenstein / Notiz", textarea: true, required: true),
      DiaryField(key: "sonstiges", label: "Sonstiges", textarea: true),
    ]),
]

let kDefaultDiary = "schwangerschaft"

/// Ein Tagebuch-Eintrag; `fields` hält die dynamischen Tagebuch-Felder.
struct Entry: Identifiable, Hashable {
  let id: Int
  let diary: String
  let kalenderDatum: String
  /// Medienordner: lokal ein absoluter Pfad, im Server-Modus `uploads/<ordner>`.
  let bilder: String
  let vonName: String
  var favorit: Int
  let createdAt: String
  let fields: [String: String]
  let bilderFiles: [String]

  /// Baut einen Eintrag aus einer API-Antwort (Feld-Whitelist wie Flutter).
  static func fromJson(_ json: [String: Any], diary: String) -> Entry {
    let commonKeys: Set<String> = [
      "id", "diary", "kalender_datum", "bilder", "von_name",
      "favorit", "created_at", "bilder_files",
    ]
    var fields: [String: String] = [:]
    for (key, value) in json where !commonKeys.contains(key) {
      fields[key] = stringWert(value)
    }
    return Entry(
      id: intWert(json["id"]),
      diary: (json["diary"] as? String) ?? diary,
      kalenderDatum: (json["kalender_datum"] as? String) ?? "",
      bilder: (json["bilder"] as? String) ?? "",
      vonName: (json["von_name"] as? String) ?? "",
      favorit: intWert(json["favorit"]),
      createdAt: (json["created_at"] as? String) ?? "",
      fields: fields,
      bilderFiles: (json["bilder_files"] as? [Any])?.compactMap { $0 as? String } ?? [])
  }

  private static func intWert(_ value: Any?) -> Int {
    if let zahl = value as? Int { return zahl }
    if let text = value as? String { return Int(text) ?? 0 }
    if let zahl = value as? Double { return Int(zahl) }
    return 0
  }

  private static func stringWert(_ value: Any?) -> String {
    if value == nil || value is NSNull { return "" }
    if let text = value as? String { return text }
    return "\(value!)"
  }
}

/// Erster/letzter Eintrag und ein zufälliges Datum eines Tagebuchs.
struct StatsResult {
  let first: String?
  let last: String?
  let randomDate: String?
}

/// Wählt einen zufälligen Tag, ohne den zuletzt gezeigten zu wiederholen
/// (außer es gibt nur einen).
enum RandomDay {
  static func pick(dates: [String], excluding last: String?) -> String? {
    guard !dates.isEmpty else { return nil }
    let kandidaten = dates.filter { $0 != last }
    return (kandidaten.isEmpty ? dates : kandidaten).randomElement()
  }
}

// MARK: - Medien-Helfer (Endungslisten identisch zur Flutter-App)

private let kImageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
private let kVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
private let kDownloadOnlyExtensions: Set<String> = ["heic", "psd"]

private func endung(_ name: String) -> String {
  (name as NSString).pathExtension.lowercased()
}

func isImageFile(_ name: String) -> Bool { kImageExtensions.contains(endung(name)) }
func isVideoFile(_ name: String) -> Bool { kVideoExtensions.contains(endung(name)) }
func isDownloadOnlyFile(_ name: String) -> Bool { kDownloadOnlyExtensions.contains(endung(name)) }

/// Lokale Quellen sind absolute Pfade, Server-Quellen relative `uploads/...`.
func isLocalMediaSource(_ source: String) -> Bool { source.hasPrefix("/") }
