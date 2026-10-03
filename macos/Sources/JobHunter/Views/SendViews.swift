import JobHunterCore
import SwiftUI

/// Persistent banner: is anything going out for real? Always visible above all columns.
struct SendBanner: View {
    @Environment(AppModel.self) private var model
    /// Detail column: one line only.
    var compact = false

    var body: some View {
        let kind = model.bannerKind
        let s = model.sendSettings
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: icon(kind))
                Text(kind.headline(s)).font(.callout.weight(.bold))
                if model.isSending {
                    ProgressView().controlSize(.mini)
                    Text("sendet …").font(.caption)
                }
            }
            if !compact && model.isOnline {
                Text(serverLine(s)).font(.caption)
                Text(countsLine(s)).font(.caption.monospacedDigit())
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(foreground(kind))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(background(kind))
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private func serverLine(_ s: SendSettings?) -> String {
        let server = s.map { "Server: \($0.mode)" + ($0.dryRun ? " + dry_run" : "") + ($0.killSwitch ? " + kill_switch" : "") }
            ?? "Server: unbekannt"
        return server + " · App „Automatisch senden“: " + (model.settings.autoSendEnabled ? "AN" : "AUS")
    }

    private func countsLine(_ s: SendSettings?) -> String {
        s.map { "Heute gesendet: \($0.sentToday) · Insgesamt gesendet: \($0.sentTotal) · Im Testmodus vorbereitet: \($0.dryRunTotal)" }
            ?? "Heute gesendet: – · Insgesamt gesendet: – · Im Testmodus vorbereitet: –"
    }

    private func icon(_ k: SendBannerKind) -> String {
        switch k {
        case .test: "testtube.2"
        case .auto: "paperplane.fill"
        case .approve: "hand.tap"
        case .kill: "exclamationmark.octagon.fill"
        case .off, .unknown: "envelope.badge.shield.half.filled"
        }
    }

    private func background(_ k: SendBannerKind) -> Color {
        switch k {
        case .test: .yellow.opacity(0.35)
        case .auto, .kill: .red.opacity(0.28)
        case .approve: .green.opacity(0.22)
        case .off, .unknown: .gray.opacity(0.18)
        }
    }

    private func foreground(_ k: SendBannerKind) -> Color {
        k == .auto || k == .kill ? .red : .primary
    }
}

/// Per-job badge: "✉ Gesendet am … an …" / "Test – nicht gesendet" / "Bereit zum Senden" / "Nur manuell …".
struct SendBadge: View {
    let state: SendStateInfo?
    var compact = false

    var body: some View {
        if let state {
            HStack(spacing: 4) {
                main(state)
                if let test = state.testAt, state.state != "sent", state.state != "test" {
                    chip("Test – nicht gesendet", .yellow).help("Testlauf am \(formatted(test))")
                }
            }
        }
    }

    @ViewBuilder
    private func main(_ s: SendStateInfo) -> some View {
        switch s.state {
        case "sent":
            chip("✉ Gesendet am \(formatted(s.sentAt, dateOnly: true)) an \(s.to ?? "?")", .red, bold: true)
        case "test":
            chip("Test – nicht gesendet", .yellow).help(s.testAt.map { "Testlauf am \(formatted($0))" } ?? "")
        case "ready":
            chip(s.approved == true ? "Bereit zum Senden (freigegeben)" : "Bereit zum Senden", .green)
        case "manual":
            chip(compact ? "Nur manuell" : "Nur manuell (keine E-Mail-Adresse)", .gray)
        default:
            if s.approved == true {
                chip("Freigegeben", .green)
            } else if !compact, let to = s.to {
                chip("E-Mail: \(to)", .gray)
            } else if compact {
                Image(systemName: "envelope").help("E-Mail-Bewerbung möglich: \(s.to ?? "")")
            }
        }
    }

    private func chip(_ text: String, _ color: Color, bold: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(bold ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(color == .gray ? Color.secondary : (color == .yellow ? Color.primary : color))
    }
}

func formatted(_ ts: String?, dateOnly: Bool = false) -> String {
    guard let d = ServerDate.parse(ts) else { return ts ?? "–" }
    return dateOnly ? d.formatted(date: .numeric, time: .omitted) : d.formatted(date: .numeric, time: .shortened)
}

/// One row of the Postausgang: sent / test / waiting / error.
struct MailRow: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case sent = "Gesendet ✅", test = "Test 🧪", waiting = "Wartet ⏳", error = "Fehler ❌"
        var id: String { rawValue }
        var tint: Color {
            switch self {
            case .sent: .green
            case .test: .yellow
            case .waiting: .blue
            case .error: .red
            }
        }
    }

    var id: String
    var kind: Kind
    var date: Date?
    var to: String
    var subject: String
    var company: String?
    var title: String?
    var jobID: Int?
    var note: String?
    var sentEntry: SentEntry?
}

/// "Postausgang": every real send, test run, waiting item and failure, with a summary header.
struct OutboxView: View {
    @Environment(AppModel.self) private var model
    @State private var message: String?
    @State private var filter: MailRow.Kind?

