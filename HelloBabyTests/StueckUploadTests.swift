import CryptoKit
import Foundation
import Security
import XCTest

@testable import HelloBaby

/// Prüft das Hochladen in Stücken über die öffentliche Schnittstelle des
/// `ApiClient` — gegen einen nachgestellten Server, der sich wie
/// `upload_chunks.php` verhält (`ci/upload_attrappe.py`).
///
/// Voraussetzungen: siehe `AttrappeTestCase`.
@MainActor
final class StueckUploadTests: AttrappeTestCase {

  /// Stückgröße, die die Attrappe vorgibt — klein, damit die Tests schnell bleiben.
  private static let stueck = 512 * 1024

  // MARK: - Tests

  func testLaedtMedienInStueckenUndLegtDenEintragAn() async throws {
    try await richteEin("neu")
    defer { raeumeAuf() }
    let foto = try datei("foto.jpg", bytes: 1000)
    let video = try datei("video.mov", bytes: 3 * Self.stueck + 123)
    let gesamt = Int64(1000 + 3 * Self.stueck + 123)
    let fortschritt = Fortschritt()
    // Sonderzeichen, die in einem Formular kodiert werden müssen.
    let notiz = "Größe & Gewicht = 50% + mehr\nzweite Zeile"

    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": notiz], vonName: "Test",
      images: [foto, video], diary: "entwicklung",
      onSendProgress: { gesendet, total in fortschritt.melde(gesendet, total) })

    XCTAssertEqual(id, 1)
    let zustand = try await zustand("neu")
    let uploads = try XCTUnwrap(zustand["uploads"] as? [[String: Any]])
    XCTAssertEqual(uploads.count, 2)
    XCTAssertEqual(uploads[0]["name"] as? String, "foto.jpg")
    XCTAssertEqual(uploads[0]["sha256"] as? String, try sha(foto))
    XCTAssertEqual(uploads[0]["offsets"] as? [Int], [0])
    XCTAssertEqual(uploads[0]["status"] as? Int, 0, "ein Foto braucht keine Statusabfrage")
    XCTAssertEqual(uploads[1]["name"] as? String, "video.mov")
    XCTAssertEqual(uploads[1]["sha256"] as? String, try sha(video))
    XCTAssertEqual(
      uploads[1]["offsets"] as? [Int], [0, Self.stueck, 2 * Self.stueck, 3 * Self.stueck])
    XCTAssertEqual(
      uploads[1]["status"] as? Int, 3, "auf das Video wird gewartet, bis es umgewandelt ist")
    XCTAssertEqual(zustand["abgelehnt"] as? Int, 0)

    let eintraege = try XCTUnwrap(zustand["eintraege"] as? [[String: Any]])
    XCTAssertEqual(eintraege.count, 1)
    let felder = try XCTUnwrap(eintraege[0]["felder"] as? [String: String])
    XCTAssertEqual(felder["notiz"], notiz)
    XCTAssertEqual(felder["kalender_datum"], "2031-02-03")
    XCTAssertEqual(felder["von_name"], "Test")
    XCTAssertEqual(felder["diary"], "entwicklung")
    XCTAssertEqual(
      eintraege[0]["uploads"] as? [String], uploads.compactMap { $0["id"] as? String },
      "Reihenfolge der Medien bleibt erhalten")

