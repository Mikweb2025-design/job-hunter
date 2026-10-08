import JobHunterCore
import SwiftUI

struct JobDetailView: View {
    let jobID: Int
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    @State private var detail: JobDetail?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var info: String?

    // Editable state
    @State private var letter = ""
    @State private var pdfRunning = false
    @State private var notes = ""
    @State private var hasAppliedDate = false
    @State private var appliedDate = Date.now
    @State private var busy = false
    @State private var confirmRegenerate = false
    @State private var confirmAI = false
    @State private var aiRunning = false

    // "Anzeigentext einfügen" (job alerts carry no posting text)
    @State private var posting = ""
    @State private var editPosting = false
    @State private var waitingForLetter: Task<Void, Never>?

    // E-mail application
    @State private var preview: EmailPreview?
    @State private var previewError: String?
    @State private var applyEmail = ""
    @State private var confirmSend = false

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let loadError {
                ContentUnavailableView {
                    Label("Stelle konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Erneut versuchen") { Task { await load() } }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: jobID) { await load() }
        .onChange(of: model.sendGeneration) { Task { await loadPreview() } }
        .onChange(of: model.pendingCount) { refreshFromModel() }
        .onChange(of: model.connection) { _, new in
            if new == .ok && preview == nil { Task { await loadPreview() } }
        }
    }

    // MARK: Layout