    private var rows: [MailRow] {
        var rows: [MailRow] = model.sentLog.map { e in
            MailRow(id: "s\(e.id)", kind: e.dryRun ? .test : .sent, date: e.sentDate, to: e.to, subject: e.subject,
                    company: e.company, title: e.title, jobID: e.jobId,
                    note: e.dryRun ? "nicht gesendet (Testmodus)" : (e.trigger.map { "Auslöser: \($0)" }), sentEntry: e)
        }
        let sentIDs = Set(model.sentLog.filter { !$0.dryRun }.map(\.jobId))
        // Sent on this Mac, but the server has not acknowledged it yet (ledger).
        for (jobID, r) in model.settings.ledger.pending() where !sentIDs.contains(jobID) {
            let job = model.allJobs.first { $0.id == jobID }
            rows.append(MailRow(id: "l\(jobID)", kind: .sent, date: ServerDate.parse(r.sentAt), to: r.to, subject: r.subject,
                                company: job?.company, title: job?.title, jobID: jobID,
                                note: "Server-Meldung wird nachgeholt"))
        }
        for item in model.outbox?.items ?? [] where !sentIDs.contains(item.jobId) {
            rows.append(MailRow(id: "o\(item.jobId)", kind: .waiting, date: nil, to: item.email.to ?? "–",
                                subject: item.email.subject, company: item.company, title: item.title, jobID: item.jobId,
                                note: (item.isApproved ? "freigegeben" : "automatisch") + waitingReason))
        }
        for f in model.sendFailures {
            rows.append(MailRow(id: "f\(f.id)", kind: .error, date: f.at, to: f.to ?? "–", subject: f.subject ?? "–",
                                company: f.company, title: f.title, jobID: f.jobID, note: f.message))
        }
        return rows.sorted { ($0.kind == .waiting ? 0 : 1, -(($0.date ?? .distantFuture).timeIntervalSince1970))
                           < ($1.kind == .waiting ? 0 : 1, -(($1.date ?? .distantFuture).timeIntervalSince1970)) }
    }

    private var waitingReason: String {
        guard let o = model.outbox else { return "" }
        if !model.isOnline { return " · offline – wird erst gesendet, wenn der Server erreichbar ist" }
        if o.killSwitch { return " · Not-Aus aktiv" }
        if o.dryRun { return " · Testmodus: wird nicht gesendet" }
        if o.mode == "auto" && !model.settings.autoSendEnabled { return " · „Automatisch senden“ ist in der App aus" }
        return ""
    }

    var body: some View {
        let all = rows
        let items = all.filter { filter == nil || $0.kind == filter }
        VStack(spacing: 0) {
            summary(all)
            if let message {
                HStack {
                    Text(message).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button { self.message = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(8)
                .background(.orange.opacity(0.12))
            }
            List(items) { r in
                HStack(alignment: .top, spacing: 10) {
                    Text(r.kind.rawValue)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(r.kind.tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 112, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.date.map { $0.formatted(date: .numeric, time: .shortened) } ?? "noch nicht gesendet")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let e = r.sentEntry, !e.dryRun {
                                Button("In Mail öffnen") { Task { message = await model.openInMail(e) } }
                                    .controlSize(.small)
                            }
                        }
                        Text("An: \(r.to)").font(.callout).textSelection(.enabled).lineLimit(1)
                        Text(r.subject).font(.callout.weight(.medium)).lineLimit(2).textSelection(.enabled)
                        if let id = r.jobID {
                            Button((r.company.map { "\($0) – " } ?? "") + (r.title ?? "#\(id)")) { model.open(jobID: id) }
                                .buttonStyle(.link)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        if let note = r.note {
                            Text(note).font(.caption)
                                .foregroundStyle(r.kind == .error ? Color.red : Color.secondary)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(filter == nil ? "Noch nichts gesendet" : "Keine Einträge „\(filter!.rawValue)“",
                                           systemImage: "tray",
                                           description: Text("Hier erscheint jede Bewerbung per E-Mail – gesendet, Test, wartend oder fehlgeschlagen."))
                }
            }
        }
        .navigationTitle("Postausgang")
        .task { await model.loadSentLog() }
    }

    private func summary(_ rows: [MailRow]) -> some View {
        let count = { (k: MailRow.Kind) in rows.filter { $0.kind == k }.count }
        let s = model.sendSettings
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(MailRow.Kind.allCases) { k in
                    Button {
                        filter = filter == k ? nil : k
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.rawValue).font(.caption).foregroundStyle(.secondary)
                            Text("\(count(k))").font(.title2.weight(.semibold)).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(k.tint.opacity(filter == k ? 0.3 : 0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Nur „\(k.rawValue)“ anzeigen")
                }
            }
            HStack(spacing: 6) {
                if let s {
                    Text("Heute gesendet: \(s.sentToday) von \(s.dailyCap) · insgesamt \(s.sentTotal) · Test: \(s.dryRunTotal) · Modus: \(s.mode)\(s.dryRun ? " (TESTMODUS)" : "")")
                } else {
                    Text("Server-Zähler unbekannt")
                }
                if !model.isOnline {
                    Text("· offline: Stand der letzten Verbindung, es wird nichts gesendet").foregroundStyle(.orange)
                }
                Spacer()
                if !model.sendFailures.isEmpty {
                    Button("Fehler ausblenden") { model.clearSendFailures() }.controlSize(.small)
                }
            }
            .font(.caption)
        }
        .padding(10)
        .overlay(alignment: .bottom) { Divider() }
    }
}
