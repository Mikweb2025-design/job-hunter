import JobHunterCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    /// Always start with the sidebar visible (a collapsed sidebar left users with no navigation).
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var confirmBatch = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.sidebarSelection == .tracker {
                // Tracker: sidebar + full-width Kanban; the selected job opens in an inspector.
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
                } detail: {
                    TrackerView()
                        .safeAreaInset(edge: .top, spacing: 0) { banners }
                        .inspector(isPresented: Binding(get: { model.selectedJobID != nil },
                                                        set: { if !$0 { model.selectedJobID = nil } })) {
                            if let id = model.selectedJobID {
                                JobDetailView(jobID: id)
                                    .id(id)
                                    .inspectorColumnWidth(min: 380, ideal: 520, max: 760)
                            }
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
                } content: {
                    Group {
                        switch model.sidebarSelection ?? .today {
                        case .today: TodayView()
                        case .outbox: OutboxView()
                        case let item: JobListView(item: item)
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) { banners }
                    .navigationSplitViewColumnWidth(min: 380, ideal: 460, max: 640)
                } detail: {
                    if let id = model.selectedJobID {
                        JobDetailView(jobID: id)
                            .id(id)
                            .safeAreaInset(edge: .top, spacing: 0) { SendBanner(compact: true) }
                    } else {
                        ContentUnavailableView("Keine Stelle ausgewählt", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Wähle links eine Stelle aus."))
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .help("Daten neu laden und Änderungen synchronisieren (⌘R)")
                .disabled(model.isLoading)

                if model.isWritingBatch {
                    Button {
                        model.cancelLetterBatch()
                    } label: {
                        Label(batchLabel, systemImage: "stop.circle")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("KI-Anschreiben werden geschrieben – klicken zum Abbrechen")
                } else {
                    Button {
                        confirmBatch = true
                    } label: {
                        Label("Alle Vorlagen schreiben", systemImage: "wand.and.stars")
                    }
                    .help("Für alle offenen Stellen mit Vorlagen-Anschreiben ein KI-Anschreiben schreiben (opencode)")
                    .disabled(model.templateLetterJobs.isEmpty)
                }

                Button {
                    model.triggerRun()
                } label: {
                    if model.isRunActive {
                        Label("Suche läuft …", systemImage: "hourglass")
                    } else {
                        Label("Jetzt suchen", systemImage: "magnifyingglass.circle")
                    }
                }
                .labelStyle(.titleAndIcon)
                .help(model.isOnline ? "Einen Such- und Bewertungslauf auf dem Server starten (⇧⌘R)"
                                     : "Offline – der Suchlauf läuft auf dem Server")
                .disabled(model.isRunActive || model.client == nil || !model.isOnline)
            }
        }
        .modifier(TrackerSheets())
        .confirmationDialog("Alle Vorlagen mit KI schreiben?", isPresented: $confirmBatch, titleVisibility: .visible) {
            Button("\(model.templateLetterJobs.count) Anschreiben schreiben") { model.writeAllTemplateLetters() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("opencode (\(model.settings.letterModel)) schreibt nacheinander für \(model.templateLetterJobs.count) offene Stellen ein 4-Satz-Anschreiben und speichert es (offline: wartet auf Synchronisierung). Es wird nichts gesendet. Dauer ca. 20–60 s pro Stelle; jederzeit abbrechbar.")
        }
    }

    private var banners: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            SendBanner()
            StatusBanner()
        }
    }

    private var batchLabel: String {
        guard let j = model.letterJob else { return "KI schreibt …" }
        return "KI \(j.done)/\(j.total) – Stopp"
    }
}

/// "Offline – zeigt gespeicherte Daten von …" + pending changes. Shown above all lists.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isOffline || (model.connection == .notConfigured && model.dataDate != nil) {
            VStack(alignment: .leading, spacing: 3) {
                Label(headline, systemImage: "wifi.slash")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Button("Erneut versuchen") { Task { await model.refresh() } }
                        .controlSize(.small)
                        .disabled(model.isLoading)
                    if model.isLoading { ProgressView().controlSize(.mini) }
                }
                if model.pendingCount > 0 {
                    Label(pendingText(model.pendingCount), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                // No .fixedSize(vertical:) here: inside a safeAreaInset it made SwiftUI size the text at a
                // tiny width and grew the whole window content far beyond the window (offline bug).
                Text("Bearbeiten geht weiter (wird später übertragen). Offline wird nie gesendet.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.14))
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        } else if model.pendingCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                Text(pendingText(model.pendingCount)).font(.callout)
                Spacer()
                if model.isSyncing { ProgressView().controlSize(.small) }
                Button("Jetzt synchronisieren") { Task { await model.syncNow() } }
                    .controlSize(.small)
                    .disabled(model.isSyncing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.08))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var headline: String {
        if let date = model.dataDate {
            return "Offline – zeigt gespeicherte Daten von \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        return "Offline – noch keine gespeicherten Daten"
    }
}

/// Error / info banner (not configured, or transient messages).
struct StatusBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.connection == .notConfigured {
            HStack(spacing: 10) {
                Image(systemName: "gearshape").foregroundStyle(.orange)
                Text(model.errorMessage ?? "").font(.callout).lineLimit(3)
                Spacer()
                SettingsLink { Text("Einstellungen …") }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            .overlay(alignment: .bottom) { Divider() }
        } else if model.isOffline && model.dataDate == nil && model.allJobs.isEmpty {
            EmptyView()  // OfflineBanner already explains it
        } else if let msg = model.transientMessage {
            HStack(alignment: .top) {
                Image(systemName: model.isRunActive ? "hourglass" : "info.circle")
                    .foregroundStyle(.secondary)
                Text(msg).font(.callout).lineLimit(4).textSelection(.enabled)
                Spacer()
                Button {
                    model.transientMessage = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Ausblenden")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
