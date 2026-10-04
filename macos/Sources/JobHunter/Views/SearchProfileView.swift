import JobHunterCore
import SwiftUI

/// Editable copy of one source's settings.
struct SourceDraft: Equatable {
    var enabled: Bool
    var options: SourceOptions
}

/// State of the "Suchprofil & Profil" window. Online only: everything goes straight to the
/// server (no offline queue); offline the window says so and offers "Erneut versuchen".
@MainActor
@Observable
final class SearchProfileModel {
    private(set) var payload: SearchProfilePayload?
    var draft = SearchProfileData()
    var sources: [String: SourceDraft] = [:]
    private(set) var changedSources: Set<String> = []
    private(set) var preview: SearchPreview?
    private(set) var suggestions: ProfileSuggestions?
    private(set) var cv: CVProfileData?
    var cvDraft = ""

    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var isPreviewing = false
    private(set) var isSavingCV = false
    var message: String?
    var error: String?
    private(set) var loadError: String?
    private(set) var offline = false

    var isDirty: Bool {
        guard let payload else { return false }
        return draft != payload.profile || !changedSources.isEmpty
    }

    var cvDirty: Bool { cv.map { $0.text != cvDraft } ?? false }

    func load(_ client: APIClient?) async {
        guard let client else { loadError = APIError.notConfigured.errorDescription; return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let p = client.searchProfile()
            async let c = client.cvProfile()
            let (payload, cv) = try await (p, c)
            apply(payload)
            self.cv = cv
            cvDraft = cv.text
            loadError = nil
            offline = false
            await loadSuggestions(client)
        } catch let e as APIError where e == .notFound {
            loadError = "Der Server kennt das Suchprofil noch nicht (404) – bitte das Backend aktualisieren (Deploy)."
        } catch let e as APIError where e.isConnectivityProblem {
            offline = true
            loadError = e.errorDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(_ p: SearchProfilePayload) {
        payload = p
        draft = p.profile
        sources = Dictionary(uniqueKeysWithValues: p.sources.map { ($0.id, SourceDraft(enabled: $0.enabled, options: $0.options)) })
        changedSources = []
    }

    func loadSuggestions(_ client: APIClient?) async {
        guard let client else { return }
        suggestions = try? await client.profileSuggestions()
    }

    func sourceBinding(_ id: String) -> Binding<SourceDraft> {
        Binding { [self] in sources[id] ?? SourceDraft(enabled: false, options: SourceOptions()) }
            set: { [self] in sources[id] = $0; changedSources.insert(id) }
    }

    private var update: SearchProfileUpdate {
        SearchProfileUpdate(profile: draft,
                            sources: Dictionary(uniqueKeysWithValues: changedSources.compactMap { id in
                                sources[id].map { (id, SearchProfileUpdate.SourceChange(enabled: $0.enabled, options: $0.options)) }
                            }))
    }

    /// Saves; the server re-scores all jobs in the background. Returns true on success.
    func save(_ client: APIClient?) async -> Bool {
        guard let client else { return false }
        let problems = draft.validationErrors()
        guard problems.isEmpty else { error = problems.joined(separator: " "); return false }
        isSaving = true
        defer { isSaving = false }
        do {
            var u = update
            u.rescore = true
            let p = try await client.saveSearchProfile(u)
            apply(p)
            error = nil
            message = "Gespeichert." + (p.rescoreStarted == true ? " Alle Stellen werden neu bewertet." : "")
            await loadSuggestions(client)
            return true
        } catch {
            self.error = "Nicht gespeichert: " + error.localizedDescription
            return false
        }
    }

    func reset(_ client: APIClient?) async {
        guard let client else { return }
        do {
            apply(try await client.resetSearchProfile())
            message = "Auf config.yaml zurückgesetzt."
            error = nil
            await loadSuggestions(client)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runPreview(_ client: APIClient?) async {
        guard let client else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        do {
            preview = try await client.previewSearchProfile(update)
            error = nil
        } catch {
            self.error = "Vorschau nicht möglich: " + error.localizedDescription
        }
    }

    func saveCV(_ client: APIClient?) async {
        guard let client else { return }
        isSavingCV = true
        defer { isSavingCV = false }
        do {
            let c = try await client.saveCVProfile(text: cvDraft)
            cv = c
            cvDraft = c.text
            error = nil
            message = "CV-Profil gespeichert" + (c.backup.map { " (alte Version: \($0))" } ?? "") + ". Stellen werden neu bewertet."
            await loadSuggestions(client)
        } catch {
            self.error = "CV-Profil nicht gespeichert: " + error.localizedDescription
        }
    }

    func addSuggestion(_ s: ProfileSuggestion) {
        if s.kind == "title" { addUnique(s.value, to: &draft.targetTitles) } else { addUnique(s.value, to: &draft.queries) }
    }

    func isAdded(_ s: ProfileSuggestion) -> Bool {
        let list = s.kind == "title" ? draft.targetTitles : draft.queries
        return list.contains { $0.caseInsensitiveCompare(s.value) == .orderedSame }
    }
}

struct SearchProfileView: View {
    @Environment(AppModel.self) private var app
    @State private var model = SearchProfileModel()
    @State private var tab = Tab.search
    @State private var confirmReset = false
    @State private var confirmCV = false

    enum Tab: Hashable { case search, sources, scoring, cv }

    /// Longer timeout: the preview runs up to ~60 searches on the server.
    private var client: APIClient? { app.settings.serverConfig.map { APIClient(config: $0, timeout: 120) } }

    var body: some View {
        Group {
            if model.payload == nil {
                placeholder
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        banners
                        TabView(selection: $tab) {
                            SearchTab(model: model).tabItem { Text("Suche") }.tag(Tab.search)
                            SourcesTab(model: model).tabItem { Text("Quellen") }.tag(Tab.sources)
                            ScoringTab(model: model).tabItem { Text("Bewertung") }.tag(Tab.scoring)
                            cvTab.tabItem { Text("CV-Profil") }.tag(Tab.cv)
                        }
                        .padding([.horizontal, .top], 8)
                        if tab != .cv { saveBar }
                    }
                    .frame(minWidth: 520, idealWidth: 620)

                    SidePanel(model: model, client: client)
                        .frame(minWidth: 300, idealWidth: 380)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .task { await model.load(client) }
        .confirmationDialog("Suchprofil und Quellen auf config.yaml zurücksetzen?", isPresented: $confirmReset) {
            Button("Zurücksetzen", role: .destructive) { Task { await model.reset(client) } }
        } message: {
            Text("Alle in der App/im Dashboard geänderten Werte werden verworfen.")
        }
        .confirmationDialog("CV-Profil speichern?", isPresented: $confirmCV) {
            Button("Speichern") { Task { await model.saveCV(client) } }
        } message: {
            Text("Nur wahre Angaben – die KI schreibt die Anschreiben aus diesem Profil. Die alte Version wird auf dem Server gesichert.")
        }
    }

    @ViewBuilder private var placeholder: some View {
        if model.isLoading {
            ProgressView("Lade Suchprofil …").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(model.offline ? "Nur online verfügbar" : "Suchprofil nicht verfügbar",
                      systemImage: model.offline ? "wifi.slash" : "exclamationmark.triangle")
            } description: {
                Text(model.offline
                     ? "Das Suchprofil liegt auf dem Server und kann nur mit Verbindung geändert werden (keine Warteschlange).\n\(model.loadError ?? "")"
                     : (model.loadError ?? ""))
            } actions: {
                Button("Erneut versuchen") { Task { await model.load(client) } }
            }
        }
    }

    @ViewBuilder private var banners: some View {
        if let e = model.error {
            banner(e, systemImage: "exclamationmark.triangle.fill", color: .orange) { model.error = nil }
        } else if let m = model.message {
            banner(m, systemImage: "checkmark.circle.fill", color: .green) { model.message = nil }
        }
        if let p = model.payload, !p.overridden.isEmpty {
            Text("Geändert gegenüber config.yaml: " + p.overridden.map(fieldLabel).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 6)
        }
    }

    private func banner(_ text: String, systemImage: String, color: Color, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Ausblenden")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(color.opacity(0.12))
    }

    private var saveBar: some View {
        HStack {
            Button("Speichern") { Task { _ = await model.save(client) } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Speichern + Jetzt suchen") {
                Task { if await model.save(client) { app.triggerRun() } }
            }
            .help("Speichern, dann sofort einen Suchlauf auf dem Server starten")
            .disabled(app.isRunActive)
            if model.isSaving { ProgressView().controlSize(.small) }
            if model.isDirty {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
                    .help("Ungespeicherte Änderungen").accessibilityLabel("Ungespeicherte Änderungen")
            }
            Spacer(minLength: 8)
            Button("Zurücksetzen …") { confirmReset = true }
                .help("Suchprofil und Quellen auf die Werte aus config.yaml zurücksetzen")
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isSaving)
        .padding(10)
        .background(.bar)
    }

    private var cvTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.cv?.warning ?? "Nur wahre Angaben eintragen.", systemImage: "exclamationmark.shield")
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            if let cv = model.cv {
                Text("\(cv.keywords) Keywords · \(cv.results) Kernergebnisse"
                     + (cv.backups.first.map { " · neueste Sicherung: \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $model.cvDraft)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.3))
                .accessibilityLabel("CV-Profil (Markdown)")
            HStack {
                Button("CV-Profil speichern") { confirmCV = true }
                    .disabled(!model.cvDirty || model.isSavingCV || model.cvDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.isSavingCV { ProgressView().controlSize(.small) }
                Button("Änderungen verwerfen") { model.cvDraft = model.cv?.text ?? "" }
                    .disabled(!model.cvDirty)
                Spacer()
                Text("Alte Version wird als data/cv_profile.backup-….md gesichert.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}

func fieldLabel(_ f: String) -> String {
    [
        "queries": "Suchbegriffe", "location": "Ort", "radius_km": "Umkreis", "remote_ok": "Remote",
        "days_back": "Zeitraum", "min_salary": "Mindestgehalt", "target_titles": "Zieltitel",
        "excluded_title_keywords": "Ausschluss im Titel", "excluded_keywords": "Ausschluss-Wörter",
        "keyword_weights": "Keyword-Gewichte", "keyword_saturation": "Sättigung", "extra_locations": "weitere Orte",
    ][f] ?? f
}

// MARK: - Tabs

private struct SearchTab: View {
    @Bindable var model: SearchProfileModel

    var body: some View {
        Form {
            Section {
                TokenListEditor(items: $model.draft.queries, placeholder: "Suchbegriff hinzufügen",
                                limit: SearchProfileData.maxQueries)
            } header: {
                Text("Suchbegriffe (\(model.draft.queries.count)/\(SearchProfileData.maxQueries))")
            } footer: {
                Text("Je Begriff eine Suche bei der Arbeitsagentur (Ort + bundesweit Homeoffice); Feeds werden nach diesen Begriffen und den Zieltiteln gefiltert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ort") {
                TextField("Ort", text: $model.draft.location)
                LabeledContent("Umkreis") {
                    HStack {
                        Slider(value: Binding(get: { Double(model.draft.radiusKm) }, set: { model.draft.radiusKm = Int($0) }),
                               in: 0...200, step: 5)
                            .accessibilityLabel("Umkreis in km")
                        Text("\(model.draft.radiusKm) km").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
                Toggle("Remote/Homeoffice deutschlandweit", isOn: $model.draft.remoteOk)
                LabeledContent("Weitere Orte") {
                    TokenListEditor(items: $model.draft.extraLocations, placeholder: "Ort hinzufügen", limit: 10)
                }
            }
            Section("Filter") {
                Stepper(value: $model.draft.daysBack, in: 1...100) {
                    LabeledContent("Anzeigen der letzten", value: "\(model.draft.daysBack) Tage")
                }
                Stepper(value: $model.draft.minSalary, in: 0...300_000, step: 1000) {
                    LabeledContent("Mindestgehalt", value: "\(model.draft.minSalary.formatted()) € / Jahr")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ScoringTab: View {
    @Bindable var model: SearchProfileModel
    @State private var newKeyword = ""
    @State private var newWeight = 1.0

    var body: some View {
        Form {
            Section {
                TokenListEditor(items: $model.draft.targetTitles, placeholder: "Zieltitel hinzufügen", limit: 60)
            } header: { Text("Zieltitel") } footer: {
                Text("Volle Titelpunkte (25), wenn der Stellentitel einen Zieltitel enthält.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TokenListEditor(items: $model.draft.excludedTitleKeywords, placeholder: "Wort hinzufügen", limit: 100)
            } header: { Text("Ausschluss im Titel (→ Score 0)") }
            Section {
                TokenListEditor(items: $model.draft.excludedKeywords, placeholder: "Wort hinzufügen", limit: 100)
            } header: { Text("Ausschluss-Wörter (im Text −10, im Titel Score 0)") }
            Section {
                ForEach(model.draft.keywordWeights.keys.sorted(), id: \.self) { kw in
                    HStack {
                        Text(kw)
                        Spacer()
                        Text(model.draft.keywordWeights[kw].map { $0.formatted() } ?? "").monospacedDigit()
                        Stepper("Gewicht \(kw)", value: weight(kw), in: 0...10, step: 0.5).labelsHidden()
                        Button { model.draft.keywordWeights[kw] = nil } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("\(kw) entfernen")
                    }
                }
                HStack {
                    TextField("Neues Keyword", text: $newKeyword).onSubmit(addKeyword)
                    Text(newWeight.formatted()).monospacedDigit()
                    Stepper("Gewicht", value: $newWeight, in: 0...10, step: 0.5).labelsHidden()
                    Button("Hinzufügen", action: addKeyword).disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Stepper(value: $model.draft.keywordSaturation, in: 1...100, step: 1) {
                    LabeledContent("Sättigung (Summe für volle 40 Punkte)", value: model.draft.keywordSaturation.formatted())
                }
            } header: { Text("Keyword-Gewichte") } footer: {
                Text("Ergänzen/überschreiben die Keywords aus dem CV-Profil (0–10).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func weight(_ kw: String) -> Binding<Double> {
        Binding { model.draft.keywordWeights[kw] ?? 0 } set: { model.draft.keywordWeights[kw] = $0 }
    }

    private func addKeyword() {
        let k = newKeyword.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !k.isEmpty else { return }
        model.draft.keywordWeights[k] = newWeight
        newKeyword = ""
    }
}

private struct SourcesTab: View {
    @Bindable var model: SearchProfileModel

    var body: some View {
        Form {
            Section {
                Text("Nur offizielle/öffentliche Schnittstellen und Feeds – keine Bots auf Jobbörsen. LinkedIn, StepStone und Indeed kommen über die Job-Alert-Mails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.payload?.sources ?? []) { src in
                Section { SourceEditor(source: src, draft: model.sourceBinding(src.id), payload: model.payload) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SourceEditor: View {
    let source: SourceSetting
    @Binding var draft: SourceDraft
    let payload: SearchProfilePayload?
    @State private var newATS = "greenhouse"
    @State private var newToken = ""
    @State private var newName = ""
    @State private var newFeed = ""

    var body: some View {
        Toggle(isOn: $draft.enabled) {
            HStack {
                Text(source.label).fontWeight(.medium)
                Text(source.kind).font(.caption).padding(.horizontal, 5).background(.quaternary, in: Capsule())
            }
            Text(source.info).font(.caption).foregroundStyle(.secondary)
        }
        if let urlString = source.url, let url = URL(string: urlString) {
            Link("Info ↗", destination: url).font(.caption)
        }
        if draft.enabled && !source.configured, let reason = source.reason {
            Label("Nicht aktiv: \(reason)", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        }
        if draft.enabled {
            if let range = source.intRange("max_pages") {
                Stepper(value: Binding(get: { draft.options.maxPages ?? range.lowerBound },
                                       set: { draft.options.maxPages = $0 }), in: range) {
                    LabeledContent("Seiten pro Abruf", value: "\(draft.options.maxPages ?? range.lowerBound)")
                }
            }
            if source.hasOption("remote_search") {
                Toggle("Zusätzlich bundesweit Homeoffice", isOn: Binding(get: { draft.options.remoteSearch ?? true },
                                                                          set: { draft.options.remoteSearch = $0 }))
            }
            if !source.choices("category").isEmpty {
                Picker("Kategorie", selection: Binding(get: { draft.options.category ?? "" }, set: { draft.options.category = $0 })) {
                    ForEach(source.choices("category"), id: \.self) { Text($0.isEmpty ? "alle" : $0).tag($0) }
                }
            }
            if !source.choices("geo").isEmpty {
                Picker("Region", selection: Binding(get: { draft.options.geo ?? "germany" }, set: { draft.options.geo = $0 })) {
                    ForEach(source.choices("geo"), id: \.self) { Text($0).tag($0) }
                }
            }
            if source.hasOption("companies") { companies }
            if source.hasOption("feeds") { feeds }
        }
    }

    @ViewBuilder private var companies: some View {
        let types = payload?.atsTypes ?? [:]
        ForEach(draft.options.companies ?? []) { c in
            HStack {
                Text(c.name)
                Text("\(types[c.ats] ?? c.ats): \(c.token)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { draft.options.companies?.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("\(c.name) entfernen")
            }
        }
        HStack {
            Picker("System", selection: $newATS) {
                ForEach(types.keys.sorted(), id: \.self) { Text(types[$0] ?? $0).tag($0) }
            }
            .labelsHidden().frame(width: 150)
            TextField("Kürzel (z. B. sumup)", text: $newToken)
            TextField("Name (optional)", text: $newName)
            Button("Firma hinzufügen") {
                add(ATSCompany(ats: newATS, token: newToken.trimmingCharacters(in: .whitespaces), name: newName))
                newToken = ""; newName = ""
            }
            .disabled(newToken.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let examples = payload?.atsExamples, !examples.isEmpty {
            HStack {
                Text("Geprüfte Beispiele:").font(.caption).foregroundStyle(.secondary)
                ForEach(examples) { ex in
                    Button("+ \(ex.name)") { add(ex) }
                        .controlSize(.small)
                        .disabled((draft.options.companies ?? []).contains { $0.id == ex.id })
                }
            }
        }
    }

    private func add(_ c: ATSCompany) {
        var list = draft.options.companies ?? []
        guard !c.token.isEmpty, !list.contains(where: { $0.id == c.id }) else { return }
        list.append(c)
        draft.options.companies = list
    }

    @ViewBuilder private var feeds: some View {
        ForEach(draft.options.feeds ?? [], id: \.url) { f in
            HStack {
                Text(f.url).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { draft.options.feeds?.removeAll { $0.url == f.url } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        HStack {
            TextField("https://…/feed", text: $newFeed)
            Button("Feed hinzufügen") {
                let u = newFeed.trimmingCharacters(in: .whitespaces)
                guard !u.isEmpty else { return }
                draft.options.feeds = (draft.options.feeds ?? []) + [FeedEntry(url: u)]
                newFeed = ""
            }
        }
    }
}

// MARK: - Preview + suggestions

private struct SidePanel: View {
    @Bindable var model: SearchProfileModel
    let client: APIClient?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("Vorschau") { Task { await model.runPreview(client) } }
                                .disabled(model.isPreviewing || !model.draft.validationErrors().isEmpty)
                            if model.isPreviewing { ProgressView().controlSize(.small); Text("Suche läuft …").font(.caption) }
                        }
                        Text("Sucht jetzt mit den Werten im Formular – ohne zu speichern. 10 Minuten zwischengespeichert.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let p = model.preview { PreviewTable(preview: p) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("Vorschau", systemImage: "eye") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Aus deinem CV-Profil und den Stellen, die du als interessant/beworben markiert hast. „+“ übernimmt, dann speichern.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let s = model.suggestions {
                            suggestionList("Suchbegriffe", s.queries.prefix(12))
                            suggestionList("Zieltitel", s.titles.prefix(8))
                            if s.queries.isEmpty && s.titles.isEmpty { Text("Keine neuen Vorschläge.").foregroundStyle(.secondary) }
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("Vorschläge", systemImage: "lightbulb") }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private func suggestionList(_ title: String, _ items: ArraySlice<ProfileSuggestion>) -> some View {
        if !items.isEmpty {
            Text(title).font(.subheadline.weight(.semibold)).padding(.top, 4)
            ForEach(Array(items)) { s in
                HStack(alignment: .top, spacing: 6) {
                    Button { model.addSuggestion(s) } label: {
                        Image(systemName: model.isAdded(s) ? "checkmark.circle.fill" : "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isAdded(s))
                    .help(model.isAdded(s) ? "Übernommen" : "„\(s.value)“ übernehmen")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.value)
                        Text(s.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct PreviewTable: View {
    let preview: SearchPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Suchbegriff").bold()
                    Text("BA Ort").bold().help("Arbeitsagentur: Ort + Umkreis, Treffer gesamt")
                    Text("BA Remote").bold().help("Arbeitsagentur: Homeoffice unter den ersten 100 bundesweiten Treffern")
                    Text("Feeds").bold().help("Treffer in den aktivierten Feeds/Karriereseiten")
                }
                .font(.caption)
                Divider()
                ForEach(preview.queries) { q in
                    GridRow(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(q.query).fontWeight(.medium)
                            if let e = q.error { Text(e).font(.caption2).foregroundStyle(.orange) }
                            ForEach(q.samples ?? [], id: \.self) { s in
                                Text("· \(s.title)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if let ba = q.arbeitsagentur {
                                Text("neu auf Seite 1: \(ba.newInPage)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(q.arbeitsagentur.map { "\($0.local)" } ?? "–").monospacedDigit()
                        Text(q.arbeitsagentur.map { "\($0.remote)" } ?? "–").monospacedDigit()
                        Text("\(q.feeds.values.reduce(0, +))").monospacedDigit()
                    }
                }
            }
            if !preview.sources.isEmpty {
                Divider()
                ForEach(preview.sources) { s in
                    if let e = s.error {
                        Text("\(s.label): \(e)").font(.caption).foregroundStyle(.orange)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.label): \(s.matching ?? 0) passend von \(s.fetched ?? 0) (neu: \(s.new ?? 0))").font(.caption)
                            if let samples = s.samples, !samples.isEmpty {
                                Text(samples.map(\.title).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            Text(preview.cached ? "aus dem Zwischenspeicher" : "frisch abgerufen").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Token list ("Chips")

/// Editable list of short strings shown as removable chips; Enter adds the typed value.
struct TokenListEditor: View {
    @Binding var items: [String]
    var placeholder: String
    var limit: Int = 100
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 3) {
                        Text(item)
                        Button { items.removeAll { $0 == item } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(item) entfernen")
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
            TextField(placeholder, text: $input)
                .onSubmit(add)
                .disabled(items.count >= limit)
        }
    }

    private func add() {
        for part in input.split(separator: ",") { addUnique(String(part), to: &items) }
        input = ""
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: subviews.isEmpty ? 0 : y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
