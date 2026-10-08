import JobHunterCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        List(selection: $model.sidebarSelection) {
            Section("Bewerben") {
                Label("Heute zu tun", systemImage: "checklist")
                    .badge(model.todayJobs.count)
                    .tag(SidebarItem.today)
                    .help("Die besten Stellen, bei denen du dich selbst über das Portal bewerben musst")
                Label("Neu (letzte \(AppModel.recentDays) Tage)", systemImage: "sparkles")
                    .badge(model.recentJobs.count)
                    .tag(SidebarItem.recent)
                    .help("Neu gefundene und aus Job-Alerts (LinkedIn, StepStone, Indeed) importierte Stellen – neueste zuerst")
                bewerbenRows
            }

            Section("Ansicht") {
                Label("Alle Stellen", systemImage: "briefcase")
                    .badge(model.jobs.count)
                    .tag(SidebarItem.jobs)
                Label("Tracker", systemImage: "chart.bar.xaxis")
                    .badge(trackedCount)
                    .tag(SidebarItem.tracker)
                Label("Postausgang", systemImage: "paperplane")
                    .badge(model.sendSettings?.sentToday ?? 0)
                    .tag(SidebarItem.outbox)
                    .help("Gesendete, wartende und fehlgeschlagene Bewerbungen (Badge: heute gesendet)")
                Button {
                    openWindow(id: "searchProfile")
                } label: {
                    Label("Suchprofil & Profil …", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help("Suchbegriffe, Ort, Quellen, Bewertung und CV-Profil ändern (⇧⌘P) – nur online")
            }

            Section("Filter") {
                Picker("Status", selection: statusBinding) {
                    Text("Alle").tag(StatusChoice.all)
                    Text("Aktiv (ohne Absagen)").tag(StatusChoice.active)
                    Divider()
                    ForEach(JobStatus.allCases) { s in
                        Label(s.label, systemImage: s.symbolName).tag(StatusChoice.only(s))
                    }
                }
                .help("Gilt für „Alle Stellen“; die Bewerben-Listen nutzen die übrigen Filter")

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Min. Score")
                        Spacer()
                        Text(model.filter.minScore == 0 ? "–" : "≥ \(model.filter.minScore)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: minScoreBinding, in: 0...100, step: 5)
                        .controlSize(.small)
                        .accessibilityLabel("Mindest-Score")
                }

                Picker("Quelle", selection: $model.filter.source) {
                    Text("Alle").tag(String?.none)
                    ForEach(model.sources, id: \.self) { src in
                        Text(sourceLabel(src)).tag(String?.some(src))
                    }
                }

                Picker("Neu seit", selection: $model.filter.sinceDays) {
                    Text("Beliebig").tag(Int?.none)
                    Text("letzte 24 h").tag(Int?.some(1))
                    Text("letzte 3 Tage").tag(Int?.some(3))
                    Text("letzte 7 Tage").tag(Int?.some(7))
                    Text("letzte 30 Tage").tag(Int?.some(30))
                }

                if model.filter != JobFilter() {
                    Button("Filter zurücksetzen") { model.filter = JobFilter() }
                        .buttonStyle(.link)
                }
            }

            Section("Server") {
                SyncStatusView()
                if let stats = model.stats {
                    LabeledContent("Stellen gesamt", value: "\(stats.total)")
                    LabeledContent("Neu im letzten Lauf", value: "\(stats.newSinceLastRun)")
                }
            }
            .font(.callout)
        }
        .listStyle(.sidebar)
        .navigationTitle("JobHunter")
    }

    /// "Bewerben" rows: dynamic from `GET /api/v1/views` when the server knows
    /// `far` (newest servers), otherwise the static four. The far row never has
    /// any send affordance (neither here nor in its list/detail).
    @ViewBuilder
    private var bewerbenRows: some View {
        if let views = model.serverViews, views.order.contains("far") {
            ForEach(views.order, id: \.self) { key in
                switch key {
                case "auto":
                    categoryRow(.automatic, title: views.labels["auto"],
                                help: "Hat eine Bewerbungs-Adresse – die App kann per E-Mail senden (Server-Regeln)")
                case "manual":
                    categoryRow(.manual, title: views.labels["manual"],
                                help: "Keine E-Mail-Adresse – hier musst DU dich über das Portal bewerben")
                case "applied":
                    categoryRow(.applied, title: views.labels["applied"],
                                help: "Beworben, Gespräch, Angebot oder E-Mail gesendet")
                case "later":
                    categoryRow(.later, title: views.labels["later"],
                                help: "Abgesagt / zurückgestellt")
                case "far":
                    Label(views.labels["far"] ?? "Zu weit", systemImage: "mappin.slash")
                        .badge(model.farJobs.count)
                        .tag(SidebarItem.far)
                        .help("Zu weit entfernt – weder E-Mail noch Portal")
                default:
                    EmptyView()  // today (own row above) and unknown future views
                }
            }
        } else {
            categoryRow(.automatic, help: "Hat eine Bewerbungs-Adresse – die App kann per E-Mail senden (Server-Regeln)")
            categoryRow(.manual, help: "Keine E-Mail-Adresse – hier musst DU dich über das Portal bewerben")
            categoryRow(.applied, help: "Beworben, Gespräch, Angebot oder E-Mail gesendet")
            categoryRow(.later, help: "Abgesagt / zurückgestellt")
        }
    }

    private func categoryRow(_ c: ApplyCategory, title: String? = nil, help: String) -> some View {
        Text(title ?? c.title)
            .fontWeight(c == .manual && model.count(.manual) > 0 ? .semibold : .regular)
            .badge(model.count(c))
            .tag(SidebarItem(rawValue: c.rawValue)!)
            .help(help)
    }

    private var trackedCount: Int {
        model.allJobs.filter { $0.status != .neu }.count
    }

    private enum StatusChoice: Hashable { case all, active, only(JobStatus) }

    private var statusBinding: Binding<StatusChoice> {
        Binding {
            switch model.filter.status {
            case .all: .all
            case .active: .active
            case .only(let s): .only(s)
            }
        } set: { choice in
            switch choice {
            case .all: model.filter.status = .all
            case .active: model.filter.status = .active
            case .only(let s): model.filter.status = .only(s)
            }
        }
    }

    private var minScoreBinding: Binding<Double> {
        Binding { Double(model.filter.minScore) } set: { model.filter.minScore = Int($0) }
    }
}

