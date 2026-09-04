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

  /// Stellt sicher, dass die Hinweisdatei existiert.
  ///
  /// Bewusst ohne Prüfung, ob der Ordner leer ist: `contentsOfDirectory`
  /// zählt auch unsichtbare Dateien mit (Punkt-Dateien, Reste von iCloud
  /// oder einem Restore). Für iOS gilt der Ordner damit trotzdem als leer –
  /// die frühere Prüfung sprang in dem Fall nicht an und der Ordner blieb
  /// in der Dateien-App unsichtbar.
  ///
  /// Die Datei kostet ein paar hundert Byte und wird nach dem Löschen beim
  /// nächsten Start neu angelegt; genau so ist sie auch beschrieben.
  static func sichtbarMachen() {
    let ordner = documents
    // Auf einem frischen Gerät kann Documents/ noch fehlen; ohne den Ordner
    // liefe das Schreiben ins Leere.
    try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    let ziel = ordner.appendingPathComponent(hinweisName)
    guard !FileManager.default.fileExists(atPath: ziel.path) else { return }
    try? Data(hinweis.utf8).write(to: ziel)
  }

  private static let hinweis = """
    Das ist der Ordner der App „Hello Baby!“ in der Dateien-App.

    Für die Anmeldung per Client-Zertifikat (mTLS) gehören hier hinein:

      client.crt  –  Client-Zertifikat (PEM)
      client.key  –  zugehöriger privater Schlüssel (PEM, ohne Passphrase)

    Alternativ lässt sich in den Einstellungen der App ein beliebiger anderer
    Ordner auswählen, in dem die beiden Dateien liegen.

    Diese Datei darf gelöscht werden. Sie wird beim nächsten Start der App
    neu angelegt: iOS blendet den Ordner in der Dateien-App aus, sobald er
    keine sichtbare Datei mehr enthält.
    """
}