    private func content(_ d: JobDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(d)
                applyBox(d)
                if !model.pendingChanges(for: jobID).isEmpty {
                    Label("Lokal gespeichert – \(pendingText(model.pendingChanges(for: jobID).count)) (\(model.pendingChanges(for: jobID).map(\.field.label).joined(separator: ", ")))",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout).foregroundStyle(.orange)
                } else if model.isOffline {
                    Label("Offline – gespeicherte Daten", systemImage: "wifi.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let actionError {
                    MessageRow(text: actionError, isError: true) { self.actionError = nil }
                } else if let info {
                    MessageRow(text: info, isError: false) { self.info = nil }
                }
                mailBox(d)
                trackerBox(d)
                scoreBox(d)
                if let reason = d.reason, !reason.isEmpty {
                    GroupBox {
                        Text(reason)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("Begründung (LLM)", systemImage: "text.bubble")
                    }
                }
                if !d.hasPostingText { postingBox(d) }
                letterBox(d)
                if d.hasPostingText { postingBox(d) }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .navigationTitle(d.summary.title)
        .disabled(busy)
        .onDisappear { waitingForLetter?.cancel() }
    }

    private func postingBox(_ d: JobDetail) -> some View {
        let isAlert = AlertSource(rawValue: d.summary.source) != nil
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !d.description.isEmpty && !(editPosting || !d.hasPostingText) {
                    Text(d.description)
                        .font(.body)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
                if !d.hasPostingText {
                    Label(isAlert
                          ? "Job-Alert-E-Mails enthalten keinen Anzeigentext. Anzeige öffnen („Bewerbung öffnen“), Text kopieren und hier einfügen – danach wird die Stelle neu bewertet und das KI-Anschreiben geschrieben."
                          : "Kein oder nur sehr kurzer Anzeigentext. Text aus der Anzeige hier einfügen – danach wird neu bewertet und das KI-Anschreiben geschrieben.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if editPosting || !d.hasPostingText {
                    TextEditor(text: $posting)
                        .font(.body)
                        .frame(minHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    HStack {
                        Button {
                            if let text = NSPasteboard.general.string(forType: .string) { posting = text }
                        } label: {
                            Label("Aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
                        }
                        Text("\(posting.trimmingCharacters(in: .whitespacesAndNewlines).count) Zeichen (KI ab \(JobSummary.minPostingText))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if editPosting {
                            Button("Abbrechen") { editPosting = false; posting = "" }
                        }
                        Button {
                            savePosting()
                        } label: {
                            Label("Speichern & neu bewerten", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(posting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || posting.trimmingCharacters(in: .whitespacesAndNewlines) == d.description)
                    }
                } else {
                    HStack {
                        Spacer()
                        Button("Anzeigentext ersetzen …") {
                            posting = d.description
                            editPosting = true
                        }
                        .controlSize(.small)
                    }
                }
            }
        } label: {
            Label(d.hasPostingText ? "Anzeigentext" : "Anzeigentext einfügen", systemImage: "doc.plaintext")
        }
    }

    private func savePosting() {
        let oldLetter = detail?.letter ?? ""
        let online = model.isOnline
        applyLocal(model.saveDescription(id: jobID, text: posting),
                   online ? "Anzeigentext gespeichert – der Server bewertet neu und schreibt das KI-Anschreiben (30–120 s)."
                          : "Anzeigentext offline gespeichert – wird beim nächsten Kontakt übertragen, dann neu bewertet.",
                   keepLetter: true, keepNotes: true)
        posting = ""
        editPosting = false
        guard online else { return }
        // Pick up the new score and (later) the server's KI letter while this job is open.
        waitingForLetter?.cancel()
        let id = jobID
        waitingForLetter = Task {
            for _ in 0..<18 {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, id == jobID else { return }
                guard (try? await model.loadDetail(id: id)) != nil else { continue }
                refreshFromModel()
                if let l = detail?.letter, !l.isEmpty, l != oldLetter {
                    info = "KI-Anschreiben vom Server ist da."
                    return
                }
            }
        }
    }

    private func header(_ d: JobDetail) -> some View {
        let s = d.summary
        return HStack(alignment: .top, spacing: 16) {
            ScoreBadge(score: s.score, large: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if !s.companyAndLocation.isEmpty {
                    Text(s.companyAndLocation).font(.title3).foregroundStyle(.secondary)
                }
                SendBadge(state: preview?.sendState ?? s.sendState)
                HStack(spacing: 12) {
                    if s.remote { Label("Remote möglich", systemImage: "house") }
                    if let salary = s.salaryText { Label(salary, systemImage: "eurosign.circle") }
                    Label(sourceLabel(s.source) + (s.alsoSeenOn.isEmpty ? "" : " (+ " + s.alsoSeenOn.map(sourceLabel).joined(separator: ", ") + ")"),
                          systemImage: "tray.and.arrow.down")
                    if let date = ServerDate.parse(s.published) ?? s.fetchedDate {
                        Label { Text(date, format: .dateTime.day().month().year()) } icon: { Image(systemName: "calendar") }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                HStack {
                    Button {
                        if let link = JobLinks.applyLink(for: s) { openURL(link) }
                    } label: {
                        Label("Bewerbung öffnen", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(JobLinks.applyLink(for: s) == nil)
                    .help(JobLinks.applyLink(for: s)?.absoluteString ?? "Kein Link vorhanden")
                    moreLinksMenu(s)
                    Text("Öffnet die Originalanzeige im Browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    /// Big "what do I have to do" box: manual (portal) vs. automatic (e-mail).
    @ViewBuilder
    private func applyBox(_ d: JobDetail) -> some View {
        let s = d.summary
        // Anti-trasloco: a job marked "Zu weit" (or server-classified `far`) is never
        // applied to (neither automatic nor portal) — and the far view has no send
        // button at all. The status can still be changed in the picker below.
        if ApplyCategory.isFar(s) {
            GroupBox {
                Text("Als „Zu weit“ markiert – weder E-Mail noch Portal. Zum Reaktivieren unten einen anderen Status wählen.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } label: {
                Label("Zu weit – nicht bewerben", systemImage: "mappin.slash").font(.headline).foregroundStyle(.secondary)
            }
        } else {
        let category = model.category(of: s)
        switch category {
        case .manual, .later:
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.applyEmail == nil
                         ? "Keine E-Mail-Adresse in der Anzeige – du musst dich selbst über das Portal bewerben."
                         : "Die Firma steht auf der Sperrliste des Servers – nicht automatisch senden, ggf. selbst bewerben.")
                        .font(.callout)
                    HStack(spacing: 10) {
                        Button {
                            if let link = JobLinks.applyLink(for: s) { openURL(link) }
                            if !letter.isEmpty {
                                copyToPasteboard(letter)
                                info = "Portal geöffnet, Anschreiben in die Zwischenablage kopiert."
                            }
                        } label: {
                            Label("Jetzt manuell bewerben", systemImage: "arrow.up.right.square.fill")
                                .font(.title3.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(.orange)
                        .fixedSize()
                        .disabled(JobLinks.applyLink(for: s) == nil)
                        .help(JobLinks.applyLink(for: s)?.absoluteString ?? "Kein Link vorhanden")
                        moreLinksMenu(s)

                        Button {
                            copyToPasteboard(letter)
                            info = "Anschreiben in die Zwischenablage kopiert."
                        } label: {
                            Label("Anschreiben kopieren", systemImage: "doc.on.doc")
                        }
                        .controlSize(.large)
                        .disabled(letter.isEmpty)

                        Button {
                            applyLocal(model.markApplied(id: jobID), "Als beworben markiert" + (model.isOnline ? "." : " – wird synchronisiert, sobald der Server erreichbar ist."))
                        } label: {
                            Label("Als beworben markieren", systemImage: "checkmark.circle")
                        }
                        .controlSize(.large)
                        .disabled(s.status == .beworben)
                    }
                    if !d.hasPostingText && (d.letterIsTemplate || letter.isEmpty) {
                        Label("Noch kein Anschreiben: unten „Anzeigentext einfügen“, dann schreibt die KI das Anschreiben.",
                              systemImage: "doc.badge.plus")
                            .font(.caption).foregroundStyle(.orange)
                    } else if d.letterIsTemplate || letter.isEmpty {
                        Label("Das Anschreiben ist nur eine Vorlage – erst „Anschreiben mit KI schreiben“ (unten) oder selbst anpassen.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("MANUELL bewerben – das musst du selbst tun", systemImage: "hand.point.up.left.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
            .backgroundStyle(.orange.opacity(0.08))
        case .automatic:
            GroupBox {
                Text("Bewerbungs-Adresse \(s.applyEmail ?? "?") vorhanden: die App sendet per Apple Mail – nur nach den Server-Regeln (Testmodus, Freigabe, Tageslimit) und nie offline. Details unten unter „E-Mail-Bewerbung“.")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            } label: {
                Label("Automatisch per E-Mail", systemImage: "envelope.fill").font(.headline).foregroundStyle(.blue)
            }
        case .applied:
            Label(s.sendState?.isSent == true ? "Beworben per E-Mail" : "Beworben" + (s.appliedDate.map { " am \($0)" } ?? ""),
                  systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
        }
        }
    }

    private func mailBox(_ d: JobDetail) -> some View {
        // The far view never has a send button (anti-trasloco); the verdict is shown
        // via blockerTexts instead.
        let isFar = ApplyCategory.isFar(d.summary)
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Empfänger", text: $applyEmail, prompt: Text("keine Adresse – nur manuell bewerben"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                    Button("Adresse speichern") { Task { await saveApplyEmail() } }
                        .disabled(applyEmail.trimmingCharacters(in: .whitespaces) == (preview?.applyEmail ?? ""))
                    if let src = preview?.applyEmailSource {
                        Text(src == "manuell" ? "manuell eingetragen" : "aus der Anzeige erkannt (\(src))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let previewError {
                    Text(previewError).font(.callout).foregroundStyle(.red)
                }
                if let p = preview, let email = p.email {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow { Text("Von").foregroundStyle(.secondary); Text(email.sender) }
                        GridRow { Text("An").foregroundStyle(.secondary); Text(email.to ?? "–") }
                        GridRow { Text("Betreff").foregroundStyle(.secondary); Text(email.subject) }
                        GridRow {
                            Text("Anhang").foregroundStyle(.secondary)
                            Text(cvDisplayPath).foregroundStyle(cvExists ? Color.primary : Color.red)
                                .help(cvExists ? "" : "Datei fehlt – Einstellungen › E-Mail-Versand")
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    Text(email.body)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    if letter != d.letter {
                        Label("Ungespeicherte Änderungen am Anschreiben – gesendet wird die gespeicherte Fassung.",
                              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                    if !p.blockerTexts.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kann jetzt nicht gesendet werden:").font(.caption.weight(.semibold))
                            ForEach(p.blockerTexts, id: \.self) { Text("• \($0)").font(.caption) }
                        }
                        .foregroundStyle(.orange)
                    }
                    HStack {
                        if !isFar {
                            Button {
                                confirmSend = true
                            } label: {
                            Label(p.dryRun ? "Per Mail senden (Testmodus)" : "Per Mail senden", systemImage: "paperplane")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(p.dryRun ? .orange : .accentColor)
                        .disabled(!p.canSend || model.isSending || letter != d.letter || !model.isOnline
                                  || !model.pendingChanges(for: jobID).isEmpty)
                        .confirmationDialog(p.dryRun ? "Testmodus: Nachricht nur in Mail öffnen?" : "Bewerbung jetzt ECHT senden?",
                                            isPresented: $confirmSend, titleVisibility: .visible) {
                            Button(p.dryRun ? "In Mail öffnen (nicht senden)" : "Jetzt über Apple Mail senden",
                                   role: p.dryRun ? nil : .destructive) { Task { await sendNow() } }
                            Button("Abbrechen", role: .cancel) {}
                        } message: {
                            Text(p.dryRun
                                 ? "Der Server ist im Testmodus (dry_run). Die Nachricht wird in Mail angezeigt, aber NICHT gesendet."
                                 : "An: \(email.to ?? "")\nVon: \(email.sender)\nBetreff: \(email.subject)\nAnhang: \(cvDisplayPath)\n\nDas kann nicht zurückgenommen werden.")
                        }
                        }  // if !isFar: the far view has no send button
                        if model.isSending { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(p.dryRun ? "Testmodus: es wird nichts gesendet." : "Sendet über Apple Mail (\(email.from)).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !p.sent.isEmpty {
                        Divider()
                        ForEach(p.sent) { e in
                            HStack {
                                Text(e.dryRun ? "Test – nicht gesendet" : "✉ Gesendet")
                                    .foregroundStyle(e.dryRun ? Color.secondary : Color.red)
                                Text("\(formatted(e.sentAt)) an \(e.to)")
                                Spacer()
                                if !e.dryRun {
                                    Button("In Mail öffnen") { Task { actionError = await model.openInMail(e) } }
                                }
                            }
                            .font(.caption)
                        }
                    }
                    if !model.pendingChanges(for: jobID).isEmpty {
                        Label("Erst synchronisieren: der Server hat noch nicht die lokale Fassung.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else if let p = preview {
                    // Server verdict in the server's own (German) words; generic fallback
                    // only when the server sent no reason.
                    if !p.blockerTexts.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Kann jetzt nicht gesendet werden:").font(.caption.weight(.semibold))
                            ForEach(p.blockerTexts, id: \.self) { Text("• \($0)").font(.caption) }
                        }
                        .foregroundStyle(.orange)
                    } else {
                        Text("Keine Bewerbungs-E-Mail-Adresse in der Anzeige gefunden – nur manuell bewerben (oder Adresse oben eintragen).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        } label: {
            Label("E-Mail-Bewerbung", systemImage: "envelope")
        }
    }

    private var cvDisplayPath: String {
        let raw = model.settings.cvPath.trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? (preview?.email?.attachment ?? "–") : raw
    }

    private var cvExists: Bool {
        FileManager.default.fileExists(atPath: SendCoordinator.expand(cvDisplayPath))
    }

    private func loadPreview() async {
        guard model.isOnline || model.connection == .unknown else {
            previewError = "Offline – E-Mail-Vorschau und Versand nur, wenn der Server erreichbar ist. Es wird nichts gesendet."
            return
        }
        do {
            let p = try await model.emailPreview(id: jobID)
            preview = p
            applyEmail = p.applyEmail ?? ""
            previewError = nil
        } catch {
            previewError = (error as? APIError)?.isConnectivityProblem == true
                ? "Offline – E-Mail-Vorschau und Versand nur, wenn der Server erreichbar ist. Es wird nichts gesendet."
                : error.localizedDescription
        }
    }

    private func saveApplyEmail() async {
        let value = applyEmail.trimmingCharacters(in: .whitespaces)
        await perform("Adresse gespeichert.", keepLetter: true, keepNotes: true) {
            try await model.setApplyEmail(id: jobID, value)
        }
        await loadPreview()
    }

    private func sendNow() async {
        actionError = nil
        info = nil
        do {
            switch try await model.sendNow(jobID: jobID) {
            case .sent(_, let to, _, let recorded):
                info = "Bewerbung an \(to) gesendet." + (recorded ? "" : " (Server-Protokoll wird nachgeholt.)")
            case .drafted(_, let to, _):
                info = "Testmodus: Nachricht an \(to) in Mail geöffnet, NICHT gesendet."
            case .skipped(_, let reason):
                info = "Nicht gesendet: \(reason)"
            }
            if let d = try? await model.loadDetail(id: jobID) { apply(d) }
        } catch {
            actionError = error.localizedDescription
        }
        await loadPreview()
    }

    private func trackerBox(_ d: JobDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Picker("Status", selection: statusBinding(d)) {
                        ForEach(JobStatus.allCases) { s in
                            Label(s.label, systemImage: s.symbolName).tag(s)
                        }
                    }
                    .frame(maxWidth: 240)

                    Toggle("Beworben am", isOn: $hasAppliedDate)
                    DatePicker("Beworben am", selection: $appliedDate, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(!hasAppliedDate)
                    Spacer()
                }
                Text("Notizen").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    Spacer()
                    Button("Notizen & Datum speichern") { saveTracker(d) }
                        .disabled(!trackerDirty(d))
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
            .padding(4)
        } label: {
            Label("Tracker", systemImage: "checklist")
        }
    }

    private func scoreBox(_ d: JobDetail) -> some View {
        let bd = d.scoreBreakdown
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if bd.isExcluded {
                    Label("Ausgeschlossen wegen: \(bd.excluded.joined(separator: ", "))", systemImage: "nosign")
                        .foregroundStyle(.red)
                }
                ScoreBar(label: "Keywords", value: bd.keywords, max: ScoreBreakdown.maxKeywords,
                         detail: bd.matched.isEmpty ? nil : bd.matched.joined(separator: ", "))
                ScoreBar(label: "Titel", value: bd.title, max: ScoreBreakdown.maxTitle, detail: bd.titleMatch)
                ScoreBar(label: "Ort/Remote", value: bd.location, max: ScoreBreakdown.maxLocation, detail: bd.locationReason)
                ScoreBar(label: "Gehalt", value: bd.salary, max: ScoreBreakdown.maxSalary, detail: bd.salaryReason)
                if bd.penalty != 0 {
                    HStack {
                        Text("Abzug").frame(width: 90, alignment: .leading)
                        Text(bd.penalty, format: .number.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                        Text(bd.excludedInText.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Divider()
                HStack(spacing: 18) {
                    LabeledContent("Regel-Score", value: d.summary.ruleScore.map(String.init) ?? "–")
                    LabeledContent("LLM-Score", value: d.summary.llmScore.map(String.init) ?? "–")
                    LabeledContent("Gesamt", value: "\(d.summary.score)")
                }
                .font(.callout)
                .fixedSize()
            }
            .padding(4)
        } label: {
            Label("Score-Aufschlüsselung", systemImage: "chart.bar")
        }
    }

    private func letterBox(_ d: JobDetail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if !d.hasPostingText {
                    Label("Kein Anzeigentext – Anzeigentext einfügen, dann KI-Anschreiben.", systemImage: "doc.badge.plus")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if d.letterIsTemplate {
                    Label("Vorlage ohne KI (neutraler Text) – mit „Anschreiben mit KI schreiben“ ersetzen oder selbst anpassen.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                TextEditor(text: $letter)
                    .font(.body)
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                HStack {
                    if let origin = d.summary.letterOrigin {
                        Text(originLabel(origin)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if aiRunning || model.letterJobIDs.contains(jobID) {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        if letter != d.letter || (!d.letter.isEmpty && !d.letterIsTemplate) { confirmAI = true } else { Task { await writeWithAI() } }
                    } label: {
                        Label("Anschreiben mit KI schreiben", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiRunning || model.letterJobIDs.contains(jobID) || !d.hasPostingText)
                    .help("Schreibt mit opencode (\(model.settings.letterModel)) ein Anschreiben (3–4 Absätze) aus Profil + Anzeige und speichert es. Funktioniert auch offline (wird später synchronisiert).")
                    .confirmationDialog("Vorhandenes Anschreiben ersetzen?", isPresented: $confirmAI) {
                        Button("Mit KI neu schreiben", role: .destructive) { Task { await writeWithAI() } }
                    } message: {
                        Text("Der aktuelle Text wird durch ein neues KI-Anschreiben ersetzt.")
                    }
                    Button {
                        if letter != d.letter { confirmRegenerate = true } else { Task { await regenerate() } }
                    } label: {
                        Label(d.letter.isEmpty ? "Entwurf (Server)" : "Neu (Server)", systemImage: "wand.and.stars")
                    }
                    .disabled(!model.isOnline)
                    .help("Lässt den Server (LLM bzw. Vorlage) neu generieren – nur online")
                    .confirmationDialog("Ungespeicherte Änderungen verwerfen?", isPresented: $confirmRegenerate) {
                        Button("Verwerfen und neu generieren", role: .destructive) { Task { await regenerate() } }
                    } message: {
                        Text("Der bearbeitete Text wird durch einen neuen Entwurf ersetzt.")
                    }
                    Button {
                        copyToPasteboard(letter)
                        info = "Anschreiben in die Zwischenablage kopiert."
                    } label: {
                        Label("Kopieren", systemImage: "doc.on.doc")
                    }
                    .disabled(letter.isEmpty)
                    Button {
                        saveLetter()
                    } label: {
                        Label("Speichern", systemImage: "square.and.arrow.down")
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(letter == d.letter)
                }
                HStack {
                    Spacer()
                    if pdfRunning { ProgressView().controlSize(.small) }
                    Button {
                        Task { await exportPDF(preview: true) }
                    } label: {
                        Label("Vorschau", systemImage: "eye")
                    }
                    .disabled(letter.isEmpty || pdfRunning)
                    .help("Ganzes Anschreiben (Absender, Empfänger, Datum, Betreff, Anrede, Gruß) als PDF in Vorschau öffnen")
                    Button {
                        Task { await exportPDF(preview: false) }
                    } label: {
                        Label("Als PDF speichern", systemImage: "doc.richtext")
                    }
                    .disabled(letter.isEmpty || pdfRunning)
                    .help("Speichert das ganze Anschreiben als A4-PDF in \(model.settings.letterPDFFolder) und zeigt es im Finder – funktioniert offline")
                }
            }
            .padding(4)
        } label: {
            Label("Anschreiben-Entwurf", systemImage: "envelope.open")
        }
    }

    // MARK: Actions

    private func exportPDF(preview: Bool) async {
        pdfRunning = true
        defer { pdfRunning = false }
        do {
            if preview {
                try await model.previewLetterPDF(id: jobID, letter: letter)
            } else {
                let url = try await model.saveLetterPDF(id: jobID, letter: letter)
                info = "PDF gespeichert: \(url.path(percentEncoded: false))" + (letter != detail?.letter ? " (mit ungespeicherten Änderungen)" : "")
            }
        } catch {
            info = error.localizedDescription
        }
    }

    private func load() async {
        loadError = nil
        do {
            let d = try await model.loadDetail(id: jobID)
            apply(d)
        } catch {
            loadError = error.localizedDescription
        }
        await loadPreview()
    }

    private func apply(_ d: JobDetail) {
        detail = d
        letter = d.letter
        notes = d.notes
        if let date = ServerDate.parse(d.summary.appliedDate) {
            hasAppliedDate = true
            appliedDate = date
        } else {
            hasAppliedDate = false
            appliedDate = .now
        }
    }

    private func statusBinding(_ d: JobDetail) -> Binding<JobStatus> {
        Binding {
            detail?.summary.status ?? d.summary.status
        } set: { newValue in
            guard newValue != detail?.summary.status else { return }
            applyLocal(model.setStatus(id: jobID, newValue), "Status: \(newValue.label)" + (model.isOnline ? "" : " (offline gespeichert)"),
                       keepLetter: true, keepNotes: true)
        }
    }

    private func trackerDirty(_ d: JobDetail) -> Bool {
        if notes != d.notes { return true }
        let current = hasAppliedDate ? ServerDate.dayString(appliedDate) : nil
        return current != d.summary.appliedDate
    }

    private func saveTracker(_ d: JobDetail) {
        let date = hasAppliedDate ? ServerDate.dayString(appliedDate) : nil
        applyLocal(model.saveTracker(id: jobID, notes: notes, appliedDate: date), savedText("Gespeichert"),
                   keepLetter: true, keepNotes: false)
    }

    private func saveLetter() {
        applyLocal(model.saveLetter(id: jobID, text: letter), savedText("Anschreiben gespeichert"),
                   keepLetter: false, keepNotes: true)
        Task { await loadPreview() }
    }

    private func savedText(_ what: String) -> String {
        model.isOnline ? "\(what)." : "\(what) (offline – wird später synchronisiert)."
    }

    /// Applies a locally saved detail; unsaved edits in the *other* editors survive.
    private func applyLocal(_ d: JobDetail?, _ success: String, keepLetter: Bool = true, keepNotes: Bool = true) {
        actionError = nil
        let pendingLetter = keepLetter && letter != detail?.letter ? letter : nil
        let pendingNotes = keepNotes && notes != detail?.notes ? notes : nil
        if let d = d ?? model.cachedDetail(id: jobID) {
            apply(d)
        } else if var current = detail {
            // Detail never cached (should not happen once loaded): reflect the edit locally.
            current = model.localize(current)
            apply(current)
        }
        if let pendingLetter { letter = pendingLetter }
        if let pendingNotes { notes = pendingNotes }
        info = success
    }

    /// After a sync the model has fresh server data; take it over unless the user is editing.
    private func refreshFromModel() {
        guard let current = detail, let fresh = model.cachedDetail(id: jobID), fresh != current else { return }
        let dirtyLetter = letter != current.letter
        let dirtyNotes = notes != current.notes
        let keepLetter = letter, keepNotes = notes
        apply(fresh)
        if dirtyLetter { letter = keepLetter }
        if dirtyNotes { notes = keepNotes }
    }

    private func writeWithAI() async {
        aiRunning = true
        defer { aiRunning = false }
        actionError = nil
        info = "KI schreibt das Anschreiben (\(model.settings.letterModel)) …"
        do {
            let (d, secs) = try await model.writeLetterWithAI(id: jobID)
            let keepNotes = notes != detail?.notes ? notes : nil
            if let d { apply(d) } else if let c = model.cachedDetail(id: jobID) { apply(c) }
            if let keepNotes { notes = keepNotes }
            info = "KI-Anschreiben gespeichert (\(Int(secs.rounded())) s)" + (model.isOnline ? "." : " – offline, wird später synchronisiert.")
            await loadPreview()
        } catch {
            info = nil
            actionError = "KI-Anschreiben fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func regenerate() async {
        await perform("Entwurf neu erstellt.", keepLetter: false, keepNotes: true) {
            try await model.regenerateLetter(id: jobID)
        }
        await loadPreview()
    }

    /// Runs a server operation; unsaved edits in the *other* editors survive the refresh.
    private func perform(_ success: String, keepLetter: Bool, keepNotes: Bool,
                         _ op: () async throws -> JobDetail) async {
        busy = true
        defer { busy = false }
        actionError = nil
        info = nil
        let pendingLetter = keepLetter && letter != detail?.letter ? letter : nil
        let pendingNotes = keepNotes && notes != detail?.notes ? notes : nil
        do {
            apply(try await op())
            if let pendingLetter { letter = pendingLetter }
            if let pendingNotes { notes = pendingNotes }
            info = success
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func originLabel(_ origin: String) -> String {
        switch origin {
        case "vorlage": "Quelle: Vorlage"
        case "manuell": "Quelle: manuell bearbeitet"
        case LetterPrompt.originLabel: "Quelle: KI (opencode)"
        default: "Quelle: \(origin)"
        }
    }

    /// Alternative links (StepStone search, web search, careers page, original mail link).
    @ViewBuilder
    private func moreLinksMenu(_ s: JobSummary) -> some View {
        let links = JobLinks.alternatives(for: s)
        if !links.isEmpty {
            Menu {
                ForEach(links) { l in
                    Button { openURL(l.url) } label: { Label(l.title, systemImage: l.symbol) }
                }
            } label: {
                Label("Weitere Links", systemImage: "link")
            }
            .fixedSize()
            .help("Falls der Link nicht funktioniert: Stelle auf StepStone / im Web / auf der Karriereseite suchen")
        }
    }

}

private struct ScoreBar: View {
    let label: String
    let value: Double
    let max: Double
    let detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(label).frame(width: 90, alignment: .leading)
            ProgressView(value: min(Swift.max(value, 0), max), total: max)
                .frame(width: 160)
                .tint(value >= max * 0.75 ? .green : value > 0 ? .orange : .gray)
            Text("\(value, format: .number.precision(.fractionLength(0...1))) / \(Int(max))")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }
}

private struct MessageRow: View {
    let text: String
    let isError: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(8)
        .background((isError ? Color.red : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
