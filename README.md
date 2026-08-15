# HelloBaby! – iOS (nativ)

Natives iOS-Pendant der früheren Flutter-App **HelloBaby!** – ein
Schwangerschafts- und Entwicklungstagebuch mit Fotos/Videos, wahlweise
komplett lokal oder gegen eine eigene Server-API.

- **Sprache/UI:** Swift, SwiftUI (eigenes Baby-Grün-Theme wie die Flutter-App)
- **Bundle-ID:** `ch.tschir.HelloBaby` (identisch zur Flutter-App → Installation ist ein Update)
- **Version:** 3.0.0, `CURRENT_PROJECT_VERSION` lokal 100, in CI `100 + run_number`
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

## Build

```bash
xcodebuild -project HelloBaby.xcodeproj -scheme HelloBaby \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Der Code ist unter `SWIFT_STRICT_CONCURRENCY=complete` warnungsfrei.

## CI

- `.github/workflows/build-ipa.yml` (manuell): unsignierte IPA als
  GitHub-Release (`v3.0.0-<run>`), zum Sideloading.
- `.github/workflows/upload-app-store.yml` (manuell): signierte IPA nach
  App Store Connect / TestFlight. Benötigt das GitHub Environment
  `app-store` mit denselben sechs Secrets wie im früheren Flutter-Repo:
  `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`,
  `APP_STORE_CONNECT_API_KEY_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`,
  `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`.
