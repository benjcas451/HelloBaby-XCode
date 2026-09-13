import Security
import SwiftUI
import UIKit

/// Lädt ein Bild vom Server und weist sich dabei genauso aus wie der Rest der
/// App.
///
/// `AsyncImage` kann das nicht: es lädt über `URLSession.shared`, also ohne
/// `X-API-Key`, ohne Client-Zertifikat und ohne die Cloudflare-Header. Solange
/// der Server Medien offen auslieferte, fiel das nicht auf — hinter Cloudflare
/// Access blockiert der Rand jede dieser Anfragen, und zwar bevor sie den
/// Server überhaupt erreicht.
struct MedienBild<Inhalt: View, Platzhalter: View, Fehler: View>: View {

  /// Absolute URL der Bildquelle; leer bedeutet „nichts zu laden“.
  let url: String
  /// Anzeige des geladenen Bildes (z. B. `$0.resizable().scaledToFill()`).
  let inhalt: (Image) -> Inhalt
  /// Anzeige, solange geladen wird.
  let platzhalter: () -> Platzhalter
  /// Anzeige, wenn das Laden fehlschlug.
  let fehler: () -> Fehler

  @State private var bild: Image?
  @State private var fehlgeschlagen = false

  init(
    url: String,
    @ViewBuilder inhalt: @escaping (Image) -> Inhalt,
    @ViewBuilder platzhalter: @escaping () -> Platzhalter,
    @ViewBuilder fehler: @escaping () -> Fehler
  ) {
    self.url = url
    self.inhalt = inhalt
    self.platzhalter = platzhalter
    self.fehler = fehler
  }

  var body: some View {
    Group {
      if let bild {
        inhalt(bild)
      } else if fehlgeschlagen {
        fehler()
      } else {
        platzhalter()
      }
    }
    // Wechselt die Quelle (Zelle wiederverwendet, anderer Eintrag), muss auch
    // neu geladen werden — sonst bliebe das Bild des Vorgängers stehen.
    .task(id: url) {
      bild = nil
      fehlgeschlagen = false
      guard let geladen = await MedienLader.shared.bild(url) else {
        fehlgeschlagen = true
        return
      }
      bild = geladen
    }
  }
}

/// Holt Medien über eine Session, die dieselben Kopfzeilen und – im
/// mTLS-Modus – dasselbe Client-Zertifikat verwendet wie `ApiClient`.
///
/// Ein kleiner Cache im Arbeitsspeicher hält das erneute Laden beim Scrollen
/// in Grenzen; er wird bei jedem `ApiClient.reset()` geleert, damit nach einem
/// Wechsel von Server oder Zugangsdaten nichts Altes hängen bleibt.
final class MedienLader: NSObject, @unchecked Sendable {

  static let shared = MedienLader()

  private let cache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 120
    return cache
  }()

  nonisolated(unsafe) private var identity: SecIdentity?
  nonisolated(unsafe) private var session: URLSession!
  private let lock = NSLock()

  private override init() {
    super.init()
    let konfiguration = URLSessionConfiguration.ephemeral
    konfiguration.timeoutIntervalForRequest = 30
    session = URLSession(configuration: konfiguration, delegate: self, delegateQueue: nil)
  }

  /// Verwirft Cache und mTLS-Identity nach geänderten Einstellungen.
  func reset() {
    cache.removeAllObjects()
    lock.withLock { identity = nil }
  }

  func bild(_ text: String) async -> Image? {
    guard !text.isEmpty, let url = URL(string: text) else { return nil }
    if let zwischengespeichert = cache.object(forKey: text as NSString) {
      return Image(uiImage: zwischengespeichert)
    }

    // Im mTLS-Modus dieselbe Identity wie der ApiClient aufbauen; schlägt das
    // fehl, ist auch das Bild nicht zu holen.
    if AppSettings.mode == .mtls, lock.withLock({ identity }) == nil {
      guard
        let zugangsdaten = try? CertSource().readCredentials(),
        let neu = try? ClientIdentity.make(
          certPEM: zugangsdaten.cert, keyPEM: zugangsdaten.key)
      else { return nil }
      lock.withLock { identity = neu }
    }

    var request = URLRequest(url: url)
    for (feld, wert) in ApiClient.authHeader {
      request.setValue(wert, forHTTPHeaderField: feld)
    }
    guard
      let (daten, antwort) = try? await session.data(for: request),
      let http = antwort as? HTTPURLResponse,
      (200..<300).contains(http.statusCode),
      // Hinter Cloudflare Access landet eine Anfrage ohne gültiges Token auf
      // der Login-Seite — die kommt mit Status 200 an und ist kein Bild.
      CloudflareServiceToken.abweisung(http) == nil,
      let bild = UIImage(data: daten)
    else { return nil }

    cache.setObject(bild, forKey: text as NSString)
    return Image(uiImage: bild)
  }
}

extension MedienLader: URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
      let identity = lock.withLock({ identity })
    else {
      // Server-Zertifikat weiterhin normal gegen den System-Trust-Store prüfen.
      completionHandler(.performDefaultHandling, nil)
      return
    }
    completionHandler(
      .useCredential,
      URLCredential(identity: identity, certificates: nil, persistence: .forSession))
  }
}
