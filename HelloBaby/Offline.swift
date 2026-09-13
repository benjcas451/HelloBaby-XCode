import Combine
import Foundation
import Network

// MARK: - Warteschlange

/// Ein Schreibzugriff, der offline erfasst wurde und noch zum Server muss.
enum Warteaktion: Codable, Equatable {
  case anlegen(Anlegen)
  case loeschen(id: Int, diary: String)
  /// Favoriten-Status umschalten (die API kennt nur „umschalten“, keinen
  /// Zielwert).
  case favorit(id: Int, diary: String)

  /// Ein offline erfasster neuer Eintrag samt seiner Medien.
  struct Anlegen: Codable, Equatable {
    /// Negative Kennung, unter der der Eintrag bis zum Hochladen geführt wird.
    let lokaleId: Int
    let kalenderDatum: String
    let fields: [String: String]
    let vonName: String
    let diary: String
    /// Unterordner in der Medien-Ablage der Warteschlange.
    let medienOrdner: String
    /// Dateinamen darin, in der Reihenfolge der Auswahl. Bewusst nicht die
    /// ursprünglichen Pfade: Ein Bild aus der Fotomediathek liegt in einem
    /// temporären Ordner, den das System jederzeit räumen darf.
    let medien: [String]
  }
}

/// Die geordnete Liste der offenen Schreibzugriffe eines Zugangs.
struct Warteschlange: Codable, Equatable {

  private(set) var aktionen: [Warteaktion] = []
  /// Zähler für die nächste lokale Kennung (läuft ins Negative).
  private var naechsteLokaleId: Int = -1

  var istLeer: Bool { aktionen.isEmpty }
  var anzahl: Int { aktionen.count }

  mutating func lege(
    kalenderDatum: String, fields: [String: String], vonName: String, diary: String,
    medienOrdner: String, medien: [String]
  ) -> Int {
    let id = naechsteLokaleId
    naechsteLokaleId -= 1
    aktionen.append(
      .anlegen(
        .init(
          lokaleId: id, kalenderDatum: kalenderDatum, fields: fields, vonName: vonName,
          diary: diary, medienOrdner: medienOrdner, medien: medien)))
    return id
  }

  /// Nimmt eine Löschung auf. Einen Eintrag, der noch gar nicht beim Server
  /// war, wirft sie ersatzlos aus der Warteschlange – samt seiner
  /// Favoriten-Umschaltungen. Liefert dessen Medienordner, damit der Aufrufer
  /// die Dateien wegräumen kann.
  mutating func loesche(id: Int, diary: String) -> String? {
    if let index = indexDesAnlegens(id) {
      guard case .anlegen(let a) = aktionen[index] else { return nil }
      aktionen.remove(at: index)
      aktionen.removeAll {
        if case .favorit(let fid, _) = $0 { return fid == id }
        return false
      }
      return a.medienOrdner
    }
    aktionen.append(.loeschen(id: id, diary: diary))
    return nil
  }

  mutating func schalteFavorit(id: Int, diary: String) {
    aktionen.append(.favorit(id: id, diary: diary))
  }

  mutating func entferneErste() {
    if !aktionen.isEmpty { aktionen.removeFirst() }
  }

  private func indexDesAnlegens(_ id: Int) -> Int? {
    guard id < 0 else { return nil }
    return aktionen.firstIndex {
      if case .anlegen(let a) = $0 { return a.lokaleId == id }
      return false
    }
  }
}

// MARK: - Ablage

/// Legt Antwort-Zwischenspeicher, Warteschlange und deren Medien je Zugang im
/// App-Verzeichnis ab.
///
/// Der Schlüssel ist Modus plus Server-URL: Wer zwischen zwei Servern
/// wechselt, bekommt nicht die Einträge des anderen zu sehen und lädt auch
/// keine Warteschlange dorthin hoch, wo sie nicht hingehört.
struct OfflineSpeicher {

  private let ordner: URL
  private let schluessel: String

  init(zugang: String) {
    schluessel = zugang.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    let basis = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ordner = basis.appendingPathComponent("Offline", isDirectory: true)
    try? FileManager.default.createDirectory(at: antwortOrdner, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: medienBasis, withIntermediateDirectories: true)
  }

  private var antwortOrdner: URL {
    ordner.appendingPathComponent("antworten_\(schluessel)", isDirectory: true)
  }

  /// Basis der Medien wartender Einträge. Bewusst ausserhalb von `Caches`:
  /// Diese Dateien sind die einzigen Kopien, bis der Upload durch ist.
  private var medienBasis: URL {
    ordner.appendingPathComponent("medien_\(schluessel)", isDirectory: true)
  }

  private var warteschlangeUrl: URL {
    ordner.appendingPathComponent("warteschlange_\(schluessel).json")
  }

  // MARK: Antworten

  /// Dateiname einer Anfrage: Pfad plus sortierte Parameter, damit dieselbe
  /// Abfrage denselben Eintrag trifft.
  private func antwortUrl(pfad: String, query: [String: String]) -> URL {
    let teile = query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
    let roh = "\(pfad)?\(teile)"
    let name = roh.map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    return antwortOrdner.appendingPathComponent("\(name).json")
  }

