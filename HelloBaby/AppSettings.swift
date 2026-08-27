import Foundation
import Security

/// Welche Datenquelle die App verwendet. Rohwerte identisch zur Flutter-App.
enum DataSourceMode: String {
  /// Vollständig lokale Speicherung (SQLite + Medienordner in Documents).
  case local
  /// Server-API mit Client-Zertifikat (mTLS).
  case mtls
  /// Server-API mit API-Key (`X-API-Key`-Header).
  case apiKey
}

/// Lädt und speichert App-Einstellungen (UserDefaults) – mit einer Ausnahme:
/// der API-Key liegt in der Keychain, siehe `ApiKeyStore` am Dateiende.
///
/// Beim ersten Start nach dem Umstieg von der Flutter-App werden deren Werte
/// übernommen: Flutters shared_preferences speichert auf iOS in denselben
/// UserDefaults, nur mit dem Präfix `flutter.` (gleiche Bundle-ID = gleicher
/// Container). String-Listen liegen dort als natives Array.
enum AppSettings {

  static let defaultAppName = "Baby"

  // Computed statt stored: UserDefaults ist thread-sicher, aber als
  // gespeicherte Globale würde der Compiler Sendable-Warnungen melden.
  private static var defaults: UserDefaults { .standard }

  private enum Key {
    static let mode = "data_source_mode"
    static let apiKey = "api_key"
    static let serverBase = "server_base_url"
    static let appName = "app_display_name"
    static let activeDiary = "active_diary"
    static let users = "creator_users"
    static let selectedUser = "creator_selected"
    static let defaultUser = "creator_default"
    static let certBookmark = "cert_folder_bookmark_ios"
    static let certLabel = "cert_folder_label_ios"
    static let migriert = "migriert_von_flutter"
    static let keychainMigriert = "api_key_in_keychain"
  }

  static func migrationAusfuehren() {
    apiKeyInKeychainUebernehmen()
    guard !defaults.bool(forKey: Key.migriert) else { return }
    for key in [
      Key.mode, Key.serverBase, Key.appName, Key.activeDiary,
      Key.selectedUser, Key.defaultUser, Key.certBookmark, Key.certLabel,
    ] {
      if defaults.object(forKey: key) == nil,
        let wert = defaults.string(forKey: "flutter." + key)
      {
        defaults.set(wert, forKey: key)
      }
    }
    if defaults.object(forKey: Key.users) == nil,
      let liste = defaults.stringArray(forKey: "flutter." + Key.users)
    {
      defaults.set(liste, forKey: Key.users)
    }
    defaults.set(true, forKey: Key.migriert)
  }

  /// Holt einen noch im Klartext hinterlegten API-Key einmalig in die Keychain
  /// und räumt ihn aus den UserDefaults – damit verschwindet er auch aus jedem
  /// künftigen iCloud-Backup. Eigener Marker, weil `migriert_von_flutter` bei
  /// Bestandsnutzern längst gesetzt ist und die Übernahme sonst nie liefe.
  private static func apiKeyInKeychainUebernehmen() {
    guard !defaults.bool(forKey: Key.keychainMigriert) else { return }
    let klartext =
      (defaults.string(forKey: Key.apiKey) ?? defaults.string(forKey: "flutter." + Key.apiKey))?
      .trimmingCharacters(in: .whitespaces) ?? ""
    if !klartext.isEmpty {
      ApiKeyStore.speichere(klartext)
    }
    defaults.removeObject(forKey: Key.apiKey)
    defaults.removeObject(forKey: "flutter." + Key.apiKey)
    defaults.set(true, forKey: Key.keychainMigriert)
  }

  static var mode: DataSourceMode {
    get { defaults.string(forKey: Key.mode).flatMap(DataSourceMode.init) ?? .local }
    set { defaults.set(newValue.rawValue, forKey: Key.mode) }
  }

