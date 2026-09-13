# HelloBaby! – iOS (nativ)

Natives iOS-Pendant der früheren Flutter-App **HelloBaby!** – ein
Schwangerschafts- und Entwicklungstagebuch mit Fotos/Videos, wahlweise
komplett lokal oder gegen eine eigene Server-API.

- **Sprache/UI:** Swift, SwiftUI (eigenes Baby-Grün-Theme wie die Flutter-App)
- **Bundle-ID:** `ch.tschir.HelloBaby` (identisch zur Flutter-App → Installation ist ein Update)
- **Version:** 3.0.2, `CURRENT_PROJECT_VERSION` lokal 100, in CI `100 + run_number`
- **Deployment-Target:** iOS 17

## Funktionsumfang

- Zwei Tagebücher (Schwangerschaft/Entwicklung) mit dynamischen Feldern
- Tages-, Monats-, Favoriten- und Galerie-Ansichten, zufälliger Tag
- Eintrag erstellen mit Fotos/Videos (Fotomediathek, Kamera), Upload-Fortschritt
- Datenquellen: lokal (SQLite + Medienordner) oder Server-API
  (API-Key, mTLS-Client-Zertifikat oder Cloudflare Service Token;
  Zertifikats-Ordner wahlweise der App-Ordner in der Dateien-App oder ein
  frei gewählter Ordner per security-scoped Bookmark)
- ZIP-Backup/-Wiederherstellung (Format kompatibel zur Flutter-App;
  geschrieben als STORE, gelesen werden STORE und DEFLATE)
- Einmaliger Import lokaler Einträge zur Server-API (mit Duplikatschutz)

## Datenübernahme von der Flutter-App

Beim ersten Start werden vorhandene Flutter-Daten übernommen:

- **SQLite:** dieselbe Datei `Documents/HelloBaby/hello_baby.sqlite`
  (Schema v2 inkl. `remote_imports`) wird direkt weiterverwendet, ebenso
  der Medienordner `Documents/HelloBaby/media/`.
- **Medienpfade heilen:** Die Spalte `bilder` enthält absolute Pfade.
  Der Data-Container bekommt bei App-Updates eine neue UUID, deshalb wird
  der Pfad beim Lesen anhand des Ordnernamens auf den aktuellen Container
  umgebogen (im Simulator-Update-Test nachgewiesen).
- **Einstellungen:** Flutters shared_preferences schreibt auf iOS in
  dieselben UserDefaults, nur mit Präfix `flutter.`. Die Werte werden
  einmalig kopiert (Marker `migriert_von_flutter`); String-Listen liegen
  auf iOS als natives Array. Auch das gespeicherte Zertifikats-Bookmark
  (`cert_folder_bookmark_ios`/`cert_folder_label_ios`) wird übernommen.

## REST-API & Datenmodell

Basis-URL konfiguriert der Nutzer in den Einstellungen; die Endpunkte liegen
darunter im Pfad `/api`. Alle Antworten JSON, Fehler als `{"error": "…"}` mit
passendem HTTP-Status.

| Endpunkt | Zweck |
|---|---|
| `GET /api/stats.php?diary=<id>` | erster/letzter Eintrag, zufälliges Datum |
| `GET /api/entries.php?date=YYYY-MM-DD&diary=<id>` | Einträge eines Tages (ebenso `?year=&month=`, `?favorites=1`, `?images=1`) |
| `POST /api/entries.php` | Eintrag anlegen (`multipart/form-data`): Felder je Tagebuch + `kalender_datum`, `von_name`, `diary`, optional `images[]` |
| `DELETE /api/entries.php?id=<id>&diary=<id>` | Eintrag löschen |
| `POST /api/favorite.php` | Favorit umschalten, Body `{"id":…, "diary":"…"}` |
| `GET /api/gallery.php?folder=uploads/<ordner>` | Dateien einer Galerie |

Vorschaubilder und Video-Poster liefert `/api/thumb.php`, die Medien selbst
`/api/media.php?file=…` (`&download=1` erzwingt den Download).

**Authentifizierung** je nach Modus: Header `X-API-Key`, Client-Zertifikat
auf Transport-Ebene, oder die Cloudflare-Header `CF-Access-Client-Id` und
`CF-Access-Client-Secret` (seit 3.1.0; beide Hälften liegen in eigenen
Keychain-Accounts und gehen nur gemeinsam raus). Der API-Key ist in den
Modi mTLS und Cloudflare optional.

