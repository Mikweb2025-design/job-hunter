import Foundation

/// Application tracker logic (columns, KPIs, follow-ups, interviews). Same rules as the server's
/// `jobhunter/tracker.py` – keep both in sync:
///
/// * applied   – real e-mail sent, or status beworben/gespraech/angebot, or absage with an applied
///               date. Close reason "duplikat" never counts.
/// * responded – applied and gespraech/angebot, or an employer absage (no reason, "absage_firma",
///               "stelle_besetzt").
/// * follow-up – status beworben and follow_up_at <= today, or no follow_up_at and applied
///               >= `followUpDays` days ago ("Nachfassen").
///
/// Works fully offline on the locally known jobs (pending edits included).
public enum Tracker {
    public static let followUpDays = 14
    /// Kanban order: the pipeline from left to right, the closed ones at the end.
    public static let columns: [JobStatus] = [.neu, .interessant, .beworben, .gespraech, .angebot, .absage, .zuWeit]

    public enum CloseReason: String, CaseIterable, Sendable, Identifiable {
        case duplikat, keinInteresse = "kein_interesse", stelleBesetzt = "stelle_besetzt",
             absageFirma = "absage_firma", sonstiges
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .duplikat: "Duplikat"
            case .keinInteresse: "Kein Interesse"
            case .stelleBesetzt: "Stelle besetzt"
            case .absageFirma: "Absage der Firma"
            case .sonstiges: "Sonstiges"
            }
        }
        /// Counts as an answer from the employer.
        public static func isEmployerAnswer(_ raw: String?) -> Bool {
            guard let raw, !raw.isEmpty else { return true }
            return raw == CloseReason.absageFirma.rawValue || raw == CloseReason.stelleBesetzt.rawValue
        }
    }

    // MARK: Dates (Europe/Berlin, like the user)

    nonisolated(unsafe) public static var calendar: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        c.locale = Locale(identifier: "de_DE")
        return c
    }()

    public static func day(_ value: String?) -> Date? {
        guard let value, value.count >= 10 else { return nil }
        var comps = DateComponents()
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    public static func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: to)).day ?? 0
    }

    /// Interview time "YYYY-MM-DDTHH:MM" (local wall time).
    public static func interviewDate(_ value: String?) -> Date? {
        guard let value, value.count >= 16 else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.date(from: String(value.prefix(16)))
    }

    public static func interviewString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f.string(from: date)
    }

    public static func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func fmtDay(_ date: Date?) -> String {
        guard let date else { return "–" }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", c.day ?? 0, c.month ?? 0, c.year ?? 0)
    }

    public static func fmtDateTime(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%02d.%02d.%04d %02d:%02d", c.day ?? 0, c.month ?? 0, c.year ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: Rules

    public static func isSent(_ job: JobSummary) -> Bool { job.sendState?.isSent == true }

    public static func isApplied(_ job: JobSummary) -> Bool {
        if job.closeReason == CloseReason.duplikat.rawValue { return false }
        if isSent(job) { return true }
        switch job.status {
        case .beworben, .gespraech, .angebot: return true
        case .absage: return job.appliedDate?.isEmpty == false
        default: return false
        }
    }

    public static func hasResponse(_ job: JobSummary) -> Bool {
        guard isApplied(job) else { return false }
        switch job.status {
        case .gespraech, .angebot: return true
        case .absage: return CloseReason.isEmployerAnswer(job.closeReason)
        default: return false
        }
    }

    public static func appliedDay(_ job: JobSummary) -> Date? {
        day(job.appliedDate) ?? (isSent(job) ? day(job.sendState?.sentAt) : nil)
    }

    public enum Channel: Equatable, Sendable {
        case email(sentAt: Date?, to: String?)
        case manual(on: Date?)

        public var label: String {
            switch self {
            case .email(let at, _): "✉ E-Mail gesendet am \(Tracker.fmtDay(at))"
            case .manual(let on): "🖐 manuell beworben" + (on.map { " am \(Tracker.fmtDay($0))" } ?? "")
            }
        }
        public var isEmail: Bool { if case .email = self { true } else { false } }
    }

    public static func channel(_ job: JobSummary) -> Channel? {
        if isSent(job) { return .email(sentAt: day(job.sendState?.sentAt), to: job.sendState?.to) }
        if isApplied(job) { return .manual(on: day(job.appliedDate)) }
        return nil
    }

    public static func daysSinceApplied(_ job: JobSummary, now: Date = .now) -> Int? {
        appliedDay(job).map { days(from: $0, to: now) }
    }

    public static func followUpFrom(_ job: JobSummary) -> Date? {
        if let fu = day(job.followUpAt) { return fu }
        return appliedDay(job).flatMap { calendar.date(byAdding: .day, value: followUpDays, to: $0) }
    }

    public static func followUpDue(_ job: JobSummary, now: Date = .now) -> Bool {
        guard job.status == .beworben, let from = followUpFrom(job) else { return false }
        return calendar.startOfDay(for: from) <= calendar.startOfDay(for: now)
    }

    /// `category`: the job's apply category for open jobs (auto/manual) – nil if unknown.
    public static func nextStep(_ job: JobSummary, category: ApplyCategory? = nil, now: Date = .now) -> String {
        switch job.status {
        case .neu, .interessant:
            if ApplyCategory.isFar(job) { return "Zu weit weg – nur bei Interesse manuell" }
            if category == .automatic { return "Wird per E-Mail beworben (Regeln im Postausgang)" }
            return "Manuell über das Portal bewerben"
        case .beworben:
            if followUpDue(job, now: now) {
                if let d = daysSinceApplied(job, now: now) { return "Nachfassen – seit \(d) Tagen keine Antwort" }
                return "Nachfassen"
            }
            if let fu = followUpFrom(job) { return "Auf Antwort warten (Nachfassen ab \(fmtDay(fu)))" }
            return "Auf Antwort warten"
        case .gespraech:
            guard let it = interviewDate(job.interviewAt) else { return "Gesprächstermin eintragen" }
            if calendar.startOfDay(for: it) >= calendar.startOfDay(for: now) {
                return "Gespräch am \(fmtDateTime(it)) vorbereiten"
            }
            return "Rückmeldung nach dem Gespräch abwarten"
        case .angebot: return "Angebot prüfen und antworten"
        case .absage:
            if let r = job.closeReason.flatMap(CloseReason.init(rawValue:)) { return "Abgeschlossen (\(r.label))" }
            return "Abgeschlossen"
        case .zuWeit: return "Kein Umzug – nicht bewerben"
        }
    }

    // MARK: Follow-up draft (never sent automatically)

    public struct Draft: Equatable, Sendable {
        public var to: String
        public var subject: String
        public var body: String

        /// mailto: URL – opens a compose window in the mail app, nothing is sent.
        public var mailtoURL: URL? {
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = to
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            // URLComponents encodes "+" literally; mail clients read it as "+", fine. Spaces → %20.
            return c.url
        }
    }

    public static func followUpDraft(_ job: JobSummary, applicantName: String) -> Draft {
        let title = job.title.isEmpty ? "die ausgeschriebene Stelle" : job.title
        let when = appliedDay(job).map { "am \(fmtDay($0)) " } ?? ""
        let body = """
        Sehr geehrte Damen und Herren,

        \(when)habe ich mich bei Ihnen als \(title) beworben. Ich interessiere mich weiterhin sehr \
        für die Stelle und möchte mich erkundigen, ob Sie mir schon etwas zum weiteren Ablauf sagen können.

        Für Rückfragen stehe ich Ihnen gern zur Verfügung.

        Mit freundlichen Grüßen
        \(applicantName)
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = (isSent(job) ? job.sendState?.to : nil) ?? job.applyEmail ?? ""
        return Draft(to: to, subject: "Nachfrage zu meiner Bewerbung als \(title)", body: body)
    }

    // MARK: Metrics

    public struct Week: Identifiable, Equatable, Sendable {
        public var start: Date
        public var label: String
        public var applications: Int
        public var responses: Int
        public var id: Date { start }
    }

    public struct SourceCount: Identifiable, Equatable, Sendable {
        public var label: String
        public var applications: Int
        public var responses: Int
        public var id: String { label }
    }

    public struct Metrics: Equatable, Sendable {
        public var found = 0
        public var applied = 0
        public var thisWeek = 0
        public var byEmail = 0
        public var manual = 0
        public var responses = 0
        public var interviews = 0
        public var offers = 0
        public var rejections = 0
        public var waiting = 0
        public var avgDaysToAnswer: Double?
        public var weeks: [Week] = []
        public var bySource: [SourceCount] = []

        /// Percent (0–100), nil without applications.
        public var responseRate: Int? {
            applied > 0 ? Int((100 * Double(responses) / Double(applied)).rounded()) : nil
        }
    }

    public static func weekStart(_ date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Day the employer answered: last status change (status_updated_at) for jobs in a response status.
    public static func answerDay(_ job: JobSummary) -> Date? {
        guard [.gespraech, .absage, .angebot].contains(job.status) else { return nil }
        return ServerDate.parse(job.statusUpdatedAt).map { calendar.startOfDay(for: $0) }
    }

    public static func metrics(_ jobs: [JobSummary], sourceLabel: (String) -> String = { $0 },
                               now: Date = .now, weeks: Int = 12) -> Metrics {
        var m = Metrics()
        m.found = jobs.count
        let applied = jobs.filter(isApplied)
        let responded = applied.filter(hasResponse)
        m.applied = applied.count
        m.responses = responded.count
        m.byEmail = applied.filter(isSent).count
        m.manual = applied.count - m.byEmail
        let week0 = weekStart(now)
        m.thisWeek = applied.filter { (appliedDay($0) ?? .distantPast) >= week0 }.count
        m.interviews = applied.filter { $0.status == .gespraech || $0.status == .angebot || $0.interviewAt != nil }.count
        m.offers = applied.filter { $0.status == .angebot }.count
        m.rejections = responded.filter { $0.status == .absage }.count
        m.waiting = applied.filter { $0.status == .beworben }.count
        let answerDays: [Int] = responded.compactMap { j in
            guard let ad = appliedDay(j), let ans = answerDay(j) else { return nil }
            return max(0, days(from: ad, to: ans))
        }
        if !answerDays.isEmpty {
            m.avgDaysToAnswer = (Double(answerDays.reduce(0, +)) / Double(answerDays.count) * 10).rounded() / 10
        }
        var buckets: [(Date, Int, Int)] = (0..<weeks).reversed().compactMap { i in
            calendar.date(byAdding: .weekOfYear, value: -i, to: week0).map { ($0, 0, 0) }
        }
        for j in applied {
            if let ad = appliedDay(j), let i = buckets.firstIndex(where: { $0.0 == weekStart(ad) }) { buckets[i].1 += 1 }
        }
        for j in responded {
            if let ans = answerDay(j), let i = buckets.firstIndex(where: { $0.0 == weekStart(ans) }) { buckets[i].2 += 1 }
        }
        m.weeks = buckets.map { b in
            let wk = calendar.component(.weekOfYear, from: b.0)
            return Week(start: b.0, label: "KW \(wk)", applications: b.1, responses: b.2)
        }
        var src: [String: SourceCount] = [:]
        for j in applied {
            let label = sourceLabel(j.source)
            var e = src[label] ?? SourceCount(label: label, applications: 0, responses: 0)
            e.applications += 1
            if hasResponse(j) { e.responses += 1 }
            src[label] = e
        }
        m.bySource = src.values.sorted { ($0.applications, $1.label) > ($1.applications, $0.label) }
        return m
    }

    /// Jobs of one Kanban column, sorted like the dashboard (applied columns: newest applied first;
    /// open columns: best score first).
    public static func column(_ status: JobStatus, in jobs: [JobSummary]) -> [JobSummary] {
        let items = jobs.filter { $0.status == status }
        switch status {
        case .beworben, .gespraech, .angebot, .absage:
            return items.sorted {
                ($0.appliedDate ?? $0.statusUpdatedAt ?? "", $0.score) > ($1.appliedDate ?? $1.statusUpdatedAt ?? "", $1.score)
            }
        default:
            return items.sorted { ($0.score, $0.id) > ($1.score, $1.id) }
        }
    }

    public static func followUps(_ jobs: [JobSummary], now: Date = .now) -> [JobSummary] {
        jobs.filter { followUpDue($0, now: now) }
            .sorted { (daysSinceApplied($0, now: now) ?? 0) > (daysSinceApplied($1, now: now) ?? 0) }
    }

    public static func upcomingInterviews(_ jobs: [JobSummary], now: Date = .now) -> [JobSummary] {
        let today = calendar.startOfDay(for: now)
        return jobs.compactMap { j in interviewDate(j.interviewAt).flatMap { $0 >= today ? (j, $0) : nil } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// A line appended to the notes ("Nachgefasst am 08.10.2026.").
    public static func appendNote(_ notes: String?, _ line: String) -> String {
        let base = (notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? line : base + "\n" + line
    }

    // MARK: Calendar file (.ics) – opened in Calendar, which asks before adding anything

    public static func icsEvent(title: String, company: String?, start: Date, minutes: Int = 60,
                                notes: String? = nil, url: URL? = nil, uid: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\n", with: "\\n")
        }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//JobHunter//DE", "BEGIN:VEVENT",
                     "UID:\(uid)", "DTSTAMP:\(f.string(from: .now))", "DTSTART:\(f.string(from: start))",
                     "DTEND:\(f.string(from: end))",
                     "SUMMARY:\(esc("Vorstellungsgespräch: " + title + (company.map { " – \($0)" } ?? "")))"]
        if let notes, !notes.isEmpty { lines.append("DESCRIPTION:\(esc(notes))") }
        if let url { lines.append("URL:\(url.absoluteString)") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Status history (GET /api/v1/jobs/{id}/history, newer servers)

public struct HistoryEvent: Codable, Sendable, Hashable, Identifiable {
    public var at: String
    /// found | status | sent | test | interview
    public var kind: String
    public var label: String
    public var detail: String?
    public var from: String?
    public var to: String?

    public var id: String { "\(kind)|\(at)|\(label)" }
    public var date: Date? { kind == "interview" ? Tracker.interviewDate(at) : ServerDate.parse(at) }
}

public struct JobHistory: Codable, Sendable, Hashable {
    public var jobId: Int
    public var events: [HistoryEvent]
}

extension APIClient {
    /// Timeline of one job. Older servers answer 404.
    public func history(id: Int) async throws -> JobHistory {
        try await send("GET", "jobs/\(id)/history")
    }
}