    let meldungen = fortschritt.alle
    XCTAssertFalse(meldungen.isEmpty)
    XCTAssertTrue(meldungen.allSatisfy { $0.1 == gesamt && $0.0 >= 0 && $0.0 <= gesamt })
    XCTAssertEqual(meldungen.last?.0, gesamt)
  }

  func testSetztNachVerlorenerAntwortFortUndLegtNurEinenEintragAn() async throws {
    try await richteEin("abriss")
    defer { raeumeAuf() }
    let bild = try datei("gross.jpg", bytes: 4 * Self.stueck)

    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "abriss"], vonName: "Test",
      images: [bild], diary: "entwicklung")

    XCTAssertEqual(id, 1)
    let zustand = try await zustand("abriss")
    XCTAssertEqual(zustand["abrisse"] as? Int, 2, "ein Stück und das erste Anlegen blieben ohne Antwort")
    let uploads = try XCTUnwrap(zustand["uploads"] as? [[String: Any]])
    XCTAssertEqual(uploads.count, 1)
    XCTAssertEqual(uploads[0]["sha256"] as? String, try sha(bild))
    // Kein Stück ging doppelt hinaus: die App hat den Stand erfragt.
    XCTAssertEqual(
      uploads[0]["offsets"] as? [Int], [0, Self.stueck, 2 * Self.stueck, 3 * Self.stueck])
    XCTAssertEqual(zustand["abgelehnt"] as? Int, 0)
    let eintraege = try XCTUnwrap(zustand["eintraege"] as? [[String: Any]])
    XCTAssertEqual(eintraege.count, 1, "die wiederholte Anfrage legt keinen zweiten Eintrag an")
    XCTAssertEqual(eintraege[0]["anfragen"] as? Int, 2)
  }

  func testFaelltBeiEinemServerOhneDasVerfahrenAufMultipartZurueck() async throws {
    try await richteEin("alt")
    defer { raeumeAuf() }
    let foto = try datei("foto.jpg", bytes: 5000)

    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "alt"], vonName: "Test",
      images: [foto], diary: "entwicklung")

    XCTAssertEqual(id, 1)
    let zustand = try await zustand("alt")
    XCTAssertEqual((zustand["uploads"] as? [Any])?.count, 0)
    let eintraege = try XCTUnwrap(zustand["eintraege"] as? [[String: Any]])
    XCTAssertEqual(eintraege.count, 1)
    XCTAssertEqual(eintraege[0]["multipart_images"] as? Int, 1)
    XCTAssertGreaterThan(eintraege[0]["koerper_bytes"] as? Int ?? 0, 5000)
  }

  func testOhneVerbindungWandertDerEintragSofortInDieWarteschlange() async throws {
    try await richteEin("neu")
    defer { raeumeAuf() }
    // Auf Port 1 lauscht niemand: Verbindungsaufbau scheitert sofort.
    AppSettings.serverBase = "http://127.0.0.1:1"
    ApiClient.shared.reset()
    let foto = try datei("foto.jpg", bytes: 1000)

    let start = Date()
    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "offline"], vonName: "Test",
      images: [foto], diary: "entwicklung")

    XCTAssertLessThan(id, 0, "vorgemerkte Einträge tragen eine negative Kennung")
    XCTAssertLessThan(Date().timeIntervalSince(start), 10, "kein mehrfacher Anlauf, wenn das Gerät offline ist")
    try await ApiClient.shared.deleteEntry(id: id, diary: "entwicklung")
  }

  func testUnbekannterHostWandertDerEintragSofortInDieWarteschlange() async throws {
    try await richteEin("neu")
    defer { raeumeAuf() }
    // `.invalid` löst nie auf (RFC 2606): die Anfrage geht gar nicht erst hinaus.
    AppSettings.serverBase = "https://hellobaby.invalid"
    ApiClient.shared.reset()
    let foto = try datei("foto.jpg", bytes: 1000)

    let start = Date()
    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "offline"], vonName: "Test",
      images: [foto], diary: "entwicklung")
    let dauer = Date().timeIntervalSince(start)

    XCTAssertLessThan(id, 0, "vorgemerkte Einträge tragen eine negative Kennung")
    XCTAssertLessThan(dauer, 15, "kein mehrfacher Anlauf, wenn der Server nicht erreichbar ist")
    try await ApiClient.shared.deleteEntry(id: id, diary: "entwicklung")
  }

  func testBleibenDieStueckeHaengenWandertDerEintragInDieWarteschlange() async throws {
    try await richteEin("haengt")
    defer { raeumeAuf() }
    let foto = try datei("foto.jpg", bytes: 1000)

    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "haengt"], vonName: "Test",
      images: [foto], diary: "entwicklung")

    XCTAssertLessThan(id, 0)
    let zustand = try await zustand("haengt")
    XCTAssertEqual(zustand["abrisse"] as? Int, 5, "fünf Anläufe, dann gibt die App auf")
    XCTAssertEqual((zustand["eintraege"] as? [Any])?.count, 0, "der Eintrag wurde nie angelegt")
    try await ApiClient.shared.deleteEntry(id: id, diary: "entwicklung")
  }

  // MARK: - Helfer

  /// Legt eine Datei mit zufälligem Inhalt an.
  private func datei(_ name: String, bytes: Int) throws -> URL {
    let ordner = FileManager.default.temporaryDirectory
      .appendingPathComponent("stueck-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    let url = ordner.appendingPathComponent(name)
    var inhalt = Data(count: bytes)
    let status = inhalt.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
    }
    XCTAssertEqual(status, errSecSuccess)
    try inhalt.write(to: url)
    return url
  }

  private func sha(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Sammelt Fortschrittsmeldungen, die von der URLSession-Delegate-Queue kommen.
private final class Fortschritt: @unchecked Sendable {
  private let lock = NSLock()
  private var werte: [(Int64, Int64)] = []

  func melde(_ gesendet: Int64, _ gesamt: Int64) {
    lock.lock()
    werte.append((gesendet, gesamt))
    lock.unlock()
  }

  var alle: [(Int64, Int64)] {
    lock.lock()
    defer { lock.unlock() }
    return werte
  }
}
