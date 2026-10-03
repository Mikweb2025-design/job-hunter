import Foundation

// MARK: - Status

/// Tracker status as used by the server (`jobhunter.models.STATUSES`).
public enum JobStatus: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case neu, interessant, beworben, gespraech, absage, angebot

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .neu: "Neu"
        case .interessant: "Interessant"
        case .beworben: "Beworben"
        case .gespraech: "Gespräch"
        case .absage: "Absage"
        case .angebot: "Angebot"
        }
    }

    public var symbolName: String {
        switch self {
        case .neu: "sparkles"
        case .interessant: "star"
        case .beworben: "paperplane"
        case .gespraech: "person.2"
        case .absage: "xmark.circle"
        case .angebot: "checkmark.seal"
        }
    }

    /// Unknown values (newer server) fall back to `.neu` instead of failing the whole list.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawValue: raw) ?? .neu
    }
}

// MARK: - Jobs

/// One row of `GET /api/v1/jobs` (no posting text / letter, to keep the list light).
public struct JobSummary: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var title: String
    public var company: String?
    public var location: String?
    public var url: String?
    public var source: String
    public var published: String?
    public var fetchedAt: String
    public var score: Int
    public var ruleScore: Int?
    public var llmScore: Int?
    public var status: JobStatus
    public var statusUpdatedAt: String?
    public var appliedDate: String?
    public var salaryMin: Double?
    public var salaryMax: Double?
    public var letterOrigin: String?
    public var remote: Bool
    public var salaryPredicted: Bool
    public var alsoSeenOn: [String]
    public var hasLetter: Bool
    // E-mail applications (newer servers; optional so older servers still decode).
    public var applyEmail: String?
    public var applyMethod: String?
    public var sendApproved: Bool?
    public var sendState: SendStateInfo?

    public var fetchedDate: Date? { ServerDate.parse(fetchedAt) }
    public var link: URL? { url.flatMap { URL(string: $0) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased()) ? $0 : nil } }

    public var companyAndLocation: String {
        [company, location].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    public var salaryText: String? {
        SalaryFormatter.text(min: salaryMin, max: salaryMax, predicted: salaryPredicted)
    }
}

public struct ScoreBreakdown: Codable, Sendable, Hashable {
    public static let maxKeywords = 40.0
    public static let maxTitle = 25.0
    public static let maxLocation = 15.0
    public static let maxSalary = 20.0

    public var keywords: Double
    public var matched: [String]
    public var title: Double
    public var titleMatch: String?
    public var location: Double
    public var locationReason: String?
    public var salary: Double
    public var salaryReason: String?
    public var penalty: Double
    public var excludedInText: [String]
    public var excluded: [String]

    public var isExcluded: Bool { !excluded.isEmpty }
}

/// `GET /api/v1/jobs/{id}`: summary fields plus posting text, breakdown, reason, letter, notes.
public struct JobDetail: Codable, Sendable, Identifiable, Hashable {
    public var summary: JobSummary
    public var description: String
    public var scoreBreakdown: ScoreBreakdown
    public var reason: String?
    public var letter: String
    public var letterUpdatedAt: String?
    public var notes: String
    public var applyEmailSource: String?

    public var id: Int { summary.id }

    private enum CodingKeys: String, CodingKey {
        case description, scoreBreakdown, reason, letter, letterUpdatedAt, notes, applyEmailSource
    }

    public init(from decoder: Decoder) throws {
        summary = try JobSummary(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        scoreBreakdown = try c.decode(ScoreBreakdown.self, forKey: .scoreBreakdown)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        letter = try c.decodeIfPresent(String.self, forKey: .letter) ?? ""
        letterUpdatedAt = try c.decodeIfPresent(String.self, forKey: .letterUpdatedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        applyEmailSource = try c.decodeIfPresent(String.self, forKey: .applyEmailSource)
    }

    public func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(description, forKey: .description)
        try c.encode(scoreBreakdown, forKey: .scoreBreakdown)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encode(letter, forKey: .letter)
        try c.encodeIfPresent(letterUpdatedAt, forKey: .letterUpdatedAt)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(applyEmailSource, forKey: .applyEmailSource)
    }

    /// True for the fixed template draft (server marks it "vorlage"; contains `[...]` gaps).
    public var letterIsTemplate: Bool { summary.letterOrigin == "vorlage" }
}

public struct JobList: Decodable, Sendable {
    public var count: Int
    public var items: [JobSummary]
}

// MARK: - Stats / health / run

public struct LastRun: Codable, Sendable, Hashable {
    public var id: Int
    public var startedAt: String
    public var finishedAt: String?
    public var newJobs: Int
    public var errors: [String]
}

public struct Stats: Codable, Sendable, Hashable {
    public var total: Int
    public var byStatus: [String: Int]
    public var sources: [String]
    public var running: Bool
    public var newSinceLastRun: Int
    public var newSinceLastRunAboveThreshold: Int
    public var threshold: Int
    public var lastRun: LastRun?

