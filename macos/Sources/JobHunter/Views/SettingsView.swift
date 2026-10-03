import JobHunterCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings

    @State private var password = ""
    @State private var testResult: String?
    @State private var testOK = false
    @State private var testing = false
    @State private var pickCV = false
    @State private var accountCheck: String?
    @State private var accountOK = false
    @State private var mailAccounts: [String] = []

    var body: some View {
        @Bindable var settings = settings
        TabView {
            Form {
                Section {
                    TextField("Server-URL", text: $settings.serverURL, prompt: Text("https://jobs.example.org"))
                        .textContentType(.URL)
                    TextField("Benutzer", text: $settings.username, prompt: Text("DASHBOARD_USER"))
                        .textContentType(.username)
                    SecureField("Passwort", text: $password, prompt: Text("DASHBOARD_PASSWORD"))
                        .textContentType(.password)
                        .onSubmit { Task { await saveAndTest() } }
                    if settings.passwordFromEnvironment {
                        Text("Passwort kommt aus JOBHUNTER_PASSWORD (Umgebungsvariable) und wird nicht gespeichert.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Das Passwort wird im macOS-Schlüsselbund gespeichert.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !settings.serverURL.isEmpty && ServerConfig.normalizedURL(settings.serverURL) == nil {
                        Label("Ungültige URL", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                Section {
                    HStack {
                        Button("Speichern & Verbindung testen") { Task { await saveAndTest() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let testResult {
                        Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Server", systemImage: "server.rack") }

            Form {
                Section("Aktualisierung") {
                    Stepper(value: $settings.refreshMinutes, in: 1...240, step: settings.refreshMinutes < 5 ? 1 : 5) {
                        LabeledContent("Automatisch alle", value: "\(settings.refreshMinutes) min")
                    }
                    .onChange(of: settings.refreshMinutes) { model.restartAutoRefresh() }
                }
                Section("Benachrichtigungen") {
                    Toggle("Mitteilung bei neuen passenden Stellen", isOn: $settings.notificationsEnabled)
                        .onChange(of: settings.notificationsEnabled) { _, on in
                            if on { Task { await NotificationManager.shared.requestAuthorization() } }
                        }
                    Stepper(value: $settings.notifyThreshold, in: 0...100, step: 5) {
                        LabeledContent("Ab Score", value: "\(settings.notifyThreshold)")
                    }
                    Text("Gilt auch für die Anzeige in der Menüleiste (neue, noch nicht bearbeitete Stellen ab diesem Score).")
                        .font(.caption).foregroundStyle(.secondary)
                    if !NotificationManager.shared.isAvailable {
                        Text("Mitteilungen sind nur in der gebündelten JobHunter.app verfügbar.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Allgemein", systemImage: "gearshape") }

            mailTab
                .formStyle(.grouped)
                .tabItem { Label("E-Mail-Versand", systemImage: "paperplane") }

            aiTab
                .formStyle(.grouped)
                .tabItem { Label("KI-Anschreiben", systemImage: "sparkles") }

            alertsTab
                .formStyle(.grouped)
                .tabItem { Label("Job-Alerts", systemImage: "bell.badge") }

            offlineTab
                .formStyle(.grouped)
                .tabItem { Label("Offline", systemImage: "wifi.slash") }
        }
        .frame(width: 680, height: 600)
        .onAppear { password = settings.password }
    }

    private var mailTab: some View {
        @Bindable var settings = settings
        let s = model.sendSettings
        return Form {
            Section("Server (config.yaml › send)") {
                if let s {
                    LabeledContent("Modus", value: s.mode + (s.dryRun ? " · TESTMODUS (dry_run)" : " · ECHT"))
                    if s.killSwitch { Label("Not-Aus aktiv", systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
                    LabeledContent("Absender", value: "\(s.senderName) <\(s.fromAddress)>")
                    LabeledContent("Regeln", value: "Auto ab Score \(s.autoMinScore) · max. \(s.dailyCap)/Tag · Firma \(s.companyCooldownDays) Tage gesperrt")
                    LabeledContent("Heute gesendet", value: "\(s.sentToday) von \(s.dailyCap) · insgesamt \(s.sentTotal) · Test \(s.dryRunTotal)")
                } else {
                    Text("Server nicht erreichbar oder zu alt – es wird nichts gesendet.").foregroundStyle(.secondary)
                }
                Button("Neu laden") { Task { await model.refreshSendState() } }
            }
            Section("Automatisch senden") {
                Toggle("Automatisch senden", isOn: $settings.autoSendEnabled)
                    .onChange(of: settings.autoSendEnabled) { Task { await model.refreshSendState() } }
                Text("Wirkt nur, wenn der Server send.mode = auto und dry_run = false hat. Dann sendet die App bei jeder Aktualisierung alle Stellen, die die Server-Regeln erlauben (Score, Tageslimit, Firmen-Sperrfrist, Sperrliste, kein Vorlagen-Anschreiben) – mit Mitteilung pro Bewerbung. Im Dashboard freigegebene Stellen werden (außer im Testmodus) auch ohne diesen Schalter gesendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lebenslauf (Anhang)") {
                HStack {
                    TextField("PDF", text: $settings.cvPath, prompt: Text(AppSettings.defaultCVPath))
                    Button("Auswählen …") { pickCV = true }
                }
                let exists = FileManager.default.fileExists(atPath: SendCoordinator.expand(settings.cvPath))
                Label(exists ? "Datei gefunden" : "Datei nicht gefunden – ohne Lebenslauf wird nicht gesendet",
                      systemImage: exists ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(exists ? .green : .orange)
                    .font(.caption)
            }
            .fileImporter(isPresented: $pickCV, allowedContentTypes: [.pdf]) { result in
                if case .success(let url) = result {
                    settings.cvPath = (url.path as NSString).abbreviatingWithTildeInPath
                }
            }
            Section("Apple Mail") {
                Button("Mail-Konto prüfen") { Task { await checkAccount() } }
                if let accountCheck {
                    Label(accountCheck, systemImage: accountOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(accountOK ? .green : .red)
                        .textSelection(.enabled)
                }
                Text("Liest nur die Adressen deiner Mail-Accounts (es wird nichts gesendet). Beim ersten Mal fragt macOS, ob JobHunter Mail steuern darf – bitte „Erlauben“. Später änderbar unter Systemeinstellungen › Datenschutz & Sicherheit › Automation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var aiTab: some View {
        @Bindable var settings = settings
        let runner = model.opencode
        return Form {
            Section("opencode (Terminal-KI)") {
                TextField("Programm", text: $settings.opencodePath, prompt: Text(OpencodeRunner.defaultExecutable))
                Label(runner.isInstalled ? "opencode gefunden" : "opencode nicht gefunden",
                      systemImage: runner.isInstalled ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(runner.isInstalled ? .green : .orange)
                    .font(.caption)
                HStack {
                    Picker("Modell", selection: $settings.letterModel) {
                        ForEach(model.availableModels, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Modelle laden") { Task { await model.loadModels() } }
                }
                TextField("Anderes Modell", text: $settings.letterModel, prompt: Text("provider/modell"))
                    .font(.caption)
                Stepper(value: $settings.letterTimeout, in: 30...600, step: 30) {
                    LabeledContent("Zeitlimit", value: "\(settings.letterTimeout) s")
                }
                Text("Standard: opencode/big-pickle. Lokale Modelle (z. B. ollama/maternion/spark-x2.5:4b-q4_K_M) funktionieren ohne Internet, sind aber langsamer und schwächer. Die Liste kommt aus „opencode models“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Profil (Fakten für das Anschreiben)") {
                TextField("cv_profile.md", text: $settings.cvProfilePath, prompt: Text(LetterPrompt.defaultCVProfilePath))
                let exists = FileManager.default.fileExists(atPath: (settings.cvProfilePath as NSString).expandingTildeInPath)
                Label(exists ? "Profil gefunden" : "Profil nicht gefunden",
                      systemImage: exists ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(exists ? .green : .orange)
                    .font(.caption)
                Text("Regeln wie auf dem Server: Deutsch, Ich-Form, 3–4 kurze Absätze (Einstieg mit dem stärksten Ergebnis · 2–3 Belege aus dem Profil · Bezug zur Anzeige + erste 90 Tage · Bitte um Gespräch), keine Buzzwords, keine erfundenen Zahlen. Antworten mit [Platzhaltern], fremden Zahlen, unter 600 oder über 2200 Zeichen werden verworfen. Es wird nur Text erzeugt – nichts gesendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Automatik") {
                Toggle("Vorlagen automatisch durch KI ersetzen", isOn: $settings.autoReplaceTemplates)
                Text("Nach dem Aktualisieren schreibt die App für offene Stellen, die noch die Vorlage haben, ein KI-Anschreiben – eins nach dem anderen (max. 20 pro Durchgang, abbrechbar). Nur wenn der Server keine KI hat oder es seit 6 Stunden nicht geschafft hat. Selbst bearbeitete Anschreiben bleiben unberührt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Absender im Anschreiben (PDF)") {
                TextField("Name", text: $settings.applicantName)
                TextField("Straße (optional)", text: $settings.applicantStreet)
                TextField("Ort", text: $settings.applicantCity)
                TextField("E-Mail", text: $settings.applicantEmail)
                TextField("Telefon", text: $settings.applicantPhone)
                TextField("LinkedIn", text: $settings.applicantLinkedIn)
                TextField("PDF-Ordner", text: $settings.letterPDFFolder, prompt: Text(AppSettings.defaultLetterPDFFolder))
                HStack {
                    Button("Vom Server übernehmen") {
                        if let a = model.sendSettings?.applicant { settings.adopt(a) }
                    }
                    .disabled(model.sendSettings?.applicant == nil)
                    .help("Übernimmt den Abschnitt applicant: aus der config.yaml des Servers")
                    Button("Standard") { settings.adopt(.standard) }
                }
                Text("„Als PDF speichern“ legt Anschreiben_<Firma>_<Datum>.pdf in diesem Ordner ab (A4, eine Seite, Layout wie der Lebenslauf).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var alertsTab: some View {
        @Bindable var settings = settings
        let choices = mailAccounts.contains(settings.jobAlertAccount) ? mailAccounts : [settings.jobAlertAccount] + mailAccounts
        return Form {
            Section("Job-Alerts aus Mail importieren") {
                Toggle("Job-Alerts aus Mail importieren", isOn: $settings.jobAlertsEnabled)
                HStack {
                    Picker("Mail-Account", selection: $settings.jobAlertAccount) {
                        ForEach(choices, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Accounts laden") { Task { mailAccounts = await model.mailAccountNames() } }
                }
                Stepper(value: $settings.jobAlertDays, in: 1...60) {
                    LabeledContent("Zeitraum", value: settings.jobAlertDays == 1 ? "letzter Tag" : "letzte \(settings.jobAlertDays) Tage")
                }
                HStack {
                    Button("Jetzt importieren") { Task { await model.importJobAlerts(manual: true) } }
                        .disabled(model.isImportingAlerts)
                    if model.isImportingAlerts { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let last = model.alertState.lastRun {
                    LabeledContent("Zuletzt", value: last.formatted(date: .abbreviated, time: .shortened))
                    if let summary = model.alertState.lastSummary {
                        Text(summary).font(.caption).textSelection(.enabled)
                    }
                }
                if !model.alertState.pending.isEmpty {
                    Label("\(model.alertState.pending.count) Stellen warten auf den Server", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange).font(.caption)
                }
                LabeledContent("Verarbeitete Alert-Mails", value: "\(model.alertState.processed.count)")
            }
            Section("So funktioniert es") {
                Text("Liest im Posteingang des gewählten Accounts nur die Job-Alert-E-Mails von LinkedIn („Jobbenachrichtigung“), StepStone und Indeed – nichts wird verschoben, markiert oder gesendet, und die Jobbörsen selbst werden nie aufgerufen (deren AGB verbieten Bots). Titel, Firma, Ort und Link gehen an den Server; schon bekannte Stellen (z. B. von der Arbeitsagentur) werden nicht doppelt angelegt. Automatisch nach dem Aktualisieren, höchstens stündlich und nur, wenn Mail läuft; offline wartet der Import, bis der Server erreichbar ist.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Alerts enthalten keinen Anzeigentext: Solche Stellen sind immer „Manuell bewerben“. In der Stelle „Anzeigentext einfügen“ – danach wird neu bewertet und das KI-Anschreiben geschrieben.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var offlineTab: some View {
        Form {
            Section("Lokaler Speicher") {
                LabeledContent("Ordner", value: model.store.directory.path)
                if let d = model.dataDate {
                    LabeledContent("Daten von", value: d.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Gespeicherte Stellen", value: "\(model.serverJobs.count) (Details: \(model.details.count))")
                LabeledContent("Wartende Änderungen", value: "\(model.pendingCount)")
                Button("Im Finder zeigen") { NSWorkspace.shared.open(model.store.directory) }
                Button("Jetzt synchronisieren") { Task { await model.syncNow() } }
                    .disabled(model.pendingCount == 0)
            }
            Section("Regeln") {
                Text("Ohne Server zeigt die App die zuletzt geladenen Daten. Status, Notizen, „Beworben am“, Anschreiben und eingefügte Anzeigentexte werden lokal gespeichert und beim nächsten Kontakt übertragen. Konflikte: die lokale Änderung gewinnt – außer der Server hat dasselbe Feld nachweislich später geändert (Status/Anschreiben haben Zeitstempel). E-Mails werden offline nie gesendet; „Jetzt suchen“ braucht den Server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func checkAccount() async {
        let from = model.sendSettings?.fromAddress ?? "info@daniele-michelin.com"
        do {
            let addresses = try await AppleMailSender().accountAddresses()
            accountOK = addresses.contains { $0.caseInsensitiveCompare(from) == .orderedSame }
            accountCheck = accountOK ? "Account mit \(from) gefunden."
                : "Kein Mail-Account mit \(from). Gefunden: \(addresses.joined(separator: ", "))"
        } catch {
            accountOK = false
            accountCheck = error.localizedDescription
        }
    }

    private func saveAndTest() async {
        testing = true
        defer { testing = false }
        do {
            try settings.setPassword(password)
        } catch {
            testOK = false
            testResult = error.localizedDescription
            return
        }
        model.serverChanged()
        switch await model.testConnection() {
        case .success(let h):
            testOK = true
            testResult = "Verbunden (API v\(h.apiVersion)" + (h.llmEnabled ? ", LLM: \(h.llm ?? "an")" : ", ohne LLM") + ")"
            await model.refresh()
        case .failure(let error):
            testOK = false
            testResult = error.localizedDescription
        }
    }
}
