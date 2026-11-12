import Foundation
import XCTest

@testable import HelloBaby

/// Prüft den Papierkorb über die öffentliche Schnittstelle des `ApiClient`
/// gegen den nachgestellten Server (Voraussetzungen: siehe
/// `AttrappeTestCase`) und die Beschriftung der Karten.
@MainActor
final class PapierkorbTests: AttrappeTestCase {

  func testGeloeschterEintragLaesstSichWiederherstellen() async throws {
    try await richteEin("neu")
    defer { raeumeAuf() }
    let notiz = "Erstes Lächeln & mehr"
    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": notiz, "gewicht": "5,4"], vonName: "Celine",
      images: [], diary: "entwicklung")

    let leer = try await ApiClient.shared.getPapierkorb()
    XCTAssertTrue(leer.isEmpty)

    try await ApiClient.shared.deleteEntry(id: id, diary: "entwicklung")
    let korb = try await ApiClient.shared.getPapierkorb()
    XCTAssertEqual(korb.count, 1)
    let eintrag = try XCTUnwrap(korb.first)
    XCTAssertEqual(eintrag.diary, "entwicklung")
    XCTAssertTrue(eintrag.wiederherstellbar)
    XCTAssertEqual(eintrag.tageUebrig, 30)
    XCTAssertEqual(eintrag.eintrag.id, id)
    XCTAssertEqual(eintrag.eintrag.kalenderDatum, "2031-02-03")
    XCTAssertEqual(eintrag.eintrag.vonName, "Celine")
    XCTAssertEqual(eintrag.eintrag.fields["notiz"], notiz)
    XCTAssertEqual(eintrag.eintrag.fields["gewicht"], "5,4")
    XCTAssertEqual(eintrag.titel, "Entwicklung: Eintrag vom 03.02.2031")

    let zurueck = try await ApiClient.shared.papierkorbWiederherstellen(kennung: eintrag.kennung)
    XCTAssertEqual(zurueck, id)
    let danach = try await ApiClient.shared.getPapierkorb()
    XCTAssertTrue(danach.isEmpty)
    let zustand = try await zustand("neu")
    XCTAssertEqual((zustand["eintraege"] as? [Any])?.count, 1)

    // Ein zweites Mal gibt es nichts mehr zurückzuholen.
    do {
      _ = try await ApiClient.shared.papierkorbWiederherstellen(kennung: eintrag.kennung)
      XCTFail("Fehler erwartet")
    } catch let fehler as ServiceError {
      XCTAssertEqual(fehler.statusCode, 404)
    }
  }

  func testEndgueltigLoeschenEntferntDenEintrag() async throws {
    try await richteEin("neu")
    defer { raeumeAuf() }
    let id = try await ApiClient.shared.createEntry(
      kalenderDatum: "2031-02-03", fields: ["notiz": "weg"], vonName: "Test",
      images: [], diary: "entwicklung")
    try await ApiClient.shared.deleteEntry(id: id, diary: "entwicklung")
    let korb = try await ApiClient.shared.getPapierkorb()
    let eintrag = try XCTUnwrap(korb.first)

    try await ApiClient.shared.papierkorbLoeschen(kennung: eintrag.kennung)

    let danach = try await ApiClient.shared.getPapierkorb()
    XCTAssertTrue(danach.isEmpty)
    let zustand = try await zustand("neu")
    XCTAssertEqual((zustand["eintraege"] as? [Any])?.count, 0)
    XCTAssertEqual((zustand["papierkorb"] as? [Any])?.count, 0)
  }

  func testServerOhnePapierkorbWirdErkannt() async throws {
    try await richteEin("alt")
    defer { raeumeAuf() }
    do {
      _ = try await ApiClient.shared.getPapierkorb()
      XCTFail("Fehler erwartet")
    } catch let fehler as ServiceError {
      XCTAssertEqual(fehler.message, "Der Server kennt den Papierkorb noch nicht.")
    }
  }

  func testBeschriftetDieKarten() throws {
    // So antwortet `entries.php?papierkorb=liste`.
    let json = """
      [{"kennung":"20261112_135210_edata_42","diary":"entwicklung",
        "geloescht":"2026-11-12 13:52:10","verfaellt":"2026-12-12","tage_uebrig":30,
        "wiederherstellbar":true,"medien":2,"bytes":21076582,
        "eintrag":{"id":42,"kalender_datum":"2026-11-03","bilder":"uploads/20261103_101500_abc",
                   "von_name":"Celine","favorit":1,"created_at":"2026-11-03 10:15:00",
                   "gewicht":"5,4","groesse":"","kopfumfang":"0","notiz":"Erstes Lächeln","sonstiges":""}},
       {"kennung":"20261112_134431_altlast_20250727_134229_68862cc5dc2a1","diary":null,
        "geloescht":"2026-11-12 13:44:31","verfaellt":"2026-12-12","tage_uebrig":1,
        "wiederherstellbar":false,"medien":1,"bytes":1677721,
        "eintrag":{"id":0,"kalender_datum":"2025-07-27","bilder":"uploads/20250727_134229_68862cc5dc2a1",
                   "von_name":"","favorit":0,"created_at":""}}]
      """
    let roh = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    let eintrag = PapierkorbEintrag.fromJson(roh[0])
    let ohneEintrag = PapierkorbEintrag.fromJson(roh[1])

    XCTAssertEqual(eintrag.eintrag.id, 42)
    XCTAssertEqual(eintrag.eintrag.favorit, 1)
    XCTAssertEqual(eintrag.bytes, 21_076_582)
    XCTAssertEqual(eintrag.titel, "Entwicklung: Eintrag vom 03.11.2026")
    XCTAssertEqual(eintrag.medienText, "2 Fotos/Videos (20,1 MB)")
    XCTAssertEqual(
      eintrag.fristText,
      "Gelöscht am 12.11.2026 13:52 · wird am 12.12.2026 endgültig entfernt (noch 30 Tage)")

    XCTAssertEqual(ohneEintrag.diary, "")
    XCTAssertFalse(ohneEintrag.wiederherstellbar)
    XCTAssertEqual(ohneEintrag.titel, "Medien ohne Eintrag vom 27.07.2025")
    XCTAssertEqual(ohneEintrag.medienText, "1 Foto/Video (1,6 MB)")
    XCTAssertEqual(
      ohneEintrag.fristText,
      "Gelöscht am 12.11.2026 13:44 · wird am 12.12.2026 endgültig entfernt (noch 1 Tag)")
  }
}
