import Charts
import JobHunterCore
import SwiftUI

/// Application tracker: Kanban with all 7 statuses (drag & drop, context menu, ⌥⌘1…7),
/// KPIs/funnel, charts per week and per source, follow-ups ("Nachfassen") and upcoming interviews.
/// Works offline on the cached jobs; changes go through the offline edit queue.
struct TrackerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("trackerShowClosed") private var showClosed = true
    @AppStorage("trackerShowNew") private var showNew = true
    /// Cards shown per column before "weitere …" (neu/zu_weit can have hundreds).
    private let perColumn = 40

    var body: some View {
        let jobs = model.trackerJobs
        let metrics = Tracker.metrics(jobs, sourceLabel: sourceLabel)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                kpis(metrics)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    weeklyChart(metrics)
                    sourceChart(metrics)
                    funnel(metrics)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)],
                          alignment: .leading, spacing: 12) {
                    followUps(Tracker.followUps(jobs))
                    interviews(Tracker.upcomingInterviews(jobs))
                }
                kanbanHeader
                kanban(jobs)
                lastRun
            }
            .padding(16)
        }
        .navigationTitle("Tracker")
        .navigationSubtitle(subtitle(metrics))
        .searchable(text: Bindable(model).filter.query, placement: .toolbar, prompt: "Titel, Firma, Text")
        .overlay {
            if model.allJobs.isEmpty {
                if model.isLoading { ProgressView("Lade Stellen …") } else {
                    ContentUnavailableView("Noch keine Daten", systemImage: "chart.bar.xaxis",
                                           description: Text(model.errorMessage ?? "Aktualisieren (⌘R), sobald der Server erreichbar ist."))
                }
            }
        }
    }

    private func subtitle(_ m: Tracker.Metrics) -> String {
        "\(m.applied) Bewerbungen · \(m.responses) Antworten" + (m.responseRate.map { " (\($0) %)" } ?? "")
    }

    // MARK: KPIs

    private func kpis(_ m: Tracker.Metrics) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 10)], spacing: 10) {
            Tile(title: "Bewerbungen", value: "\(m.applied)", symbol: "paperplane", tint: .teal)
            Tile(title: "Diese Woche", value: "\(m.thisWeek)", symbol: "calendar", tint: .blue)
            Tile(title: "✉ E-Mail / 🖐 manuell", value: "\(m.byEmail) / \(m.manual)", symbol: "envelope", tint: .indigo)
            Tile(title: "Antwortquote", value: m.responseRate.map { "\($0) %" } ?? "–", symbol: "bubble.left.and.bubble.right", tint: .purple,
                 help: "(Gespräch + Angebot + Absage der Firma) / Bewerbungen – Duplikate und „Kein Interesse“ zählen nicht")
            Tile(title: "Gespräche", value: "\(m.interviews)", symbol: JobStatus.gespraech.symbolName, tint: .orange)
            Tile(title: "Angebote", value: "\(m.offers)", symbol: JobStatus.angebot.symbolName, tint: .green)
            Tile(title: "Ø Tage bis Antwort", value: m.avgDaysToAnswer.map { String(format: "%.1f", $0) } ?? "–",
                 symbol: "hourglass", tint: .brown)
            Tile(title: "Warten auf Antwort", value: "\(m.waiting)", symbol: "clock", tint: .gray)
        }
    }

    // MARK: Charts

    private func weeklyChart(_ m: Tracker.Metrics) -> some View {
        GroupBox("Pro Woche (12 Wochen)") {
            Chart {
                ForEach(m.weeks) { w in
                    BarMark(x: .value("Woche", w.label), y: .value("Anzahl", w.applications))
                        .foregroundStyle(by: .value("Art", "Bewerbungen"))
                        .position(by: .value("Art", "Bewerbungen"))
                        .cornerRadius(3)
                    BarMark(x: .value("Woche", w.label), y: .value("Anzahl", w.responses))
                        .foregroundStyle(by: .value("Art", "Antworten"))
                        .position(by: .value("Art", "Antworten"))
                        .cornerRadius(3)
                }
            }
            .chartForegroundStyleScale(["Bewerbungen": Color.accentColor, "Antworten": Color.green])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis {
                AxisMarks { v in
                    AxisValueLabel { if let s = v.as(String.self) { Text(s.replacingOccurrences(of: "KW ", with: "")).font(.caption2) } }
                }
            }
            .frame(height: 150)
        }
        .frame(maxWidth: .infinity)
    }

    private func sourceChart(_ m: Tracker.Metrics) -> some View {
        GroupBox("Bewerbungen nach Quelle") {
            if m.bySource.isEmpty {
                Text("Noch keine Bewerbung.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                Chart(m.bySource.prefix(6)) { s in
                    BarMark(x: .value("Bewerbungen", s.applications), y: .value("Quelle", s.label))
                        .foregroundStyle(Color.accentColor)
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(s.responses > 0 ? "\(s.applications) (\(s.responses) Antw.)" : "\(s.applications)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func funnel(_ m: Tracker.Metrics) -> some View {
        let steps: [(String, Int)] = [("Gefunden", m.found), ("Beworben", m.applied), ("Antwort", m.responses),
                                      ("Gespräch", m.interviews), ("Angebot", m.offers)]
        let top = max(steps.map(\.1).max() ?? 1, 1)
        return GroupBox("Trichter") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(steps, id: \.0) { name, value in
                    HStack(spacing: 8) {
                        Text(name).font(.caption).frame(width: 64, alignment: .leading)
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.quaternary.opacity(0.5))
                                Capsule().fill(Color.accentColor.gradient)
                                    .frame(width: max(3, g.size.width * CGFloat(value) / CGFloat(top)))
                            }
                        }
                        .frame(height: 10)
                        Text("\(value)").font(.caption.weight(.semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Follow-ups / interviews

    private func followUps(_ items: [JobSummary]) -> some View {
        GroupBox {
            if items.isEmpty {
                Text("Nichts fällig. Bewerbungen ohne Antwort erscheinen hier nach \(Tracker.followUpDays) Tagen (oder am gesetzten Erinnerungsdatum).")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items.prefix(8)) { job in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Button(job.title) { select(job) }
                                    .buttonStyle(.link).lineLimit(1)
                                Text([job.company, Tracker.channel(job)?.label,
                                      Tracker.daysSinceApplied(job).map { "vor \($0) Tagen" }]
                                        .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                model.openFollowUpDraft(job)
                            } label: { Label("Entwurf", systemImage: "envelope.badge") }
                                .help("Öffnet einen Nachfass-Entwurf im Mailprogramm – es wird nichts gesendet")
                            Menu {
                                Button("Text kopieren") { copyToPasteboard(model.followUpDraft(for: job).body) }
                                Button("Als nachgefasst markieren (+\(Tracker.followUpDays) Tage)") { model.followUpDone(id: job.id) }
                                Button("Erinnerung in 7 Tagen") { model.snoozeFollowUp(id: job.id, days: 7) }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize()
                        }
                        .controlSize(.small)
                    }
                    if items.count > 8 { Text("+ \(items.count - 8) weitere").font(.caption).foregroundStyle(.secondary) }
                }
            }
        } label: {
            Label("Nachfassen (\(items.count))", systemImage: "arrow.uturn.forward.circle")
                .foregroundStyle(items.isEmpty ? Color.primary : Color.orange)
        }
        .frame(maxWidth: .infinity)
    }

    private func interviews(_ items: [JobSummary]) -> some View {
        GroupBox {
            if items.isEmpty {
                Text("Keine Termine. Karte nach „Gespräch“ ziehen oder Kontextmenü › „Gesprächstermin eintragen …“.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { job in
                        HStack {
                            if let d = Tracker.interviewDate(job.interviewAt) {
                                Text(Tracker.fmtDateTime(d)).font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            Button(job.title) { select(job) }.buttonStyle(.link).lineLimit(1)
                            Text(job.company ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button { model.openInterviewInCalendar(job) } label: { Image(systemName: "calendar.badge.plus") }
                                .buttonStyle(.borderless)
                                .help("In Kalender übernehmen (Kalender fragt vor dem Hinzufügen)")
                        }
                    }
                }
            }
        } label: {
            Label("Nächste Gespräche", systemImage: "person.2")
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Kanban

    private var kanbanHeader: some View {
        HStack {
            Text("Pipeline").font(.headline)
            Text("Karten ziehen oder Rechtsklick › Status · ⌥⌘1…7 setzt den Status der ausgewählten Stelle")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Toggle("Neu", isOn: $showNew).toggleStyle(.checkbox)
            Toggle("Absage & Zu weit", isOn: $showClosed).toggleStyle(.checkbox)
        }
    }

    private func kanban(_ jobs: [JobSummary]) -> some View {
        let statuses = Tracker.columns.filter { s in
            (showNew || s != .neu) && (showClosed || (s != .absage && s != .zuWeit))
        }
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(statuses) { status in
                    KanbanColumn(status: status, jobs: Tracker.column(status, in: jobs), limit: perColumn,
                                 onShowAll: { showAll(status) })
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func select(_ job: JobSummary) {
        model.selectedJobIDs = []
        model.selectedJobID = job.id
    }

    private func showAll(_ status: JobStatus) {
        model.filter.status = .only(status)
        model.sidebarSelection = .jobs
    }

    @ViewBuilder
    private var lastRun: some View {
        if let run = model.stats?.lastRun {
            GroupBox("Letzter Suchlauf") {
                VStack(alignment: .leading, spacing: 4) {
                    if let end = ServerDate.parse(run.finishedAt) {
                        LabeledContent("Beendet") { Text(end, format: .dateTime.day().month().hour().minute()) }
                    }
                    LabeledContent("Neue Stellen", value: "\(run.newJobs)")
                    ForEach(run.errors, id: \.self) { err in
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct KanbanColumn: View {
    @Environment(AppModel.self) private var model
    let status: JobStatus
    let jobs: [JobSummary]
    let limit: Int
    let onShowAll: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(status.label, systemImage: status.symbolName).font(.headline)
                Spacer()
                Text("\(jobs.count)").font(.callout.weight(.semibold)).monospacedDigit()
            }
            .foregroundStyle(statusTint(status))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(statusTint(status).opacity(0.14))
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(jobs.prefix(limit)) { job in
                    KanbanCard(job: job)
                }
                if jobs.count > limit {
                    Button("+ \(jobs.count - limit) weitere in der Liste …", action: onShowAll)
                        .buttonStyle(.link).font(.caption).padding(.vertical, 4)
                }
                if jobs.isEmpty {
                    Text("Leer – Karte hierher ziehen").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
            }
            .padding(8)
        }
        .frame(width: 236)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(targeted ? Color.accentColor : .clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(Int.init).filter { id in model.job(id)?.status != status }
            guard !ids.isEmpty else { return false }
            switch status {
            case .absage: model.reasonSheetJobIDs = ids
            default:
                model.setStatus(ids: ids, status)
                if status == .gespraech, ids.count == 1, model.job(ids[0])?.interviewAt == nil {
                    model.interviewSheetJobID = ids[0]
                }
            }
            return true
        } isTargeted: { targeted = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.label), \(jobs.count) Stellen")
    }
}

private struct KanbanCard: View {
    @Environment(AppModel.self) private var model
    let job: JobSummary

    var body: some View {
        let selected = model.selectedJobID == job.id
        let due = Tracker.followUpDue(job)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                ScoreBadge(score: job.score)
                Text(job.title).font(.callout.weight(.semibold)).lineLimit(3)
            }
            if let c = job.company, !c.isEmpty {
                Text(c).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let ch = Tracker.channel(job) {
                Text(ch.label + (Tracker.daysSinceApplied(job).map { $0 == 0 ? " · heute" : " · vor \($0) T." } ?? ""))
                .font(.caption2).foregroundStyle(ch.isEmail ? Color.blue : Color.secondary)
            }
            if let d = Tracker.interviewDate(job.interviewAt) {
                Label(Tracker.fmtDateTime(d), systemImage: "calendar").font(.caption2).foregroundStyle(.orange)
            }
            Text("➜ " + Tracker.nextStep(job, category: model.category(of: job)))
                .font(.caption2)
                .foregroundStyle(due ? Color.orange : Color.secondary)
                .fontWeight(due ? .semibold : .regular)
                .lineLimit(2)
            if let n = job.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
                Text("📝 " + n).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            if !model.pendingChanges(for: job.id).isEmpty {
                Label("wartet auf Sync", systemImage: "arrow.triangle.2.circlepath").font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedJobIDs = []
            model.selectedJobID = job.id
        }
        .draggable(String(job.id)) {
            Text(job.title).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .contextMenu { JobActionsMenu(ids: [job.id]) }
        .help(job.companyAndLocation)
        .accessibilityAddTraits(.isButton)
    }
}

func statusTint(_ status: JobStatus) -> Color {
    switch status {
    case .neu: .blue
    case .interessant: .purple
    case .beworben: .teal
    case .gespraech: .orange
    case .absage: .red
    case .angebot: .green
    case .zuWeit: .gray
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .help(help ?? title)
    }
}
