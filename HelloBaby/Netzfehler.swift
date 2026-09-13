import Foundation

/// Wie ein fehlgeschlagener Netzwerkzugriff zu bewerten ist.
///
/// Der Unterschied entscheidet über Duplikate: Nur wenn die Anfrage den
/// Server nachweislich nie erreicht hat, darf die App sie in die
/// Warteschlange legen und später erneut senden. Bei allem Mehrdeutigen
/// könnte der Server sie längst ausgeführt haben — ein zweiter Versuch legte
/// dann einen zweiten Eintrag an.
enum Netzfehler: Sendable {

  /// DNS, Verbindungsaufbau oder TLS schlugen fehl, oder das Gerät hat gar
  /// keine Verbindung. Die Anfrage ist nie hinausgegangen.
  case nieGesendet

  /// Zeitüberschreitung oder Abbruch mitten in der Übertragung. Ob der Server
  /// die Anfrage gesehen hat, ist nicht feststellbar.
  case mehrdeutig

  /// Ordnet einen `URLSession`-Fehler ein; nil bei allem, was kein
  /// Netzwerkproblem ist.
  static func aus(_ fehler: Error) -> Netzfehler? {
    guard let urlFehler = fehler as? URLError else { return nil }
    switch urlFehler.code {
    case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
      .secureConnectionFailed, .serverCertificateUntrusted,
      .serverCertificateHasBadDate, .serverCertificateNotYetValid,
      .serverCertificateHasUnknownRoot, .clientCertificateRejected,
      .clientCertificateRequired:
      return .nieGesendet
    case .timedOut, .networkConnectionLost, .cannotLoadFromNetwork,
      .resourceUnavailable, .badServerResponse:
      return .mehrdeutig
    default:
      // Alles Übrige (ungültige URL, abgebrochen durch den Aufrufer, …) ist
      // kein Verbindungsproblem und gehört nicht in die Warteschlange.
      return nil
    }
  }

  /// Kurzer Grund für die Offline-Anzeige.
  static func meldung(_ fehler: Error) -> String {
    (fehler as? URLError)?.localizedDescription ?? fehler.localizedDescription
  }
}
