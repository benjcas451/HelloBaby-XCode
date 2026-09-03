import Foundation

/// Hält den App-Ordner in der „Dateien“-App sichtbar.
///
/// `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` allein
/// genügen nicht: iOS blendet den Ordner unter „Auf meinem iPhone“ aus,
/// solange `Documents/` leer ist. Die Flutter-App legte dort immer ihre
/// Datenbank ab, der Ordner war deshalb stets zu sehen. Die native App
/// schreibt im Server-Modus nichts hinein – und der Ordner verschwand, womit
/// sich auch client.crt/client.key nicht mehr hineinkopieren ließen.
///
/// Eine kurze Hinweisdatei genügt, um ihn wieder auftauchen zu lassen.
enum AppOrdner {

  static let hinweisName = "README.txt"

  static var documents: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  /// Schreibt die Hinweisdatei, solange sonst nichts im Ordner liegt.
  ///
  /// Sobald eigene Dateien vorhanden sind, passiert nichts mehr – eine vom
  /// Nutzer gelöschte Hinweisdatei bleibt dann also gelöscht.
  static func sichtbarMachen() {
    let inhalt = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
    guard inhalt.isEmpty else { return }
    try? Data(hinweis.utf8).write(to: documents.appendingPathComponent(hinweisName))
  }

  private static let hinweis = """
    Das ist der Ordner der App „Hello Baby!“ in der Dateien-App.

    Für die Anmeldung per Client-Zertifikat (mTLS) gehören hier hinein:

      client.crt  –  Client-Zertifikat (PEM)
      client.key  –  zugehöriger privater Schlüssel (PEM, ohne Passphrase)

    Alternativ lässt sich in den Einstellungen der App ein beliebiger anderer
    Ordner auswählen, in dem die beiden Dateien liegen.

    Diese Datei darf gelöscht werden. Ist der Ordner danach vollständig leer,
    blendet iOS ihn in der Dateien-App allerdings wieder aus – beim nächsten
    Start der App wird sie deshalb neu angelegt.
    """
}
