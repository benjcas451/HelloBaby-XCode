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

  Bilder/Video-Poster liefert /api/thumb.php, die Medien selbst \
  /api/media.php?file=… (&download=1 erzwingt den Download). Die App ruft \
  beide mit denselben Kopfzeilen ab wie die übrigen Endpunkte — hinter \
  Cloudflare Access ist das zwingend, sonst blockiert der Rand die Anfrage.

  Authentifizierung je nach Modus:
  • API-Key: HTTP-Header X-API-Key
  • mTLS: Client-Zertifikat (client.crt + client.key), API-Key optional
  • Cloudflare Access: Header CF-Access-Client-Id und \
  CF-Access-Client-Secret, API-Key optional

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
  @State private var cfClientId = AppSettings.cfAccessClientId
  @State private var cfClientSecret = AppSettings.cfAccessClientSecret
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
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        personenSektion
        titelSektion
        datenquelleSektion
        if mode == .local {
          backupSektion
        } else {
          serverSektion
          importSektion
        }
        erklaerungSektion
      }
      .padding(.horizontal, Mh.rand)
      .padding(.bottom, Mh.abstand8)
      .hbBreite()
    }
    .scrollDismissesKeyboard(.interactively)
    .background(Mh.bg.ignoresSafeArea())
    .navigationTitle("Einstellungen")
    .navigationBarTitleDisplayMode(.large)
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
      HbTextBlatt(titel: "Aufbau der API", text: apiInfoText)
    }
    .sheet(isPresented: $dbDialog) {
      HbTextBlatt(titel: "Aufbau der Datenbank", text: dbInfoText)
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
    VStack(alignment: .leading, spacing: 0) {
      MhGruppenLabel("Personen")
      if nutzer.isEmpty {
        Text(
          "Noch keine Person angelegt. Lege mindestens eine an, dann kannst du "
            + "sie beim Eintrag auswählen."
        )
        .mhText(.small)
        .foregroundStyle(Mh.textSecondary)
        .padding(.bottom, Mh.abstand2)
      }
      ForEach(Array(nutzer.enumerated()), id: \.element) { index, name in
        if index > 0 { MhTrennlinie() }
        MhListenZeile(
          name,
          untertitel: name == standardNutzer ? "Wird beim Eintrag vorgewählt" : nil,
          symbol: "MhUser"
        ) {
          MhAuswahl("Standard", gewaehlt: name == standardNutzer) {
            standardNutzer = standardNutzer == name ? "" : name
            AppSettings.defaultUser = standardNutzer
          }
          MhSymbolButton("MhTrash", beschreibung: "\(name) entfernen") {
            entferne(name)
          }
          .padding(.trailing, -Mh.abstand3)
        }
      }
      Button {
        personDialog = true
      } label: {
        MhButtonInhalt("Person hinzufügen", symbol: "MhUserPlus", symbolGroesse: 18)
      }
      .buttonStyle(.mhZweit)
      .padding(.top, Mh.abstand2)
    }
  }

  private var titelSektion: some View {
    VStack(alignment: .leading, spacing: 0) {
      MhGruppenLabel("Name im Titel")
      MhFeld("Name", hinweis: "Die App heißt dann „Hello \(AppSettings.appName)!“.") {
        TextField(AppSettings.defaultAppName, text: $appName)
          .onChange(of: appName) { _, neu in AppSettings.appName = neu }
          .hbFeldRahmen()
      }
    }
  }

  private var datenquelleSektion: some View {
    VStack(alignment: .leading, spacing: 0) {
      MhGruppenLabel("Datenspeicher")
      auswahl(
        gewaehlt: mode == .local,
        titel: "Lokal auf diesem Gerät",
        untertitel: "SQLite-Datenbank und lokaler Medienordner"
      ) {
        mode = .local
        AppSettings.mode = .local
        api.reset()
      }
      MhTrennlinie()
      auswahl(
        gewaehlt: mode != .local,
        titel: "Server",
        untertitel: "API mit API-Key, Client-Zertifikat oder Cloudflare Service Token"
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
    VStack(alignment: .leading, spacing: Mh.abstand2) {
      MhGruppenLabel("Sicherung")
      Button {
        backupErstellen()
      } label: {
        HStack(spacing: Mh.abstand2) {
          if exportiert {
            ProgressView().controlSize(.small).tint(Mh.primary)
          } else {
            MhSymbol("MhSave", groesse: 18)
          }
          Text(exportiert ? "Backup wird erstellt …" : "Backup erstellen und teilen")
        }
      }
      .buttonStyle(MhZweitButtonStil(breit: true))
      .disabled(exportiert || restauriert)

      Button {
        restoreNachfrage = true
      } label: {
        HStack(spacing: Mh.abstand2) {
          if restauriert {
            ProgressView().controlSize(.small).tint(Mh.primary)
          } else {
            MhSymbol("MhUndo", groesse: 18)
          }
          Text(restauriert ? "Backup wird wiederhergestellt …" : "Backup wiederherstellen")
        }
      }
      .buttonStyle(MhZweitButtonStil(breit: true))
      .disabled(exportiert || restauriert)

      Text("Das Backup lässt sich zum Beispiel in iCloud Drive oder Google Drive ablegen.")
        .mhText(.small)
        .foregroundStyle(Mh.textSecondary)
    }
  }

  private var serverSektion: some View {
    VStack(alignment: .leading, spacing: 0) {
      MhGruppenLabel("Anmeldung")
      auswahl(
        gewaehlt: mode == .apiKey,
        titel: "API-Key",
        untertitel: "Empfohlen, Key als X-API-Key-Header"
      ) {
        mode = .apiKey
        AppSettings.mode = .apiKey
        api.reset()
      }
      MhTrennlinie()
      auswahl(
        gewaehlt: mode == .mtls,
        titel: "Client-Zertifikat (mTLS)",
        untertitel: "Anmeldung per client.crt und client.key"
      ) {
        mode = .mtls
        AppSettings.mode = .mtls
        api.reset()
        pruefeZertifikate()
      }
      MhTrennlinie()
      auswahl(
        gewaehlt: mode == .cloudflare,
        titel: "Cloudflare Access",
        untertitel: "Service Token, API-Key optional zusätzlich"
      ) {
        mode = .cloudflare
        AppSettings.mode = .cloudflare
        api.reset()
      }

      MhGruppenLabel("Server")
      VStack(alignment: .leading, spacing: Mh.abstand4) {
        MhFeld("Server-Adresse", hinweis: "Basis-URL ohne /api, z. B. https://baby.example.org") {
          TextField("https://baby.example.org", text: $serverUrl)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: serverUrl) { _, neu in
              AppSettings.serverBase = neu
              api.reset()
            }
            .hbFeldRahmen()
        }

        if mode == .mtls {
          VStack(alignment: .leading, spacing: Mh.abstand2) {
            MhHinweis(
              certLabel,
              titel: certsOk ? "Zertifikate gefunden" : "Keine Zertifikate gefunden",
              art: certsOk ? .erfolg : .fehler)
            HbReihe(abstand: Mh.abstand2) {
              Button {
                zeigeOrdnerwahl = true
              } label: {
                MhButtonInhalt("Ordner wählen", symbol: "MhFolder", symbolGroesse: 18)
              }
              .buttonStyle(.mhZweit)
              Button {
                pruefeZertifikate()
                meldung = certsOk ? "Zertifikate gefunden." : "Keine Zertifikate gefunden."
              } label: {
                MhButtonInhalt("Erneut prüfen", symbol: "MhRefresh", symbolGroesse: 18)
              }
              .buttonStyle(.mhText)
            }
            Button("App-Ordner in der Dateien-App verwenden") {
              certSource.nutzeStandardOrdner()
              pruefeZertifikate()
            }
            .buttonStyle(.mhText)
          }
        }

        // Cloudflare Access prüft das Service Token am Rand und reicht die
        // Anfrage erst danach an den Server weiter. Beide Hälften sind nötig:
        // mit einer weist Cloudflare genauso ab wie ganz ohne.
        if mode == .cloudflare {
          MhFeld("Client-ID", hinweis: "Endet üblicherweise auf „.access“.") {
            SecureField("", text: $cfClientId)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onChange(of: cfClientId) { _, neu in
                AppSettings.cfAccessClientId = neu
                api.reset()
              }
              .hbFeldRahmen()
              .accessibilityLabel("Client-ID")
          }
          MhFeld(
            "Client-Secret",
            hinweis: "Beide Teile des Service Tokens. Sie laufen ab, standardmäßig nach einem Jahr."
          ) {
            SecureField("", text: $cfClientSecret)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .onChange(of: cfClientSecret) { _, neu in
                AppSettings.cfAccessClientSecret = neu
                api.reset()
              }
              .hbFeldRahmen()
              .accessibilityLabel("Client-Secret")
          }
        }

        MhFeld("API-Key", zusatz: mode == .apiKey ? nil : "optional") {
          SecureField("", text: $apiKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: apiKey) { _, neu in
              AppSettings.apiKey = neu
              api.reset()
            }
            .hbFeldRahmen()
            .accessibilityLabel("API-Key")
        }
      }
    }
  }

  private var importSektion: some View {
    VStack(alignment: .leading, spacing: Mh.abstand2) {
      MhGruppenLabel("Übernahme")
      Button {
        importNachfrage = true
      } label: {
        HStack(spacing: Mh.abstand2) {
          if importiert {
            ProgressView().controlSize(.small).tint(Mh.primary)
          } else {
            MhSymbol("MhUpload", groesse: 18)
          }
          Text(
            importiert
              ? "Import \(importStand.0) / \(importStand.1) …"
              : "Lokale Daten importieren")
        }
      }
      .buttonStyle(MhZweitButtonStil(breit: true))
      .disabled(importiert)
      Text("Überträgt lokale Einträge einmalig zum eingestellten Server.")
        .mhText(.small)
        .foregroundStyle(Mh.textSecondary)
    }
  }

  private var erklaerungSektion: some View {
    VStack(alignment: .leading, spacing: 0) {
      MhGruppenLabel("Erklärung")
      if mode != .local {
        Button {
          infoDialog = true
        } label: {
          MhListenZeile("Aufbau der API", symbol: "MhCloud", pfeil: true)
        }
        .buttonStyle(.plain)
        MhTrennlinie()
      }
      Button {
        dbDialog = true
      } label: {
        MhListenZeile("Aufbau der Datenbank", symbol: "MhInfo", pfeil: true)
      }
      .buttonStyle(.plain)
    }
  }

  /// Auswahlzeile mit Optionsfeld: Titel, Nebentext, ganze Zeile tippbar.
  private func auswahl(
    gewaehlt: Bool, titel: String, untertitel: String, wirkung: @escaping () -> Void
  ) -> some View {
    Button(action: wirkung) {
      HStack(spacing: Mh.abstand3) {
        ZStack {
          Circle()
            .strokeBorder(gewaehlt ? Mh.primary : Mh.borderStrong, lineWidth: 1.5)
            .frame(width: 20, height: 20)
          if gewaehlt {
            Circle().fill(Mh.primary).frame(width: 10, height: 10)
          }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(titel)
            .font(.custom(MhSchrift.medium, size: 16, relativeTo: .body))
            .foregroundStyle(Mh.textStrong)
          Text(untertitel).mhText(.small).foregroundStyle(Mh.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, Mh.abstand3)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(gewaehlt ? [.isSelected] : [])
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
