# HelloBaby! – iOS (nativ)

Natives iOS-Pendant der früheren Flutter-App **HelloBaby!** – ein
Schwangerschafts- und Entwicklungstagebuch mit Fotos/Videos, wahlweise
komplett lokal oder gegen eine eigene Server-API.

- **Sprache/UI:** Swift, SwiftUI (eigenes Baby-Grün-Theme wie die Flutter-App)
- **Bundle-ID:** `ch.tschir.HelloBaby` (identisch zur Flutter-App → Installation ist ein Update)
- **Version:** 3.0.3, `CURRENT_PROJECT_VERSION` lokal 100, in CI `100 + run_number`
- **Deployment-Target:** iOS 17

## Funktionsumfang

- Zwei Tagebücher (Schwangerschaft/Entwicklung) mit dynamischen Feldern
- Tages-, Monats-, Favoriten- und Galerie-Ansichten, zufälliger Tag
- Eintrag erstellen mit Fotos/Videos (Fotomediathek, Kamera), Upload-Fortschritt
- Datenquellen: lokal (SQLite + Medienordner) oder Server-API
  (API-Key oder mTLS-Client-Zertifikat; Zertifikats-Ordner wahlweise der
  App-Ordner in der Dateien-App oder ein frei gewählter Ordner per
  security-scoped Bookmark)
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
`/api/media.php?file=…` (`&download=1` erzwingt den Download); beide sind ohne
Auth erreichbar. Die geschützten Endpunkte authentifizieren je nach Modus über
den Header `X-API-Key` oder das Client-Zertifikat.

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
| API-Key (Keychain) | ❌ | ✅ |
| Client-Zertifikat | ❌ | ❌ |

Der API-Key liegt in der Keychain, mit `kSecAttrAccessibleAfterFirstUnlock`
und **ohne** `kSecAttrSynchronizable`. Damit ist er beim Direkttransfer und
im verschlüsselten Finder-Backup dabei, aus einem iCloud-Backup dagegen nicht
wiederherstellbar — die iOS-Entsprechung der Android-Entscheidung
„`<device-transfer>` ja, `<cloud-backup>` nein“. Nach einer Wiederherstellung
aus iCloud ist er einmal neu einzutragen.

Client-Zertifikate (`client.crt` / `client.key`) liegen im App-Ordner der
Dateien-App und sind nach einem Gerätewechsel gegebenenfalls neu abzulegen.
Dafür müssen zwei Dinge zusammenkommen:

1. **`UIFileSharingEnabled` und `LSSupportsOpeningDocumentsInPlace` im
   Bundle.** `UIFileSharingEnabled` steht in `AppInfo.plist` und **nicht**
   als `INFOPLIST_KEY_UIFileSharingEnabled` im Projekt: diesen Schlüssel
   kennt Xcode als Build-Setting nicht und verwirft ihn kommentarlos. Genau
   daran lag es – der Schlüssel stand im Projekt und kam nie im Binary an.
   `GENERATE_INFOPLIST_FILE` bleibt `YES`; Xcode nimmt `AppInfo.plist` als
   Basis und mergt die `INFOPLIST_KEY_*`-Werte hinein.
2. **Mindestens eine sichtbare Datei in `Documents/`.** iOS blendet den
   Ordner sonst aus. `AppOrdner` hält dafür beim Start eine `README.txt`
   vor und legt sie an, sobald sie fehlt – bewusst ohne Leer-Prüfung:
   `contentsOfDirectory` zählt auch unsichtbare Punkt-Dateien mit, für iOS
   gilt der Ordner damit trotzdem als leer.

Der Build-Check liest beide Schlüssel mit `PlistBuddy` aus dem gebauten
Bundle und schlägt fehl, wenn einer nicht `true` ist. Dass beide ankommen –
einer aus der Datei, einer aus den Build-Settings – belegt zugleich, dass
der Merge greift; `CFBundleShortVersionString` wird als zweiter Beleg
mitgeprüft.

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
  GitHub-Release (`v3.0.3-<run>`), zum Sideloading.
- `.github/workflows/upload-app-store.yml` (manuell): signierte IPA nach
  App Store Connect / TestFlight. Benötigt das GitHub Environment
  `app-store` mit denselben sechs Secrets wie im früheren Flutter-Repo:
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`,
  `APP_STORE_CONNECT_API_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`,
  `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`.