**Medien laufen seit 3.1.0 über dieselben Kopfzeilen.** Vorher liefen
Vorschaubilder, Vollbilder und Videos über `AsyncImage` bzw. `AVPlayer` und
damit an `ApiClient` vorbei — ohne Key, ohne Zertifikat. Solange der Server
diese Endpunkte offen auslieferte, fiel das nicht auf; hinter Cloudflare
Access blockiert der Rand jede dieser Anfragen. Bilder holt jetzt
`MedienBild`/`MedienLader` über eine Session mit denselben Kopfzeilen und
demselben Client-Zertifikat, Videos bekommen sie per
`AVURLAssetHTTPHeaderFieldsKey` mit.

**Access-Abweisung:** Ohne gültiges Token antwortet Cloudflare nicht mit
einem Fehler, sondern leitet auf die Login-Seite des Teams um. `URLSession`
folgt dem, sodass eine HTML-Seite mit Status 200 ankommt. `ApiClient` und
`MedienLader` erkennen das am Host der finalen Antwort (Subdomain von
`cloudflareaccess.com`) bzw. an einem 403 mit `cf-ray`-Header und melden es
als Token-Problem.

## Offline-Betrieb

Bricht die Verbindung weg, bleibt die App benutzbar. Die Logik sitzt im
`ApiClient` selbst (er ist die einzige Datenquelle, es gibt kein Protokoll zum
Umhüllen) und greift nur in den Server-Modi.

**Lesen:** Jede erfolgreiche GET-Antwort landet roh als JSON in
`Application Support/Offline/antworten_<zugang>/`, benannt nach Pfad und
sortierten Parametern. Scheitert eine Abfrage an einem Netzwerkfehler, kommt
die Antwort von dort. Damit funktionieren Tagesansicht, Monatsansicht,
Favoriten, Galerie und Statistik gleichermassen, ohne je eine eigene
Zwischenspeicher-Logik zu brauchen.

**Schreiben:** Anlegen, Löschen und das Umschalten eines Favoriten gehen in
eine Warteschlange, wenn sie den Server nachweislich nie erreicht haben (kein
Netz, DNS, Verbindungsaufbau, TLS). Eine Zeitüberschreitung oder ein Abbruch
mitten in der Übertragung ist mehrdeutig — der Server könnte den Eintrag
längst haben, ein zweiter Versuch legte dann einen zweiten an. Gerade beim
Hochladen eines Videos ist das der wahrscheinlichere Fall, deshalb bleibt es
dort bei der Fehlermeldung.

**Medien wandern mit.** Ein offline erstellter Eintrag behält seine Fotos und
Videos: Die Dateien werden nach
`Application Support/Offline/medien_<zugang>/<uuid>/` kopiert und von dort
hochgeladen. Kopiert wird bewusst — die Originale aus der Fotomediathek liegen
in einem temporären Ordner, den das System jederzeit räumen darf. Nach
erfolgreichem Upload (oder wenn der Eintrag verworfen wird) verschwindet der
Ordner; verwaiste Ordner ohne zugehörige Aktion räumt das Nachholen auf.

**Ordnung.** Neue Einträge bekommen eine negative lokale Kennung. Eine
Löschung, die einen noch wartenden Eintrag trifft, entfernt dessen Aktion
samt Favoriten-Umschaltungen und Medien. Solange etwas ansteht, geht auch ein
neuer Schreibzugriff hinten dran statt am Stau vorbei.

**Abgearbeitet** wird vor jedem Laden des Startbildschirms, beim Zurückkehren
aus dem Hintergrund und sobald `NWPathMonitor` wieder einen Pfad meldet. Das
Nachholen benutzt die rohen Aufrufe (`ladeHoch`, `loescheDirekt`,
`favoritDirekt`) statt der öffentlichen Methoden — sonst würde es dieselbe
Aktion in einer Schleife erneut vormerken. Beim ersten Verbindungsfehler
bricht der Durchlauf ab, der Rest bleibt in der Reihenfolge stehen. Vom Server
inhaltlich zurückgewiesene Aktionen fliegen raus und werden einmal gemeldet.

Die Ablage hängt am Zugang (Modus + Server-URL).

