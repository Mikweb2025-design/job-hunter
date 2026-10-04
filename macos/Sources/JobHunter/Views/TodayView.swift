import JobHunterCore
import SwiftUI

/// "Heute zu tun": the best open jobs where the user must apply by hand (no e-mail address),
/// as a checklist. Ticking a row marks the job as "beworben" (works offline, synced later).
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// Jobs ticked in this session stay visible (struck through) until the view is left.
    @State private var done: [JobSummary] = []
    @State private var message: String?

    var body: some View {
        @Bindable var model = model
        let open = model.todayJobs.filter { j in !done.contains { $0.id == j.id } }
        List(selection: $model.selectedJobID) {
            Section {
                ForEach(open) { job in row(job, checked: false).tag(job.id) }
                ForEach(done) { job in row(job, checked: true).tag(job.id) }
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diese Bewerbungen musst du selbst abschicken")
                        .font(.headline)
                    Text("Keine E-Mail-Adresse in der Anzeige → über das Portal bewerben. Reihenfolge nach Score, max. 10. "
                         + "Haken setzen = „Beworben“ (Datum heute).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
        .navigationTitle("Heute zu tun")
        .navigationSubtitle(open.isEmpty ? "alles erledigt" : "\(open.count) offen · \(done.count) erledigt")
        .overlay {
            if open.isEmpty && done.isEmpty {
                ContentUnavailableView("Nichts zu tun", systemImage: "checkmark.seal",
                                       description: Text(model.allJobs.isEmpty
                                                         ? "Noch keine Daten geladen."
                                                         : "Keine offenen Stellen, die eine manuelle Bewerbung brauchen."))
            }
        }
    }

    private func row(_ job: JobSummary, checked: Bool) -> some View {
        let letterReady = job.hasLetter && job.letterOrigin != "vorlage"
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if !checked {
                    _ = model.markApplied(id: job.id)
                    done.append(job)
                    message = "„\(job.title)“ als beworben markiert" + (model.isOnline ? "." : " (wird synchronisiert, sobald der Server erreichbar ist).")
                }
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(checked ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(checked ? "Erledigt" : "Als beworben markieren")
            .disabled(checked)

            ScoreBadge(score: job.score)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                    .strikethrough(checked)
                    .foregroundStyle(checked ? .secondary : .primary)
                    .lineLimit(2)
                Text(job.companyAndLocation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !checked {
                    HStack(spacing: 8) {
                        Button {
                            if let link = JobLinks.applyLink(for: job) { openURL(link) }
                            Task { await copyLetter(job, quiet: true) }
                        } label: {
                            Label("Jetzt bewerben", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(JobLinks.applyLink(for: job) == nil)
                        .help("Portal öffnen (Anschreiben wird in die Zwischenablage kopiert)")
                        Button {
                            Task { await copyLetter(job) }
                        } label: {
                            Label("Anschreiben", systemImage: "doc.on.doc")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("Anschreiben kopieren")
                        Button {
                            Task { await savePDF(job) }
                        } label: {
                            Label("PDF", systemImage: "doc.richtext")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(!job.hasLetter)
                        .help("Ganzes Anschreiben als A4-PDF speichern (\(model.settings.letterPDFFolder)) und im Finder zeigen")
                        Label(letterReady ? "fertig" : "nur Vorlage",
                              systemImage: letterReady ? "checkmark" : "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(letterReady ? .green : .orange)
                            .lineLimit(1)
                            .help(letterReady ? "Anschreiben vorhanden" : "Nur Vorlage – öffne die Stelle und nutze „Anschreiben mit KI schreiben“")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(checked ? 0.6 : 1)
    }

    private func savePDF(_ job: JobSummary) async {
        do {
            let url = try await model.saveLetterPDF(id: job.id)
            message = "PDF gespeichert: \(url.lastPathComponent)"
        } catch {
            message = error.localizedDescription
        }
    }

    private func copyLetter(_ job: JobSummary, quiet: Bool = false) async {
        let d = model.cachedDetail(id: job.id)
        let detail: JobDetail?
        if let d { detail = d } else { detail = try? await model.loadDetail(id: job.id) }
        guard let letter = detail?.letter, !letter.isEmpty else {
            if !quiet { message = "Kein Anschreiben gespeichert – öffne die Stelle und nutze „Anschreiben mit KI schreiben“." }
            return
        }
        copyToPasteboard(letter)
        message = "Anschreiben für „\(job.title)“ in die Zwischenablage kopiert."
    }
}
