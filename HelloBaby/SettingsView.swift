import SwiftUI
import UniformTypeIdentifiers

/// Beschreibung der REST-API (für den Dialog „Aufbau API“).
private let apiInfoText = """
  Die App spricht die Baby-Tagebuch-REST-API unter der eingestellten \
  Basis-URL an (Pfad /api). Alle Antworten sind JSON.

  Wichtige Endpunkte:

  • GET /api/stats.php?diary=<id> – erster/letzter Eintrag, zufälliges Datum
  • GET /api/entries.php?date=YYYY-MM-DD&diary=<id> – Einträge eines Tages \
  (ebenso ?year=&month=, ?favorites=1 oder ?images=1)
  • POST /api/entries.php (multipart/form-data) – neuen Eintrag anlegen: \
  Felder je Tagebuch + kalender_datum, von_name, diary, optional images[]
  • DELETE /api/entries.php?id=<id>&diary=<id> – Eintrag löschen
  • POST /api/favorite.php mit {"id":…, "diary":"…"} – Favorit umschalten
  • GET /api/gallery.php?folder=uploads/<ordner> – Dateien einer Galerie

  Bilder/Video-Poster liefert /api/thumb.php (offen, ohne Auth), die Medien \
  selbst /api/media.php?file=… (offen; &download=1 erzwingt den Download).

  Authentifizierung der geschützten Endpunkte je nach Modus:
  • API-Key: HTTP-Header X-API-Key
  • mTLS: Client-Zertifikat (client.crt + client.key)

  Fehler kommen als {"error": "…"} mit passendem HTTP-Statuscode.
  """

/// Beschreibung des lokalen Datenmodells (für den Dialog „Aufbau Datenbank“).
private let dbInfoText = """
  Die App führt eine eigene SQLite-Datenbank unter \
  Documents/HelloBaby/hello_baby.sqlite; die Medien liegen daneben in \
  Documents/HelloBaby/media/. Im Modus „Lokal“ ist das die einzige Datenquelle, \
  in den Server-Modi speist sie den einmaligen Import zur API.

  Tabelle "entries":

  • id
    INTEGER, Primärschlüssel (Auto-Increment)

  • diary
    TEXT, Tagebuch: schwangerschaft oder entwicklung

  • kalender_datum
    TEXT, Tag des Eintrags als YYYY-MM-DD

  • bilder
    TEXT, Ordner der Medien dieses Eintrags (media/<diary>_<id>), leer wenn keine. \
  Gespeichert wird ein absoluter Pfad – der Container bekommt bei jeder \
  Neuinstallation eine neue UUID, deshalb biegt die App den Pfad beim Lesen \
  anhand des Ordnernamens auf den aktuellen Container um.

  • von_name
    TEXT, ausgewählter Ersteller

  • favorit
    INTEGER (0/1)

  • created_at
    TEXT, Zeitpunkt der Erfassung als ISO 8601

  • fields_json
    TEXT, die tagebuchspezifischen Felder als JSON-Objekt

  Tabelle "remote_imports" (Schema-Version 2) merkt sich je Server, welcher \
  lokale Eintrag schon zur API übertragen wurde (local_id, diary, server_base, \
  remote_id, imported_at) – deshalb legt ein erneuter Import keine Duplikate an.

  Die Server-API verwendet dasselbe Datenmodell; die Medien liegen dort unter \
  uploads/<ordner> statt im lokalen Medienordner.

  Sicherung & Gerätewechsel

  Datenbank und Medienordner liegen in Documents und werden vom iCloud-Backup \
  mitgesichert. Das ist Absicht: Fotos und Videos existieren nur hier, ein \
  Ausschluss würde sie beim Gerätewechsel verlieren.

  Der API-Key liegt dagegen nicht in den Einstellungen, sondern in der Keychain. \
  Er wandert beim Direkttransfer auf ein neues Gerät (Schnellstart) und im \
  verschlüsselten Backup über den Computer mit, lässt sich aus einem \
  iCloud-Backup aber nicht wiederherstellen. Nach einer Wiederherstellung aus \
  iCloud ist er einmal neu einzutragen.

  Ein selbst gewählter Zertifikats-Ordner wird als Lesezeichen gespeichert. Die \
  Leseberechtigung überlebt einen Gerätewechsel nicht – die App meldet das und \
  bittet darum, den Ordner erneut auszuwählen.

  Unabhängig davon lässt sich im Modus „Lokal“ jederzeit ein vollständiges \
  ZIP-Backup inklusive Medien sichern und wieder einspielen.
  """

