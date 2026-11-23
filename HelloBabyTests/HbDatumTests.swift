import XCTest

@testable import HelloBaby

/// stats.php des Servers liefert „15.11.2026“ bzw. „Keine Einträge“, die
/// lokale Ablage ISO. Beides muss die Startseite lesen, sonst bleibt
/// „Zuletzt“ im Server-Modus leer.
@MainActor
final class HbDatumTests: XCTestCase {

  private func teile(_ datum: Date?) -> [Int] {
    guard let datum else { return [] }
    let k = Calendar.current.dateComponents([.year, .month, .day], from: datum)
    return [k.year ?? 0, k.month ?? 0, k.day ?? 0]
  }

  func testLiestIsoUndDeutsch() {
    XCTAssertEqual(teile(HbDatum.datum("2026-11-15")), [2026, 11, 15])
    XCTAssertEqual(teile(HbDatum.datum("15.11.2026")), [2026, 11, 15])
    XCTAssertEqual(teile(HbDatum.datum(" 22.04.2026 ")), [2026, 4, 22])
  }

  func testKeinDatum() {
    XCTAssertNil(HbDatum.datum("Keine Einträge"))
    XCTAssertNil(HbDatum.datum(""))
  }

  func testAnzeigeIstDeutsch() {
    XCTAssertEqual(HbDatum.anzeige("2026-11-15"), "15.11.2026")
    XCTAssertEqual(HbDatum.anzeige("15.11.2026"), "15.11.2026")
  }
}
