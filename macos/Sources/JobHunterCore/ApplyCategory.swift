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
    /// Rejected / put aside (status absage).
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
        case .absage: return .later
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

    /// "Heute zu tun": open manual jobs, best score first.
    public static func todayManual(_ jobs: [JobSummary], blocklist: [String] = [], limit: Int = 10) -> [JobSummary] {
        Array(jobs.filter { of($0, blocklist: blocklist) == .manual }
            .sorted { ($0.score, $0.fetchedAt) > ($1.score, $1.fetchedAt) }
            .prefix(limit))
    }
}

extension JobFilter {
    /// Local equivalent of the server's list filter, so lists work offline.
    /// `description` (posting text, if cached) is searched like the server's `q`.
    public func matches(_ job: JobSummary, description: String? = nil, now: Date = .now) -> Bool {
        switch status {
        case .all: break
        case .active: if job.status == .absage { return false }
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
