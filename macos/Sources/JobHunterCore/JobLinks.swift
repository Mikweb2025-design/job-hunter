import Foundation

/// Working links for a job. Job-alert mails (StepStone) only carry tracking redirects
/// (`click.stepstone.de/…`) that often stop working outside the mail – so we offer links that
/// always work: a StepStone search for title + company, a web search and the company's careers page.
public struct JobLink: Sendable, Hashable, Identifiable {
    public var id: String { url.absoluteString }
    public var title: String
    public var url: URL
    public var symbol: String
}

public enum JobLinks {
    /// Hosts of e-mail tracking redirects (no stable job page).
    static let trackingHosts = ["click.stepstone.de", "email.stepstone.de", "jobagent.stepstone.de"]

    public static func isTracking(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return trackingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "IT User Support Specialist" → "it-user-support-specialist" (StepStone URL slug).
    public static func slug(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] { t = t.replacingOccurrences(of: a, with: b) }
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)   // (m/w/d)
        t = t.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return t.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func city(_ location: String?) -> String? {
        guard let l = location?.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespaces),
              !l.isEmpty else { return nil }
        return l.replacingOccurrences(of: "^\\d{5}\\s*", with: "", options: .regularExpression)
    }

    static func search(_ query: String) -> URL? {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query)]
        return c.url
    }

    public static func stepStoneSearch(title: String, company: String?, location: String?) -> URL? {
        let keywords = slug([title, company ?? ""].joined(separator: " "))
        guard !keywords.isEmpty else { return nil }
        var s = "https://www.stepstone.de/jobs/\(keywords)"
        if let c = city(location).map(slug), !c.isEmpty { s += "/in-\(c)" }
        return URL(string: s)
    }

    /// Best link for "Jetzt manuell bewerben": the original link, unless it is a tracking redirect.
    public static func applyLink(for job: JobSummary) -> URL? {
        if let l = job.link, !isTracking(l) { return l }
        if job.source == "stepstone-alert" || isTracking(job.link) {
            return stepStoneSearch(title: job.title, company: job.company, location: job.location) ?? job.link
        }
        return job.link
    }

    /// Alternatives shown under "Weitere Links".
    public static func alternatives(for job: JobSummary) -> [JobLink] {
        var out: [JobLink] = []
        let company = job.company ?? ""
        if job.source == "stepstone-alert" || isTracking(job.link),
           let u = stepStoneSearch(title: job.title, company: job.company, location: job.location) {
            out.append(JobLink(title: "Auf StepStone suchen", url: u, symbol: "magnifyingglass"))
        }
        if let u = search("\"\(job.title)\" \(company) Stellenanzeige") {
            out.append(JobLink(title: "Im Web suchen (Titel + Firma)", url: u, symbol: "globe"))
        }
        if !company.isEmpty, let u = search("\(company) Karriere \(job.title)") {
            out.append(JobLink(title: "Karriereseite der Firma suchen", url: u, symbol: "building.2"))
        }
        if let l = job.link, isTracking(l) {
            out.append(JobLink(title: "Link aus der E-Mail (Tracking, evtl. abgelaufen)", url: l, symbol: "envelope"))
        }
        return out
    }
}
