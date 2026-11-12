import Foundation
import XCTest

@testable import HelloBaby

/// Basis für Tests, die den `ApiClient` gegen den nachgestellten Server
/// (`ci/upload_attrappe.py`) laufen lassen.
///
/// Der Server muss laufen, sonst werden die Tests übersprungen:
///
///     python3 ci/upload_attrappe.py 18765
///
/// Weil er über unverschlüsseltes HTTP auf 127.0.0.1 erreichbar ist, braucht
/// der Testlauf `NSAllowsLocalNetworking` in der Info.plist; der Workflow
/// `tests.yml` trägt das nur für den Lauf ein, nicht ins Repository.
@MainActor
class AttrappeTestCase: XCTestCase {

  static let attrappe = "http://127.0.0.1:18765"

  /// Stellt die App auf die Attrappe ein und leert deren Zustand.
  func richteEin(_ szenario: String) async throws {
    var probe = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.attrappe)/bereit")))
    probe.timeoutInterval = 10
    // Mehrere Anläufe: die allererste Verbindung einer frisch gestarteten App
    // im Simulator braucht mitunter mehrere Sekunden.
    var erreichbar = false
    for _ in 0..<3 where !erreichbar {
      if let antwort = try? await URLSession.shared.data(for: probe),
        (antwort.1 as? HTTPURLResponse)?.statusCode == 200
      {
        erreichbar = true
      }
    }
    guard erreichbar else {
      throw XCTSkip("Attrappe läuft nicht – starten mit: python3 ci/upload_attrappe.py 18765")
    }
    var leeren = URLRequest(url: try XCTUnwrap(URL(string: "\(Self.attrappe)/zuruecksetzen")))
    leeren.httpMethod = "POST"
    _ = try await URLSession.shared.data(for: leeren)

    AppSettings.mode = .apiKey
    AppSettings.serverBase = "\(Self.attrappe)/\(szenario)"
    ApiClient.shared.reset()
  }

  func raeumeAuf() {
    AppSettings.mode = .local
    AppSettings.serverBase = ""
    ApiClient.shared.reset()
  }

  func zustand(_ szenario: String) async throws -> [String: Any] {
    let url = try XCTUnwrap(URL(string: "\(Self.attrappe)/\(szenario)/zustand"))
    let (daten, _) = try await URLSession.shared.data(from: url)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: daten) as? [String: Any])
  }
}
