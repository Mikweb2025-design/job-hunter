import JobHunterCore
import SwiftUI

struct JobListView: View {
    let item: SidebarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.list(for: item)
        List(items, selection: $model.selectedJobID) { job in
            JobRow(job: job, category: model.category(of: job), pending: !model.pendingChanges(for: job.id).isEmpty)
                .tag(job.id)
                .contextMenu {
                    if let link = job.link {
                        Link("Bewerbung öffnen", destination: link)
                        Button("Link kopieren") { copyToPasteboard(link.absoluteString) }
                    }
                    if job.status != .beworben {
                        Button("Als beworben markieren") { _ = model.markApplied(id: job.id) }
                    }
                }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .searchable(text: $model.filter.query, placement: .toolbar, prompt: "Titel, Firma, Text")
        .navigationTitle(title)
        .navigationSubtitle(items.count == 1 ? "1 Treffer" : "\(items.count) Treffer")
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .overlay {
            if items.isEmpty {
                if model.isLoading && model.allJobs.isEmpty {
                    ProgressView("Lade Stellen …")
                } else if !model.allJobs.isEmpty || model.connection == .ok {
                    ContentUnavailableView("Keine Stellen", systemImage: "tray",
                                           description: Text(emptyText))
                } else if model.errorMessage != nil {
                    ContentUnavailableView("Keine Verbindung und noch keine gespeicherten Daten", systemImage: "wifi.exclamationmark",
                                           description: Text(model.errorMessage ?? ""))
                }
            }
        }
    }

    private var title: String {
        item.category?.title ?? "Alle Stellen"
    }

    private var emptyText: String {
        switch item {
        case .manual: "Keine offenen Stellen ohne E-Mail-Adresse."
        case .automatic: "Keine offenen Stellen mit Bewerbungs-Adresse."
        default: "Starte einen Suchlauf oder lockere die Filter."
        }
    }

    @ViewBuilder
    private var header: some View {
        switch item {
        case .manual:
            ListHint(icon: "hand.point.up.left.fill", tint: .orange,
                     text: "Hier musst DU dich selbst bewerben: Stelle öffnen › „Jetzt manuell bewerben“ › danach „Als beworben markieren“.")
        case .automatic:
            ListHint(icon: "envelope.fill", tint: .blue,
                     text: "Diese Stellen haben eine Bewerbungs-Adresse. Die App sendet per Apple Mail – nur nach den Regeln des Servers (Testmodus, Freigabe, Tageslimit) und nie offline.")
        default:
            EmptyView()
        }
    }
}

private struct ListHint: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.caption).lineLimit(3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct JobRow: View {
    let job: JobSummary
    var category: ApplyCategory? = nil
    var pending = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScoreBadge(score: job.score)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.headline)
                    .lineLimit(2)
                if !job.companyAndLocation.isEmpty {
                    Text(job.companyAndLocation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let category {
                    ApplyMethodLabel(job: job, category: category)
                }
                HStack(spacing: 6) {
                    StatusChip(status: job.status)
                    if job.remote {
                        Label("Remote", systemImage: "house")
                            .labelStyle(.iconOnly)
                            .help("Remote/Homeoffice möglich")
                    }
                    if job.hasLetter {
                        Image(systemName: job.letterOrigin == "vorlage" ? "doc.text" : "doc.text.fill")
                            .help(job.letterOrigin == "vorlage" ? "Nur Vorlagen-Anschreiben" : "Anschreiben vorhanden (\(job.letterOrigin ?? ""))")
                    }
                    if pending {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.orange)
                            .help("Lokale Änderung wartet auf Synchronisierung")
                    }
                    Text(sourceLabel(job.source))
                    if let date = job.fetchedDate {
                        Text("·")
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let st = job.sendState, ["sent", "test", "ready"].contains(st.state) || st.approved == true {
                    SendBadge(state: st)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Prominent per-row label: automatic e-mail vs. MANUELL via portal.
struct ApplyMethodLabel: View {
    let job: JobSummary
    let category: ApplyCategory

    var body: some View {
        switch category {
        case .automatic:
            label("Automatisch (E-Mail an \(job.applyEmail ?? "?"))", "envelope.fill", .blue, bold: false)
        case .manual:
            label(job.applyEmail == nil ? "MANUELL – über Portal bewerben" : "MANUELL – Firma gesperrt, über Portal bewerben",
                  "hand.point.up.left.fill", .orange, bold: true)
        case .applied:
            label(appliedText, "checkmark.circle.fill", .green, bold: false)
        case .later:
            label("Später/abgelehnt", "pause.circle", .gray, bold: false)
        }
    }

    private var appliedText: String {
        if let st = job.sendState, st.isSent { return "Beworben per E-Mail an \(st.to ?? "?")" }
        if let d = ServerDate.parse(job.appliedDate) {
            return "Beworben am \(d.formatted(date: .numeric, time: .omitted))"
        }
        return "Beworben"
    }

    private func label(_ text: String, _ icon: String, _ tint: Color, bold: Bool) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(bold ? .bold : .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(bold ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(tint == .gray ? Color.secondary : tint)
    }
}

struct ScoreBadge: View {
    let score: Int
    var large = false

    var body: some View {
        Text("\(score)")
            .font(large ? .title2.weight(.bold) : .callout.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: large ? 54 : 36, height: large ? 54 : 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: large ? 12 : 7, style: .continuous))
            .accessibilityLabel("Score \(score)")
            .help("Score \(score) von 100")
    }

    private var color: Color {
        switch score {
        case 75...: .green
        case 55..<75: .orange
        case 1..<55: .gray
        default: .red.opacity(0.7)
        }
    }
}

struct StatusChip: View {
    let status: JobStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .neu: .blue
        case .interessant: .purple
        case .beworben: .teal
        case .gespraech: .orange
        case .absage: .secondary
        case .angebot: .green
        }
    }
}

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
