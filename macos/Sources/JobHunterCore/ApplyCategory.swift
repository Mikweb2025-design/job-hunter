import Foundation

/// Where a job stands from the user's point of view: does the app apply by e-mail, or must
/// he apply by hand through the portal?
public enum ApplyCategory: String, CaseIterable, Sendable, Identifiable, Hashable {
    /// Has an application address and is not blocked: the app can send it (server rules apply).
    case automatic
    /// No address (or company on the blocklist): apply by hand via the posting/portal.
    case manual
    /// Applied (status beworben/gespräch/angebot, or an e-mail was really sent).
    case applied
    /// Rejected / put aside (status absage or zu_weit): never auto-sent.
    case later

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "✉ Automatisch per E-Mail"
        case .manual: "🖐 Manuell bewerben"
        case .applied: "✅ Beworben"
        case .later: "⏸ Später/abgelehnt"
        }
    }

    public static func of(_ job: JobSummary, blocklist: [String] = []) -> ApplyCategory {
        if job.sendState?.isSent == true { return .applied }
        switch job.status {
        case .beworben, .gespraech, .angebot: return .applied
        case .absage, .zuWeit: return .later
        case .neu, .interessant: break
        }
        if let email = job.applyEmail?.trimmingCharacters(in: .whitespaces), !email.isEmpty,
           !isBlocked(company: job.company, blocklist: blocklist) {
            return .automatic
        }
        return .manual
    }

    /// Same rule as the server (`send.blocklist`: case-insensitive substring of the company).
    public static func isBlocked(company: String?, blocklist: [String]) -> Bool {
        guard let company = company?.lowercased(), !company.isEmpty else { return false }
        return blocklist.contains { !$0.isEmpty && company.contains($0.lowercased()) }
    }

    /// Anti-trasloco predicate shared by the far list, the detail boxes and the
    /// auto-send guard: user-marked (`zu_weit`) or server-classified (`view == far`).
    /// Far jobs are never auto-sent and have no send button.
    public static func isFar(_ job: JobSummary) -> Bool {
        job.status == .zuWeit || job.view == "far"
    }

    /// Same as the server's `views.freshness_bonus`: posting age (published, else first seen)
    /// ≤ 3 days +10, ≤ 7 +5, ≤ 14 0, ≤ 21 -5, older -10; unknown date 0.
    public static func freshnessBonus(_ job: JobSummary, now: Date = .now) -> Int {
        let raw = String((job.published?.isEmpty == false ? job.published! : job.fetchedAt).prefix(10))
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: raw) else { return 0 }
        let cal = Calendar(identifier: .gregorian)
        let age = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: now)).day ?? 0
        switch age {
        case ...3: return 10
        case ...7: return 5
        case ...14: return 0
        case ...21: return -5
        default: return -10
        }
    }

    /// "Heute zu tun": open manual jobs, best score + freshness first (old postings are often filled).
    public static func todayManual(_ jobs: [JobSummary], blocklist: [String] = [], limit: Int = 10,
                                   now: Date = .now) -> [JobSummary] {
        Array(jobs.filter { of($0, blocklist: blocklist) == .manual }
            .map { ($0, $0.score + freshnessBonus($0, now: now)) }
            .sorted { ($0.1, $0.0.fetchedAt) > ($1.1, $1.0.fetchedAt) }
            .map(\.0)
            .prefix(limit))
    }
}

extension JobFilter {
    /// Local equivalent of the server's list filter, so lists work offline.
    /// `description` (posting text, if cached) is searched like the server's `q`.
    public func matches(_ job: JobSummary, description: String? = nil, now: Date = .now) -> Bool {
        switch status {
        case .all: break
        case .active: if job.status == .absage || job.status == .zuWeit { return false }
        case .only(let s): if job.status != s { return false }
        }
        if minScore > 0 && job.score < minScore { return false }
        if let source, !source.isEmpty, job.source != source, !job.alsoSeenOn.contains(source) { return false }
        if let sinceDays, sinceDays > 0 {
            guard let fetched = job.fetchedDate,
                  fetched >= now.addingTimeInterval(-Double(sinceDays) * 86_400) else { return false }
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let hay = [job.title, job.company ?? "", job.location ?? "", description ?? ""]
            if !hay.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return false }
        }
        return true
    }
}
