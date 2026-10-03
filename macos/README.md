# JobHunter für macOS

Nativer SwiftUI-Client (macOS 15+, Swift 6) für den selbst gehosteten
[job-hunter](../job-hunter)-Server. Spricht ausschließlich mit dessen JSON-API `/api/v1`
(Basic Auth). „Bewerbung öffnen“ öffnet die Originalanzeige im Browser.
Bewerbungen **per E-Mail** sendet die App über **Apple Mail** (Konto
`info@daniele-michelin.com`) – nur nach Bestätigung oder, wenn ausdrücklich eingeschaltet,
automatisch nach den Regeln des Servers. Standard ist der **TESTMODUS**: es wird nichts versendet.

## Funktionen

- **Einstellungen** (⌘,): Server-URL, Benutzer, Passwort (im macOS-Schlüsselbund),
  Aktualisierungsintervall, Benachrichtigungen + Score-Schwelle, „Verbindung testen“.
- **Hauptfenster** (`NavigationSplitView`):
  - Seitenleiste: Ansicht *Stellen* / *Tracker*, Filter Status, Min. Score, Quelle, „Neu seit“.
  - Liste nach Score sortiert, farbige Score-Badges, Status-Chip, Suche (Titel/Firma/Text).
  - Detail: Anzeigentext, Score-Aufschlüsselung, LLM-Begründung, editierbares Anschreiben
    (Speichern ⌘S, Kopieren, Neu generieren), **Bewerbung öffnen**, Status-Picker
    (speichert sofort), Notizen + „Beworben am“.
  - Tracker: Kennzahlen, Diagramm nach Status, letzter Suchlauf (inkl. Fehler),
    Stellen nach Status gruppiert.
- **Menüleiste**: Anzahl neuer Stellen (Status „Neu“, Score ≥ Schwelle) + Schnellliste,
  Jetzt suchen, Aktualisieren.
- **Jetzt suchen** (⇧⌘R): startet einen Lauf auf dem Server, fragt den Status ab und lädt
  danach neu.
- **Automatische Aktualisierung** (Standard alle 15 min) und **Mitteilungen**
  (UserNotifications) für neue Stellen ab der Schwelle. Beim allerersten Start werden
  vorhandene Stellen nur gemerkt, nicht gemeldet. Klick auf eine Mitteilung öffnet die Stelle.
- Dark Mode nativ (nur Systemfarben); verständliche Fehlermeldung, wenn der Server nicht
  erreichbar ist oder die Anmeldung fehlschlägt (Daten bleiben sichtbar).

## Offline, Bewerben-Listen, KI-Anschreiben

- **Offline / Standalone:** jede erfolgreiche Abfrage landet in
  `~/Library/Application Support/JobHunter/<server>/cache.json` (Stellen, geöffnete Details
  inkl. Anzeigentext/Anschreiben/Notizen, Statistik, Versand-Einstellungen, Postausgang).
  Die besten 40 offenen Stellen werden pro Aktualisierung vorgeladen. Ist der Server nicht
  erreichbar, zeigt die App die gespeicherten Daten mit Banner
  „Offline – zeigt gespeicherte Daten von …“ und versucht es alle 2 min erneut.
- **Änderungen offline:** Status, Notizen, „Beworben am“ und Anschreiben gehen zuerst in eine
  Warteschlange (`pending.json`, „x Änderungen warten auf Synchronisierung“) und werden beim
  nächsten Kontakt der Reihe nach per PATCH/PUT übertragen. Konfliktregel: die lokale Änderung
  gewinnt – außer der Server hat dasselbe Feld nachweislich später geändert
  (`status_updated_at` / `letter_updated_at`); dann wird die lokale Änderung verworfen und
  gemeldet. **Offline wird nie gesendet**; Senden ist zusätzlich gesperrt, solange eine Stelle
  nicht synchronisierte Änderungen hat (der Server würde sonst die alte Fassung rendern).
- **Seitenleiste „Bewerben“:** *Heute zu tun* (max. 10 manuelle Stellen nach Score, abhaken =
  beworben), *✉ Automatisch per E-Mail* (Adresse vorhanden, Firma nicht gesperrt),
  *🖐 Manuell bewerben* (keine Adresse → Portal), *✅ Beworben*, *⏸ Später/abgelehnt*.
  Jede Zeile zeigt „Automatisch (E-Mail an …)“ bzw. „MANUELL – über Portal bewerben“; im Detail
  manueller Stellen: „Jetzt manuell bewerben“, „Anschreiben kopieren“, „Als beworben markieren“.