**Datenmodell.** Die lokale Tabelle `entries` spiegelt exakt das Modell der
API (Spaltenordnung wie in der Flutter-App):

| Spalte | Typ | Bedeutung |
|---|---|---|
| `id` | INTEGER | Primärschlüssel (Auto-Increment) |
| `diary` | TEXT | `schwangerschaft` oder `entwicklung` |
| `kalender_datum` | TEXT | Tag des Eintrags, `YYYY-MM-DD` |
| `bilder` | TEXT | Medienordner des Eintrags (`media/<diary>_<id>`), leer wenn keine |
| `von_name` | TEXT | ausgewählter Ersteller |
| `favorit` | INTEGER | 0/1 |
| `created_at` | TEXT | Zeitpunkt der Erfassung, ISO 8601 |
| `fields_json` | TEXT | die tagebuchspezifischen Felder als JSON-Objekt |

`bilder` führt einen absoluten Pfad (Erbe der Flutter-App). Der Container
bekommt bei jeder Neuinstallation eine neue UUID, deshalb biegt
`LocalStore.heileMedienPfad` den Pfad beim Lesen anhand des Ordnernamens auf
den aktuellen Container um.

Schema-Version 2 (`PRAGMA user_version`) ergänzt die Tabelle `remote_imports`
(`local_id`, `diary`, `server_base`, `remote_id`, `imported_at`): sie merkt
sich je Server, welcher lokale Eintrag schon übertragen wurde, damit ein
erneuter Import keine Duplikate anlegt.

## Sicherung & Gerätewechsel

Auf iOS gibt es kein Gegenstück zu Androids `backup_rules.xml` /
`data_extraction_rules.xml`. Gesteuert wird über die Dateiablage
(`Documents` wird gesichert, `Library/Caches` und `tmp` nicht),
`isExcludedFromBackup` und die Keychain-Attribute.

| | iCloud-Backup | Direkttransfer (Schnellstart) |
|---|---|---|
| Einträge (SQLite) | ✅ | ✅ |
| Medien (Fotos/Videos) | ✅ | ✅ |
| API-Key & Service Token (Keychain) | ❌ | ✅ |
| Client-Zertifikat | ❌ | ❌ |

Der API-Key und beide Hälften des Cloudflare Service Tokens liegen in der
Keychain, mit `kSecAttrAccessibleAfterFirstUnlock`
und **ohne** `kSecAttrSynchronizable`. Damit sind sie beim Direkttransfer und
im verschlüsselten Finder-Backup dabei, aus einem iCloud-Backup dagegen nicht
wiederherstellbar — die iOS-Entsprechung der Android-Entscheidung
„`<device-transfer>` ja, `<cloud-backup>` nein“. Nach einer Wiederherstellung
aus iCloud sind sie einmal neu einzutragen.

Client-Zertifikate (`client.crt` / `client.key`) liegen im App-Ordner der
Dateien-App und sind nach einem Gerätewechsel gegebenenfalls neu abzulegen.
Damit dieser Ordner dort überhaupt auftaucht, legt `AppOrdner` beim Start
eine Hinweisdatei an, solange er sonst leer ist – iOS blendet leere
App-Ordner aus.

Ein selbst gewählter Zertifikats-Ordner wird als security-scoped Bookmark
gespeichert. Die Leseberechtigung überlebt einen Gerätewechsel nicht;
`CertSource` erkennt das über `bookmarkDataIsStale` und bittet darum, den
Ordner erneut auszuwählen.

Unabhängig davon gibt es im Modus „Lokal“ das vollständige ZIP-Backup
inklusive Medien unter *Einstellungen → Backup*.

## Build

```bash
xcodebuild -project HelloBaby.xcodeproj -scheme HelloBaby \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Der Code ist unter `SWIFT_STRICT_CONCURRENCY=complete` warnungsfrei.

## CI

- `.github/workflows/build-ipa.yml` (manuell): unsignierte IPA als
  GitHub-Release (`v3.0.2-<run>`), zum Sideloading.
- `.github/workflows/upload-app-store.yml` (manuell): signierte IPA nach
  App Store Connect / TestFlight. Benötigt das GitHub Environment
  `app-store` mit denselben sechs Secrets wie im früheren Flutter-Repo:
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`,
  `APP_STORE_CONNECT_API_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`,
  `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`.