  /// Liegt in der Keychain statt in den UserDefaults – siehe `ApiKeyStore`.
  static var apiKey: String {
    get { ApiKeyStore.lade() }
    set { ApiKeyStore.speichere(newValue.trimmingCharacters(in: .whitespaces)) }
  }

  /// Basis-URL des Servers ohne abschließenden Slash; leer = nicht gesetzt.
  static var serverBase: String {
    get {
      var url = (defaults.string(forKey: Key.serverBase) ?? "")
        .trimmingCharacters(in: .whitespaces)
      while url.hasSuffix("/") { url.removeLast() }
      return url
    }
    set { defaults.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Key.serverBase) }
  }

  /// Der Name im Titel „Hello NAME!“.
  static var appName: String {
    get {
      let name = (defaults.string(forKey: Key.appName) ?? "")
        .trimmingCharacters(in: .whitespaces)
      return name.isEmpty ? defaultAppName : name
    }
    set {
      let name = newValue.trimmingCharacters(in: .whitespaces)
      if name.isEmpty {
        defaults.removeObject(forKey: Key.appName)
      } else {
        defaults.set(name, forKey: Key.appName)
      }
    }
  }

  /// Aktiver Tagebuch-Modus (schwangerschaft/entwicklung).
  static var activeDiary: String {
    get { defaults.string(forKey: Key.activeDiary) ?? kDefaultDiary }
    set { defaults.set(newValue, forKey: Key.activeDiary) }
  }

  /// Liste der auswählbaren Ersteller („von_name“).
  static var users: [String] {
    get { defaults.stringArray(forKey: Key.users) ?? [] }
    set { defaults.set(newValue, forKey: Key.users) }
  }

  /// Zuletzt gewählter Ersteller (Vorauswahl beim Anlegen).
  static var selectedUser: String {
    get { defaults.string(forKey: Key.selectedUser) ?? "" }
    set { defaults.set(newValue, forKey: Key.selectedUser) }
  }

  /// Fest voreingestellter Ersteller; hat Vorrang vor [selectedUser].
  static var defaultUser: String {
    get { defaults.string(forKey: Key.defaultUser) ?? "" }
    set { defaults.set(newValue, forKey: Key.defaultUser) }
  }

  /// Security-scoped Bookmark des Zertifikats-Ordners (Base64), leer = Documents.
  static var certFolderBookmark: String {
    get { defaults.string(forKey: Key.certBookmark) ?? "" }
    set { defaults.set(newValue, forKey: Key.certBookmark) }
  }

  /// Anzeigename des gewählten Zertifikats-Ordners.
  static var certFolderLabel: String {
    get { defaults.string(forKey: Key.certLabel) ?? "" }
    set { defaults.set(newValue, forKey: Key.certLabel) }
  }
}

/// Der API-Key gehört nicht in die UserDefaults – die landen vollständig in
/// jedem iCloud-Backup. In der Keychain steuert `kSecAttrAccessible`, wie weit
/// er mitwandert: `AfterFirstUnlock` ohne `kSecAttrSynchronizable` heißt beim
/// Direkttransfer auf ein neues Gerät (Quick Start) und im verschlüsselten
/// Finder-Backup dabei, aus einem iCloud-Backup dagegen nicht
/// wiederherstellbar. Das ist die iOS-Entsprechung der Android-Trennung
/// „`<device-transfer>` ja, `<cloud-backup>` nein“; die Uhr legt ihre
/// übernommene Verbindung in `ServerConnectionStore` mit demselben Attribut ab.
private enum ApiKeyStore {

  private static let service = "ch.tschir.HelloBaby"
  private static let account = "api-key"

  static func lade() -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard
      SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let daten = result as? Data
    else { return "" }
    return String(data: daten, encoding: .utf8) ?? ""
  }

  /// Ein leerer Key bedeutet „kein Key hinterlegt“ – dann bleibt auch nichts
  /// in der Keychain liegen.
  static func speichere(_ key: String) {
    loesche()
    guard !key.isEmpty else { return }
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(key.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    SecItemAdd(item as CFDictionary, nil)
  }

  static func loesche() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