struct SettingsView: View {

  @State private var mode = AppSettings.mode
  @State private var serverUrl = AppSettings.serverBase
  @State private var apiKey = AppSettings.apiKey
  @State private var appName = AppSettings.appName
  @State private var nutzer = AppSettings.users
  @State private var standardNutzer = AppSettings.defaultUser
  @State private var certsOk = false
  @State private var certLabel = ""

  @State private var personDialog = false
  @State private var neuerName = ""
  @State private var infoDialog = false
  @State private var dbDialog = false
  @State private var meldung: String?

  @State private var exportiert = false
  @State private var backupURL: URL?
  @State private var restoreNachfrage = false
  @State private var zeigeRestoreImporter = false
  @State private var restauriert = false

  @State private var zeigeOrdnerwahl = false
  @State private var importNachfrage = false
  @State private var importiert = false
  @State private var importStand = (0, 0)

  private let api = ApiClient.shared
  private let certSource = CertSource()

  var body: some View {
    Form {
      personenSektion
      titelSektion
      datenquelleSektion
      if mode == .local {
        backupSektion
      } else {
        serverSektion
        importSektion
      }
      Section {
        if mode != .local {
          Button {
            infoDialog = true
          } label: {
            Label("Aufbau API", systemImage: "cloud")
          }
        }
        Button {
          dbDialog = true
        } label: {
          Label("Aufbau Datenbank", systemImage: "cylinder.split.1x2")
        }
      }
    }
    .navigationTitle("Einstellungen")
    .navigationBarTitleDisplayMode(.inline)
    .task { pruefeZertifikate() }
    .alert("Person hinzufügen", isPresented: $personDialog) {
      TextField("Name", text: $neuerName)
      Button("Hinzufügen") { personHinzufuegen() }
      Button("Abbrechen", role: .cancel) { neuerName = "" }
    }
    .alert(
      "Hinweis",
      isPresented: .init(get: { meldung != nil }, set: { if !$0 { meldung = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(meldung ?? "")
    }
    .alert("Backup wiederherstellen?", isPresented: $restoreNachfrage) {
      Button("Backup auswählen", role: .destructive) { zeigeRestoreImporter = true }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Alle derzeit lokal gespeicherten Einträge und Medien werden durch den "
          + "Inhalt des Backups ersetzt. Dieser Vorgang kann nicht rückgängig "
          + "gemacht werden.")
    }
    .alert("Lokale Daten importieren?", isPresented: $importNachfrage) {
      Button("Import starten") { lokalImportieren() }
      Button("Abbrechen", role: .cancel) {}
    } message: {
      Text(
        "Noch nicht übertragene lokale Einträge werden inklusive Medien und "
          + "Favoriten an die aktuell eingestellte API gesendet. Bereits für "
          + "diesen Server importierte Einträge werden übersprungen.")
    }
    .sheet(isPresented: $infoDialog) {
      NavigationStack {
        ScrollView {
          Text(apiInfoText)
            .font(.callout)
            .padding()
        }
        .navigationTitle("Aufbau API")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Schließen") { infoDialog = false }
          }
        }
      }
    }
    .sheet(isPresented: $dbDialog) {
      NavigationStack {
        ScrollView {
          Text(dbInfoText)
            .font(.callout)
            .padding()
        }
        .navigationTitle("Aufbau Datenbank")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarTrailing) {
            Button("Schließen") { dbDialog = false }
          }
        }
      }
    }
    .sheet(
      isPresented: .init(
        get: { backupURL != nil },
        set: {
          if !$0 {
            // Das ZIP hat das Teilen-Blatt hinter sich; es liegt sonst bis
            // zum nächsten Systemputz in tmp/ herum.
            if let backupURL { try? FileManager.default.removeItem(at: backupURL) }
            backupURL = nil
          }
        })
    ) {
      if let backupURL {
        TeilenBlatt(url: backupURL)
      }
    }
    .fileImporter(
      isPresented: $zeigeRestoreImporter,
      allowedContentTypes: [.zip]
    ) { ergebnis in
      if case .success(let url) = ergebnis {
        backupEinspielen(url)
      }
    }
    .fileImporter(
      isPresented: $zeigeOrdnerwahl,
      allowedContentTypes: [.folder]
    ) { ergebnis in
      if case .success(let url) = ergebnis {
        do {
          try certSource.uebernehmeOrdner(url: url)
        } catch {
          meldung = "Ordner konnte nicht übernommen werden: \(error.localizedDescription)"
        }
        pruefeZertifikate()
      }
    }
  }

  // MARK: - Sektionen

  private var personenSektion: some View {
    Section("Personen") {
      if nutzer.isEmpty {
        Text(
          "Noch keine Person angelegt. Lege mindestens eine Person an, um sie "
            + "beim Erstellen eines Eintrags als Ersteller auswählen zu können."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      ForEach(nutzer, id: \.self) { name in
        HStack {
          Image(systemName: "person")
          VStack(alignment: .leading) {
            Text(name)
            if name == standardNutzer {
              Text("Standard").font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button {
            standardNutzer = standardNutzer == name ? "" : name
            AppSettings.defaultUser = standardNutzer
          } label: {
            Image(systemName: name == standardNutzer ? "checkmark.square.fill" : "square")
              .foregroundStyle(Hb.accentDeep)
          }
          .buttonStyle(.plain)
          Button {
            entferne(name)
          } label: {
            Image(systemName: "trash")
              .foregroundStyle(.red.opacity(0.7))
          }
          .buttonStyle(.plain)
        }
      }
      Button {
        personDialog = true
      } label: {
        Label("Person hinzufügen", systemImage: "person.badge.plus")
      }
    }
  }

  private var titelSektion: some View {
    Section("App-Titel") {
      TextField(AppSettings.defaultAppName, text: $appName)
        .onChange(of: appName) { _, neu in AppSettings.appName = neu }
      Text("Die App heißt dann „Hello NAME!“.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var datenquelleSektion: some View {
    Section("Datenspeicher") {
      auswahl(
        gewaehlt: mode == .local,
        titel: "Lokal auf diesem Gerät",
        untertitel: "SQLite-Datenbank und lokaler Medienordner."
      ) {
        mode = .local
        AppSettings.mode = .local
        api.reset()
      }
      auswahl(
        gewaehlt: mode != .local,
        titel: "API",
        untertitel: "Server-API mit API-Key oder Client-Zertifikat."
      ) {
        if mode == .local {
          mode = .apiKey
          AppSettings.mode = .apiKey
          api.reset()
        }
      }
    }
  }

  private var backupSektion: some View {
    Section("Backup") {
      Button {
        backupErstellen()
      } label: {
        HStack {
          if exportiert {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "icloud.and.arrow.up")
          }
          Text(exportiert ? "Backup wird erstellt…" : "Backup erstellen & teilen")
        }
      }
      .disabled(exportiert || restauriert)

      Button {
        restoreNachfrage = true
      } label: {
        HStack {
          if restauriert {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.counterclockwise")
          }
          Text(restauriert ? "Backup wird wiederhergestellt…" : "Backup wiederherstellen")
        }
      }
      .disabled(exportiert || restauriert)

      Text("Das Backup lässt sich z. B. in iCloud Drive oder Google Drive ablegen.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private var serverSektion: some View {
    Group {
      Section("Authentifizierung") {
        auswahl(
          gewaehlt: mode == .apiKey,
          titel: "API-Key",
          untertitel: "Empfohlen. Key als X-API-Key-Header."
        ) {
          mode = .apiKey
          AppSettings.mode = .apiKey
          api.reset()
        }
        auswahl(
          gewaehlt: mode == .mtls,
          titel: "Client-Zertifikat (mTLS)",
          untertitel: "Authentifizierung per client.crt/client.key"
        ) {
          mode = .mtls
          AppSettings.mode = .mtls
          api.reset()
          pruefeZertifikate()
        }
      }

      Section("Server") {
        TextField("https://baby.example.org", text: $serverUrl)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .onChange(of: serverUrl) { _, neu in
            AppSettings.serverBase = neu
            api.reset()
          }
        Text("Basis-URL ohne /api.")
          .font(.footnote)
          .foregroundStyle(.secondary)

        if mode == .mtls {
          HStack {
            Image(systemName: certsOk ? "checkmark.circle.fill" : "xmark.circle.fill")
              .foregroundStyle(certsOk ? Hb.accentDeep : .red)
            VStack(alignment: .leading) {
              Text(certsOk ? "Zertifikate gefunden" : "Keine Zertifikate gefunden")
              Text(certLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Button {
            zeigeOrdnerwahl = true
          } label: {
            Label("Zertifikats-Ordner wählen", systemImage: "folder")
          }
          Button {
            certSource.nutzeStandardOrdner()
            pruefeZertifikate()
          } label: {
            Label("Standard: App-Ordner (Dateien-App)", systemImage: "folder.badge.gearshape")
          }
          Button {
            pruefeZertifikate()
            meldung = certsOk ? "Zertifikate gefunden." : "Keine Zertifikate gefunden."
          } label: {
            Label("Erneut prüfen", systemImage: "arrow.clockwise")
          }
        }

        SecureField(
          mode == .mtls ? "API-Key (optional)" : "API-Key", text: $apiKey
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .onChange(of: apiKey) { _, neu in
          AppSettings.apiKey = neu
          api.reset()
        }
      }
    }
  }

  private var importSektion: some View {
    Section {
      Button {
        importNachfrage = true
      } label: {
        HStack {
          if importiert {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "square.and.arrow.up.on.square")
          }
          Text(
            importiert
              ? "Import \(importStand.0) / \(importStand.1)…"
              : "Lokale Daten importieren")
        }
      }
      .disabled(importiert)
      Text("Überträgt lokale Einträge einmalig zur eingestellten API.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private func auswahl(
    gewaehlt: Bool, titel: String, untertitel: String, wirkung: @escaping () -> Void
  ) -> some View {
    Button(action: wirkung) {
      HStack {
        Image(systemName: gewaehlt ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(Hb.accentDeep)
        VStack(alignment: .leading) {
          Text(titel).foregroundStyle(.primary)
          Text(untertitel).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - Aktionen

  private func personHinzufuegen() {
    let name = neuerName.trimmingCharacters(in: .whitespaces)
    neuerName = ""
    guard !name.isEmpty else { return }
    guard !nutzer.contains(where: { $0.lowercased() == name.lowercased() }) else {
      meldung = "„\(name)“ ist bereits angelegt."
      return
    }
    nutzer.append(name)
    AppSettings.users = nutzer
  }

  private func entferne(_ name: String) {
    nutzer.removeAll { $0 == name }
    AppSettings.users = nutzer
    if AppSettings.selectedUser == name { AppSettings.selectedUser = "" }
    if standardNutzer == name {
      standardNutzer = ""
      AppSettings.defaultUser = ""
    }
  }

  private func pruefeZertifikate() {
    // Nebenbei: legt die Hinweisdatei an, falls sie fehlt. Damit laesst sich
    // der App-Ordner in der Dateien-App auch ohne Neustart hervorholen.
    AppOrdner.sichtbarMachen()
    certsOk = certSource.sindVorhanden
    certLabel = certSource.locationLabel
  }

  private func backupErstellen() {
    exportiert = true
    Task {
      do {
        backupURL = try await BackupService().export()
      } catch {
        meldung = "Backup fehlgeschlagen: \(error.localizedDescription)"
      }
      exportiert = false
    }
  }

  private func backupEinspielen(_ url: URL) {
    restauriert = true
    Task {
      do {
        let anzahl = try await BackupService().restore(from: url)
        meldung = "\(anzahl) Einträge wurden wiederhergestellt."
      } catch {
        meldung = "Wiederherstellung fehlgeschlagen: \(error.localizedDescription)"
      }
      restauriert = false
    }
  }

  private func lokalImportieren() {
    importiert = true
    importStand = (0, 0)
    Task {
      do {
        AppSettings.serverBase = serverUrl
        AppSettings.apiKey = apiKey
        api.reset()
        let ergebnis = try await ImportService().importieren(
          api: api, server: AppSettings.serverBase
        ) { aktuell, gesamt in
          Task { @MainActor in importStand = (aktuell, gesamt) }
        }
        meldung =
          "\(ergebnis.imported) Einträge importiert, \(ergebnis.skipped) bereits vorhanden."
      } catch {
        meldung = "Import fehlgeschlagen: \(error.localizedDescription)"
      }
      importiert = false
    }
  }
}

/// Systemweites Teilen-Blatt für die Backup-Datei.
private struct TeilenBlatt: UIViewControllerRepresentable {
  let url: URL

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