/// Online/offline + pending-changes state with a sync button.
struct SyncStatusView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(stateText).fontWeight(.medium)
                if model.isLoading || model.isSyncing { ProgressView().controlSize(.mini) }
            }
            if let date = model.dataDate {
                Text("Daten von \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.pendingCount > 0 {
                Label(pendingText(model.pendingCount), systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.orange)
                Button("Jetzt synchronisieren") { Task { await model.syncNow() } }
                    .controlSize(.small)
                    .disabled(model.isSyncing || model.client == nil)
            }
        }
    }

    private var dotColor: Color {
        switch model.connection {
        case .ok: .green
        case .failed: .orange
        case .notConfigured: .gray
        case .unknown: .gray
        }
    }

    private var stateText: String {
        switch model.connection {
        case .ok: "Online"
        case .failed: "Offline"
        case .notConfigured: "Nicht konfiguriert"
        case .unknown: "Verbinde …"
        }
    }
}

func pendingText(_ n: Int) -> String {
    n == 1 ? "1 Änderung wartet auf Synchronisierung" : "\(n) Änderungen warten auf Synchronisierung"
}

func sourceLabel(_ source: String) -> String {
    switch source {
    case "arbeitsagentur": return "Arbeitsagentur"
    case "adzuna": return "Adzuna"
    case "rss": return "RSS"
    case "arbeitnow": return "Arbeitnow"
    case "remotive": return "Remotive"
    case "jobicy": return "Jobicy"
    case "berlinstartupjobs": return "Berlin Startup Jobs"
    case "greenhouse": return "Karriereseite (Greenhouse)"
    case "lever": return "Karriereseite (Lever)"
    case "personio": return "Karriereseite (Personio)"
    case "smartrecruiters": return "Karriereseite (SmartRecruiters)"
    default:
        if let alert = AlertSource(rawValue: source) { return alert.label }
        return source.prefix(1).uppercased() + source.dropFirst()
    }
}