  func ladeAntwort(pfad: String, query: [String: String]) -> Data? {
    try? Data(contentsOf: antwortUrl(pfad: pfad, query: query))
  }

  func speichereAntwort(_ daten: Data, pfad: String, query: [String: String]) {
    try? daten.write(to: antwortUrl(pfad: pfad, query: query), options: .atomic)
  }

  // MARK: Warteschlange

  func ladeWarteschlange() -> Warteschlange {
    guard let daten = try? Data(contentsOf: warteschlangeUrl),
      let warteschlange = try? JSONDecoder().decode(Warteschlange.self, from: daten)
    else { return Warteschlange() }
    return warteschlange
  }

  func speichere(_ warteschlange: Warteschlange) {
    guard let daten = try? JSONEncoder().encode(warteschlange) else { return }
    try? daten.write(to: warteschlangeUrl, options: .atomic)
  }

  // MARK: Medien

  /// Kopiert die gewählten Dateien in einen eigenen Ordner der Warteschlange
  /// und liefert dessen Namen samt der Dateinamen darin.
  ///
  /// Kopiert wird bewusst: Die Originale liegen je nach Quelle in einem
  /// temporären Ordner, den das System räumen darf, bevor der Upload läuft.
  func uebernehmeMedien(_ urls: [URL]) throws -> (ordner: String, dateien: [String]) {
    let name = UUID().uuidString
    let ziel = medienBasis.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: ziel, withIntermediateDirectories: true)
    var dateien: [String] = []
    for (index, quelle) in urls.enumerated() {
      // Nummeriert, damit die Reihenfolge erhalten bleibt und gleiche
      // Dateinamen aus verschiedenen Ordnern sich nicht überschreiben.
      let dateiname = "\(index)_\(quelle.lastPathComponent)"
      try FileManager.default.copyItem(at: quelle, to: ziel.appendingPathComponent(dateiname))
      dateien.append(dateiname)
    }
    return (name, dateien)
  }

  func medienUrls(ordner: String, dateien: [String]) -> [URL] {
    let basis = medienBasis.appendingPathComponent(ordner, isDirectory: true)
    return dateien.map { basis.appendingPathComponent($0) }
  }

  /// Räumt den Medienordner einer erledigten oder verworfenen Aktion weg.
  func raeumeMedien(ordner: String) {
    try? FileManager.default.removeItem(
      at: medienBasis.appendingPathComponent(ordner, isDirectory: true))
  }

  /// Entfernt Medienordner, zu denen keine Aktion mehr existiert – etwa nach
  /// einem Absturz zwischen Kopieren und Vormerken.
  func raeumeVerwaisteMedien(behalte: Set<String>) {
    let inhalt =
      (try? FileManager.default.contentsOfDirectory(
        at: medienBasis, includingPropertiesForKeys: nil)) ?? []
    for url in inhalt where !behalte.contains(url.lastPathComponent) {
      try? FileManager.default.removeItem(at: url)
    }
  }
}

// MARK: - Zustand

/// Der Offline-Zustand, den die Oberfläche anzeigt.
@MainActor
final class OfflineStatus: ObservableObject {

  static let shared = OfflineStatus()

  /// Grund der letzten gescheiterten Verbindung; nil heisst „online“.
  @Published private(set) var grund: String?
  /// Anzahl der Schreibzugriffe, die noch auf Übertragung warten.
  @Published private(set) var ausstehend = 0

  /// Der zuletzt gemeldete Grund, auch ausserhalb des MainActor lesbar –
  /// der Client braucht ihn, wenn er einen Eintrag wegen der Reihenfolge
  /// vormerkt, ohne selbst auf einen Fehler gelaufen zu sein.
  nonisolated(unsafe) private(set) static var letzterGrund = "Keine Verbindung zum Server"

  var istOffline: Bool { grund != nil }

  func melde(grund: String?) {
    self.grund = grund
    if let grund { Self.letzterGrund = grund }
  }
  func melde(ausstehend: Int) { self.ausstehend = ausstehend }

  /// Setzt alles zurück – beim Wechsel der Datenquelle.
  func zuruecksetzen() {
    grund = nil
    ausstehend = 0
  }
}

// MARK: - Verbindungswache

/// Meldet, sobald wieder ein Netzwerkpfad da ist — damit die Warteschlange
/// nicht erst beim nächsten Antippen abgearbeitet wird.
@MainActor
final class Verbindungswache: ObservableObject {

  static let shared = Verbindungswache()

  /// Feuert bei jedem Wechsel von „kein Pfad“ zu „Pfad da“.
  let wiederVerbunden = PassthroughSubject<Void, Never>()

  private let wache = NWPathMonitor()
  private var warOffline = false

  private init() {
    wache.pathUpdateHandler = { [weak self] pfad in
      let verbunden = pfad.status == .satisfied
      Task { @MainActor in self?.pfadGeaendert(verbunden) }
    }
    wache.start(queue: DispatchQueue(label: "hellobaby.verbindungswache"))
  }

  private func pfadGeaendert(_ verbunden: Bool) {
    if verbunden, warOffline { wiederVerbunden.send(()) }
    warOffline = !verbunden
  }
}
