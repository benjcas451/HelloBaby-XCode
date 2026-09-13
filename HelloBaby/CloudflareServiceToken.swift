import Foundation

/// Ein Cloudflare-Access-Service-Token: das Gegenstück zum Browser-Login für
/// Maschinen. Cloudflare prüft die beiden Header am Rand und reicht die
/// Anfrage erst danach an den eigentlichen Server weiter – der kann darüber
/// hinaus weiter seinen eigenen `X-API-Key` verlangen.
struct CloudflareServiceToken: Sendable {

  /// Client-ID des Tokens; endet üblicherweise auf `.access`.
  let clientId: String
  /// Client-Secret des Tokens.
  let clientSecret: String

  /// Nur ein vollständiges Token ergibt Sinn – mit einer Hälfte weist
  /// Cloudflare die Anfrage genauso ab wie ganz ohne.
  init?(clientId: String, clientSecret: String) {
    let id = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, !secret.isEmpty else { return nil }
    self.clientId = id
    self.clientSecret = secret
  }

  func anwenden(auf request: inout URLRequest) {
    for (feld, wert) in header {
      request.setValue(wert, forHTTPHeaderField: feld)
    }
  }

  /// Als Wörterbuch – so brauchen es AVURLAsset und der Medien-Lader, die
  /// keine `URLRequest` entgegennehmen.
  var header: [String: String] {
    [
      "CF-Access-Client-Id": clientId,
      "CF-Access-Client-Secret": clientSecret,
    ]
  }

  /// Das aus den Einstellungen hinterlegte Token, sofern vollständig.
  static var ausEinstellungen: CloudflareServiceToken? {
    CloudflareServiceToken(
      clientId: AppSettings.cfAccessClientId,
      clientSecret: AppSettings.cfAccessClientSecret)
  }

  /// Erkennt, dass Cloudflare Access die Anfrage abgefangen hat, und liefert
  /// dafür eine verständliche Meldung (sonst nil).
  ///
  /// Ohne gültiges Token antwortet Access nicht mit einem sauberen Fehler,
  /// sondern leitet auf die Login-Seite des Teams um. URLSession folgt dem
  /// automatisch, und am Ende steht eine HTML-Seite mit Status 200 – der
  /// JSON-Parser meldete dafür „kein JSON“, was den eigentlichen Grund
  /// verschleiert. Erkennbar ist der Fall am Host der finalen Antwort: Access
  /// leitet immer auf eine Subdomain von `cloudflareaccess.com`.
  static func abweisung(_ response: HTTPURLResponse) -> String? {
    if istAccessLogin(response.url) {
      return "Cloudflare Access hat die Anfrage abgewiesen. Bitte Service Token "
        + "in den Einstellungen prüfen – möglicherweise ist es abgelaufen."
    }
    // 403 direkt von Cloudflare: Token wird zwar erkannt, die Access-Richtlinie
    // lässt es aber nicht auf diese Anwendung.
    if response.statusCode == 403, response.value(forHTTPHeaderField: "cf-ray") != nil {
      return "Cloudflare Access hat den Zugriff verweigert (403). Das Service Token "
        + "ist dieser Anwendung vermutlich nicht zugewiesen."
    }
    return nil
  }

  private static func istAccessLogin(_ url: URL?) -> Bool {
    guard let host = url?.host?.lowercased() else { return false }
    return host == "cloudflareaccess.com" || host.hasSuffix(".cloudflareaccess.com")
  }
}