    public func count(_ status: JobStatus) -> Int { byStatus[status.rawValue] ?? 0 }
}

public struct Health: Decodable, Sendable, Hashable {
    public var ok: Bool
    public var apiVersion: Int
    public var running: Bool
    public var llmEnabled: Bool
    public var llm: String?
    public var serverTime: String
}

public struct RunResponse: Decodable, Sendable, Hashable {
    public var started: Bool
    public var running: Bool
}

// MARK: - Requests

/// Partial tracker update for `PATCH /api/v1/jobs/{id}`. `nil` fields are not sent.
public struct JobUpdate: Encodable, Sendable, Equatable {
    public enum AppliedDate: Sendable, Equatable {
        case set(String)  // "YYYY-MM-DD"
        case clear
    }

    public var status: JobStatus?
    public var notes: String?
    public var appliedDate: AppliedDate?
    /// Recipient for e-mail applications; "" = none (apply manually).
    public var applyEmail: String?

    public init(status: JobStatus? = nil, notes: String? = nil, appliedDate: AppliedDate? = nil,
                applyEmail: String? = nil) {
        self.status = status
        self.notes = notes
        self.appliedDate = appliedDate
        self.applyEmail = applyEmail
    }

    private enum CodingKeys: String, CodingKey {
        case status, notes
        case appliedDate = "applied_date"
        case applyEmail = "apply_email"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(status?.rawValue, forKey: .status)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(applyEmail, forKey: .applyEmail)
        switch appliedDate {
        case .set(let day): try c.encode(day, forKey: .appliedDate)
        case .clear: try c.encodeNil(forKey: .appliedDate)
        case nil: break
        }
    }
}

/// List filters, mirrored from the dashboard.
public struct JobFilter: Sendable, Equatable, Hashable {
    public enum StatusFilter: Sendable, Hashable {
        case all, active, only(JobStatus)
    }

    public var status: StatusFilter = .active
    public var minScore: Int = 0
    public var source: String? = nil
    public var sinceDays: Int? = nil
    public var query: String = ""

    public init(status: StatusFilter = .active, minScore: Int = 0, source: String? = nil,
                sinceDays: Int? = nil, query: String = "") {
        self.status = status
        self.minScore = minScore
        self.source = source
        self.sinceDays = sinceDays
        self.query = query
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        switch status {
        case .all: break
        case .active: items.append(URLQueryItem(name: "status", value: "aktiv"))
        case .only(let s): items.append(URLQueryItem(name: "status", value: s.rawValue))
        }
        if minScore > 0 { items.append(URLQueryItem(name: "min_score", value: String(minScore))) }
        if let source, !source.isEmpty { items.append(URLQueryItem(name: "source", value: source)) }
        if let sinceDays, sinceDays > 0 { items.append(URLQueryItem(name: "since", value: String(sinceDays))) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        return items
    }
}

// MARK: - Helpers

public enum ServerDate {
    // ISO8601DateFormatter is documented thread-safe.
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let dayOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        f.timeZone = TimeZone(identifier: "Europe/Berlin")
        return f
    }()

    /// Parses the server's timestamps: `2026-10-03T06:30:00+00:00`, with microseconds, or `2026-10-03`.
    public static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let d = plain.date(from: value) ?? fractional.date(from: value) { return d }
        // Python emits microseconds (6 digits); trim to milliseconds for Foundation.
        if let dot = value.firstIndex(of: "."), let tz = value[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = value[value.index(after: dot)..<tz].prefix(3)
            if let d = fractional.date(from: String(value[..<dot]) + "." + frac + String(value[tz...])) { return d }
        }
        return dayOnly.date(from: String(value.prefix(10)))
    }

    /// `YYYY-MM-DD` for `applied_date`.
    public static func dayString(_ date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

public enum SalaryFormatter {
    public static func text(min: Double?, max: Double?, predicted: Bool) -> String? {
        func eur(_ v: Double) -> String {
            v.formatted(.number.precision(.fractionLength(0)).locale(Locale(identifier: "de_DE"))) + " €"
        }
        let value: String
        switch (min, max) {
        case let (lo?, hi?) where lo != hi: value = "\(eur(lo)) – \(eur(hi))"
        case let (lo?, _): value = eur(lo)
        case let (nil, hi?): value = eur(hi)
        default: return nil
        }
        return predicted ? "\(value) (geschätzt)" : value
    }
}