- **Anschreiben mit KI (opencode):** pro Stelle oder „Alle Vorlagen schreiben“ (Symbolleiste).
  Baut den 4-Satz-Prompt wie `jobhunter/llm.py` aus `cv_profile.md` + Anzeigentext und ruft
  `opencode run -m <modell> --format json` auf (Zeitlimit 120 s). Antworten mit `[…]`,
  zu kurzem Text oder Zahlen, die weder im Profil noch in der Anzeige stehen, werden verworfen.
  Gespeichert wird wie ein bearbeitetes Anschreiben (offline in der Warteschlange), lokal als
  „KI (opencode)“ markiert (der Server speichert „manuell“). Einstellungen › KI-Anschreiben:
  Modell (Liste aus `opencode models`, Standard `opencode/big-pickle`), Profilpfad, Zeitlimit.
  Hinweis: `NO_COLOR`/`TERM=dumb` lassen `opencode run` hängen – die App setzt sie nicht.
- **Postausgang:** Kacheln + Zeilen *Gesendet ✅ / Test 🧪 / Wartet ⏳ / Fehler ❌* mit Datum,
  Empfänger, Betreff, Stelle und Grund.
- „Lokal suchen“ (lokales Backend starten) ist bewusst **nicht** eingebaut: die lokale DB hätte
  andere Stellen-IDs als der Server, und es gibt keinen Import-Weg zurück.

## E-Mail-Bewerbungen (Apple Mail)

Der Server entscheidet (Regeln in `config.yaml › send`, siehe README von job-hunter), die App
sendet. Ohne erreichbaren Server wird nie etwas gesendet.

- **Banner oben (immer sichtbar):** „TESTMODUS – es werden keine E-Mails versendet“ (gelb),
  „AUTOMATISCHER VERSAND AKTIV – x von 5 heute“ (rot), „ECHTER VERSAND nur per Klick/Freigabe“
  (grün), „Versand aus“ (grau) – mit Server-Modus, Stand des App-Schalters und den Zählern
  *Heute gesendet · Insgesamt gesendet · Im Testmodus vorbereitet*.
- **Pro Stelle:** „✉ Gesendet am … an …“, „Test – nicht gesendet“, „Bereit zum Senden“,
  „Nur manuell (keine E-Mail-Adresse)“; in der Liste ✉ = E-Mail möglich, ☝ = nur manuell.
- **Detail › E-Mail-Bewerbung:** Empfänger (korrigierbar), komplette Vorschau (Von, An, Betreff,
  Anhang, Text), Sperrgründe des Servers, **Per Mail senden** mit Bestätigungsdialog. Im
  Testmodus öffnet der Button die Nachricht nur sichtbar in Mail, **ohne sie zu senden**, und
  protokolliert einen Testlauf.
- **Automatisch:** bei jeder Aktualisierung holt die App `/api/v1/outbox` und sendet die Einträge
  nacheinander, meldet jeden Versand mit `POST /sent` und zeigt pro Bewerbung eine
  macOS-Mitteilung. Voraussetzungen: Server `send.mode = auto` **und** `dry_run = false`
  **und** in der App *Einstellungen › E-Mail-Versand › Automatisch senden* (Standard AUS).
  Im Dashboard freigegebene Stellen werden auch ohne diesen Schalter gesendet (nie im Testmodus).
- **Postausgang** (Seitenleiste, Menüleiste): alle Sendungen mit Datum, Firma, Stelle, Empfänger,
  echt/Test; „In Mail öffnen“ sucht die Nachricht im Postfach „Gesendet“ (nur lesend) und öffnet sie.
- **Sicherheitsnetze:** ein lokales Protokoll verhindert, dass eine Stelle von diesem Mac zweimal
  gesendet wird (auch wenn der Server den Versand nicht sofort speichern konnte – die Meldung wird
  später nachgeholt); bei einem Fehler (fehlende Berechtigung, Lebenslauf nicht gefunden) stoppt
  die Serie sofort; ohne Lebenslauf-PDF wird nicht gesendet.
- Technik: `NSAppleScript` im App-Prozess, Werte werden als Apple-Event-Parameter an
  AppleScript-Handler übergeben (keine String-Verkettung im Skript). `Info.plist` enthält
  `NSAppleEventsUsageDescription`, die Signatur das Entitlement
  `com.apple.security.automation.apple-events` (Hardened Runtime).

### Vom Testmodus zum echten automatischen Versand

1. Server: einige Tage mit `dry_run: true` laufen lassen, Vorschauen und Dashboard › Postausgang prüfen.
2. App › Einstellungen › **E-Mail-Versand**: Lebenslauf-PDF wählen (Standard
   `~/Bewerbung/Lebenslauf_Daniele_Michelin.pdf`), **Mail-Konto prüfen** (liest nur die
   Kontoadressen; beim ersten Mal fragt macOS nach der Automation-Erlaubnis → *Erlauben*).
3. Server `config.yaml`: `send.mode: auto`, `send.dry_run: false`, Server neu starten.
4. App: **Automatisch senden** einschalten. Das Banner wird rot: „AUTOMATISCHER VERSAND AKTIV“.
5. Stoppen: Schalter aus, oder auf dem Server `send.kill_switch: true` / `mode: off`.
   Erlaubnis zurückziehen: Systemeinstellungen › Datenschutz & Sicherheit › Automation › JobHunter › Mail.

## Voraussetzungen

- macOS 15 oder neuer, Xcode 26.x (hier: `/Volumes/Daten/Applications/Xcode.app`).
- job-hunter-Server mit der API `/api/v1` (Commit „feat: JSON API /api/v1 for native clients“).
  HTTP ist nur für localhost/LAN erlaubt (ATS `NSAllowsLocalNetworking`), sonst HTTPS.

## Bauen und installieren

```bash
scripts/build-app.sh             # -> build/JobHunter.app (Release, ad-hoc signiert)
scripts/build-app.sh --install   # zusätzlich nach ~/Applications kopieren
open build/JobHunter.app
```

Das Skript setzt `DEVELOPER_DIR` auf das Xcode unter `/Volumes/Daten/Applications`, falls
nicht anders gesetzt, baut mit `swift build -c release`, erzeugt das Bundle mit
`Support/Info.plist` + Icon und signiert ad-hoc.

Hinweise:

- Ad-hoc-Signatur: Nach jedem Neubau fragt macOS ggf. einmal, ob JobHunter auf den
  Schlüsselbund-Eintrag zugreifen darf („Immer erlauben“).
- Beim ersten Start kann Gatekeeper bei einer kopierten App warnen → Rechtsklick › Öffnen.
- Xcode: `open Package.swift` (Schema *JobHunter*), oder
  `xcodebuild -scheme JobHunter -destination 'platform=macOS' build`.
  Mitteilungen funktionieren nur im gebündelten `.app` (nicht mit `swift run`).

## Tests

```bash
DEVELOPER_DIR=/Volumes/Daten/Applications/Xcode.app/Contents/Developer swift test
```

`Tests/JobHunterCoreTests` (Swift Testing): Decoding aller API-Antworten anhand von
Fixtures, die aus dem echten Backend erzeugt wurden, Datums-/URL-Helfer, Filter-Query,
`JobUpdate`-Encoding, Erkennung neuer Stellen, sowie Requests (Pfad, Methode, Basic-Auth,
JSON-Body) und Fehlerabbildung gegen eine gestubbte `URLSession`.
`SendTests.swift`: Decoding von send-settings/outbox/preview/sent, Request-Aufbau, Banner-Logik
und der `SendCoordinator` mit einem **Fake-Sender** (Apple Mail wird in Tests nie angesprochen):
im dry_run wird nie `.send` aufgerufen, ohne App-Schalter keine Auto-Sendungen, Server nicht
erreichbar → kein Versand, Kill-Switch/off, Tageskontingent, fehlender Lebenslauf, Fehler stoppt
die Serie, kein Doppelversand bei fehlgeschlagener Server-Meldung.

Fixtures neu erzeugen (offline, ohne echte Zugangsdaten):

```bash
../job-hunter/.venv/bin/python scripts/make_fixtures.py ../job-hunter
```

Offline-Cache/Warteschlange, Konfliktregel, Replay-Reihenfolge, Bewerben-Kategorien,
lokaler Filter, KI-Prompt und Ausgabe-Bereinigung: `OfflineTests.swift`. Ein echter
opencode-Lauf ist optional (schreibt nur Text, sendet nichts):

```bash
JOBHUNTER_E2E_JOB=/pfad/job.json swift test --filter OpencodeE2ETests   # job.json = GET /api/v1/jobs/{id}
```

`JOBHUNTER_DATA_DIR=/tmp/x` lenkt Cache/Warteschlange in einen anderen Ordner (Tests).

## Für Tests/Automatisierung

Ohne gespeicherte Einstellungen zu verändern:

```bash
JOBHUNTER_PASSWORD=… build/JobHunter.app/Contents/MacOS/JobHunter \
  -serverURL http://127.0.0.1:8765 -username test-user -notificationsEnabled NO
```

`-key value` landet in der UserDefaults-Argumentdomäne (nicht persistent);
`JOBHUNTER_PASSWORD` wird nie in den Schlüsselbund geschrieben.

## Aufbau

```
Package.swift
Sources/JobHunterCore/     Modelle, APIClient (async/await), Keychain, NewJobDetector,
                           SendModels, SendCoordinator (Regeln/Ablauf), AppleMailSender
Sources/JobHunter/         SwiftUI-App: AppModel, AppSettings, NotificationManager, Views/
Tests/JobHunterCoreTests/  Swift-Testing-Tests + Fixtures/*.json
Support/                   Info.plist (Vorlage), JobHunter.entitlements, AppIcon.icns
scripts/                   build-app.sh, make_icon.swift, make_fixtures.py
```
