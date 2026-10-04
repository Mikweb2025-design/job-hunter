import Foundation

// "Suchprofil & Profil": editable search profile, job sources and CV profile on the server
// (`/api/v1/search-profile`, `/cv-profile`, …). Online only – nothing is queued offline.
// Decoded with a plain JSONDecoder and explicit snake_case keys: keyword weights and source
// options are dictionaries whose keys must not be converted.

/// The editable fields of `search:` (config.yaml + override from the app/dashboard).
public struct SearchProfileData: Codable, Equatable, Sendable {
    public var queries: [String]
    public var location: String
    public var radiusKm: Int
    public var remoteOk: Bool
    public var daysBack: Int
    public var minSalary: Int
    public var targetTitles: [String]
    public var excludedTitleKeywords: [String]
    public var excludedKeywords: [String]
    public var keywordWeights: [String: Double]
    public var keywordSaturation: Double
    public var extraLocations: [String]

    enum CodingKeys: String, CodingKey {
        case queries, location
        case radiusKm = "radius_km", remoteOk = "remote_ok", daysBack = "days_back", minSalary = "min_salary"
        case targetTitles = "target_titles", excludedTitleKeywords = "excluded_title_keywords"
        case excludedKeywords = "excluded_keywords", keywordWeights = "keyword_weights"
        case keywordSaturation = "keyword_saturation", extraLocations = "extra_locations"
    }

    public init(queries: [String] = [], location: String = "Berlin", radiusKm: Int = 30, remoteOk: Bool = true,
                daysBack: Int = 7, minSalary: Int = 44000, targetTitles: [String] = [],
                excludedTitleKeywords: [String] = [], excludedKeywords: [String] = [],
                keywordWeights: [String: Double] = [:], keywordSaturation: Double = 15, extraLocations: [String] = []) {
        self.queries = queries; self.location = location; self.radiusKm = radiusKm; self.remoteOk = remoteOk
        self.daysBack = daysBack; self.minSalary = minSalary; self.targetTitles = targetTitles
        self.excludedTitleKeywords = excludedTitleKeywords; self.excludedKeywords = excludedKeywords
        self.keywordWeights = keywordWeights; self.keywordSaturation = keywordSaturation
        self.extraLocations = extraLocations
    }

    /// Same checks as the server (jobhunter/search_profile.py) for instant feedback; the server
    /// validates again. Returns German messages, empty = ok.
    public func validationErrors() -> [String] {
        var out: [String] = []
        let q = queries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if q.isEmpty { out.append("Mindestens ein Suchbegriff nötig.") }
        if q.count > SearchProfileData.maxQueries { out.append("Höchstens \(SearchProfileData.maxQueries) Suchbegriffe.") }
        if location.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Ort darf nicht leer sein.") }
        if !(0...200).contains(radiusKm) { out.append("Umkreis 0–200 km.") }
        if !(1...100).contains(daysBack) { out.append("Zeitraum 1–100 Tage.") }
        if !(0...300_000).contains(minSalary) { out.append("Mindestgehalt 0–300.000 €.") }
        if keywordWeights.values.contains(where: { !(0...10).contains($0) }) { out.append("Keyword-Gewichte 0–10.") }
        if !(1...100).contains(keywordSaturation) { out.append("Sättigung 1–100.") }
        return out
    }

    public static let maxQueries = 30
}

/// One company feed (`sources.ats.companies`).
public struct ATSCompany: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var ats: String
    public var token: String
    public var name: String
    public var enabled: Bool

    public var id: String { "\(ats):\(token.lowercased())" }

    public init(ats: String, token: String, name: String = "", enabled: Bool = true) {
        self.ats = ats; self.token = token; self.name = name.isEmpty ? token : name; self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case ats, token, name, enabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ats = try c.decode(String.self, forKey: .ats)
        token = try c.decode(String.self, forKey: .token)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? token
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct FeedEntry: Codable, Equatable, Hashable, Sendable {
    public var url: String
    public var name: String?
    public init(url: String, name: String? = nil) { self.url = url; self.name = name }
}

/// Per-source options the UI may change. Only the options a source has are sent.
public struct SourceOptions: Codable, Equatable, Sendable {
    public var maxPages: Int?
    public var remoteSearch: Bool?
    public var category: String?
    public var geo: String?
    public var companies: [ATSCompany]?
    public var feeds: [FeedEntry]?

    enum CodingKeys: String, CodingKey {
        case maxPages = "max_pages", remoteSearch = "remote_search", category, geo, companies, feeds
    }

    public init(maxPages: Int? = nil, remoteSearch: Bool? = nil, category: String? = nil, geo: String? = nil,
                companies: [ATSCompany]? = nil, feeds: [FeedEntry]? = nil) {
        self.maxPages = maxPages; self.remoteSearch = remoteSearch; self.category = category; self.geo = geo
        self.companies = companies; self.feeds = feeds
    }
}

/// A string/number/bool in `option_types` (e.g. ["int", 1, 5] or ["choice", "", "devops"]).
public enum JSONScalar: Decodable, Equatable, Sendable {
    case string(String), int(Int), bool(Bool)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string(try c.decode(String.self)) }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int? { if case .int(let i) = self { i } else { nil } }
}

public struct SourceSetting: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var kind: String
    public var info: String
    public var url: String?
    public var enabled: Bool
    public var configured: Bool
    public var reason: String?
    public var options: SourceOptions
    public var optionTypes: [String: [JSONScalar]]

    enum CodingKeys: String, CodingKey {
        case id, label, kind, info, url, enabled, configured, reason, options
        case optionTypes = "option_types"
    }

    public func hasOption(_ key: String) -> Bool { optionTypes[key] != nil }

    /// Allowed values of a "choice" option ("" = alle).
    public func choices(_ key: String) -> [String] {
        guard let t = optionTypes[key], t.first?.string == "choice" else { return [] }
        return t.dropFirst().compactMap(\.string)
    }

    /// Range of an "int" option.
    public func intRange(_ key: String) -> ClosedRange<Int>? {
        guard let t = optionTypes[key], t.first?.string == "int", t.count >= 3,
              let lo = t[1].int, let hi = t[2].int, lo <= hi else { return nil }
        return lo...hi
    }
}

public struct RescoreStatus: Decodable, Equatable, Sendable {
    public var busy: Bool
    public var done: Int?
    public var finishedAt: String?
    public var error: String?

    enum CodingKeys: String, CodingKey { case busy, done, error, finishedAt = "finished_at" }
}

public struct SearchProfilePayload: Decodable, Equatable, Sendable {
    public var profile: SearchProfileData
    public var base: SearchProfileData
    public var overridden: [String]
    public var sources: [SourceSetting]
    public var atsExamples: [ATSCompany]
    public var atsTypes: [String: String]
    public var updatedAt: String?
    public var rescore: RescoreStatus?
    public var rescoreStarted: Bool?
    public var runStarted: Bool?

    enum CodingKeys: String, CodingKey {
        case profile, base, overridden, sources, rescore
        case atsExamples = "ats_examples", atsTypes = "ats_types", updatedAt = "updated_at"
        case rescoreStarted = "rescore_started", runStarted = "run_started"
    }
}

/// Body of `PUT /search-profile` (and, without run_now/rescore, of the preview).
public struct SearchProfileUpdate: Encodable, Equatable, Sendable {
    public struct SourceChange: Encodable, Equatable, Sendable {
        public var enabled: Bool
        public var options: SourceOptions

        public init(enabled: Bool, options: SourceOptions) { self.enabled = enabled; self.options = options }

        enum CodingKeys: String, CodingKey { case enabled }

        public func encode(to encoder: any Encoder) throws {
            try options.encode(to: encoder)  // options flat next to "enabled", nil options omitted
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
        }
    }

    public var profile: SearchProfileData?
    public var sources: [String: SourceChange]?
    public var runNow: Bool
    public var rescore: Bool

    public init(profile: SearchProfileData?, sources: [String: SourceChange]? = nil, runNow: Bool = false,
                rescore: Bool = true) {
        self.profile = profile
        self.sources = sources?.isEmpty == true ? nil : sources
        self.runNow = runNow
        self.rescore = rescore
    }

    enum CodingKeys: String, CodingKey { case profile, sources, runNow = "run_now", rescore }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(profile, forKey: .profile)
        try c.encodeIfPresent(sources, forKey: .sources)
        try c.encode(runNow, forKey: .runNow)
        try c.encode(rescore, forKey: .rescore)
    }

    /// Preview body: only profile + sources.
    public var previewBody: [String: AnyEncodable] {
        var out: [String: AnyEncodable] = [:]
        if let profile { out["profile"] = AnyEncodable(profile) }
        if let sources { out["sources"] = AnyEncodable(sources) }
        return out
    }
}

public struct AnyEncodable: Encodable, Sendable {
    private let encodeFn: @Sendable (any Encoder) throws -> Void
    public init<T: Encodable & Sendable>(_ value: T) { encodeFn = { try value.encode(to: $0) } }
    public func encode(to encoder: any Encoder) throws { try encodeFn(encoder) }
}

public struct PreviewSample: Decodable, Equatable, Sendable, Hashable {
    public var title: String
    public var company: String
    public var location: String
}

public struct PreviewBA: Decodable, Equatable, Sendable {
    public var local: Int
    public var remote: Int
    public var newInPage: Int
    public var pageSize: Int
    public var remoteScanned: Int?

    enum CodingKeys: String, CodingKey {
        case local, remote, newInPage = "new_in_page", pageSize = "page_size", remoteScanned = "remote_scanned"
    }
}

public struct PreviewQuery: Decodable, Equatable, Sendable, Identifiable {
    public var query: String
    public var arbeitsagentur: PreviewBA?
    public var feeds: [String: Int]
    public var samples: [PreviewSample]?
    public var error: String?
    public var total: Int

    public var id: String { query }
}

public struct PreviewSource: Decodable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var fetched: Int?
    public var matching: Int?
    public var new: Int?
    public var samples: [PreviewSample]?
    public var error: String?
}

public struct SearchPreview: Decodable, Equatable, Sendable {
    public var queries: [PreviewQuery]
    public var sources: [PreviewSource]
    public var cached: Bool
    public var generatedAt: String?

    enum CodingKeys: String, CodingKey { case queries, sources, cached, generatedAt = "generated_at" }
}

public struct ProfileSuggestion: Decodable, Equatable, Sendable, Identifiable, Hashable {
    public var value: String
    public var kind: String      // query | title
    public var reason: String
    public var weight: Double

    public var id: String { "\(kind):\(value)" }
}

public struct ProfileSuggestions: Decodable, Equatable, Sendable {
    public var queries: [ProfileSuggestion]
    public var titles: [ProfileSuggestion]
    public var likedJobs: Int

    enum CodingKeys: String, CodingKey { case queries, titles, likedJobs = "liked_jobs" }
}

public struct CVProfileData: Decodable, Equatable, Sendable {
    public var text: String
    public var path: String
    public var savedAt: String?
    public var keywords: Int
    public var results: Int
    public var backups: [String]
    public var warning: String
    public var maxLength: Int
    public var backup: String?
    public var rescoreStarted: Bool?

    enum CodingKeys: String, CodingKey {
        case text, path, keywords, results, backups, warning, backup
        case savedAt = "saved_at", maxLength = "max_length", rescoreStarted = "rescore_started"
    }
}

/// Adds a value to a chip list: trimmed, collapsed whitespace, no case-insensitive duplicates.
/// Returns false if nothing was added.
@discardableResult
public func addUnique(_ value: String, to list: inout [String]) -> Bool {
    let v = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !v.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return false }
    list.append(v)
    return true
}

extension APIClient {
    /// Plain decoder: keys are mapped explicitly (dictionary keys stay as they are).
    static let plainDecoder = JSONDecoder()

    public func searchProfile() async throws -> SearchProfilePayload {
        try await send("GET", "search-profile", decoder: Self.plainDecoder)
    }

    public func saveSearchProfile(_ update: SearchProfileUpdate) async throws -> SearchProfilePayload {
        try await send("PUT", "search-profile", body: try Self.encoder.encode(update), decoder: Self.plainDecoder)
    }

    public func resetSearchProfile(what: String = "all") async throws -> SearchProfilePayload {
        try await send("POST", "search-profile/reset", body: try Self.encoder.encode(["what": what]),
                       decoder: Self.plainDecoder)
    }

    /// Runs the searches without saving (server: max. 1 at a time → 429, cached 10 min).
    public func previewSearchProfile(_ update: SearchProfileUpdate) async throws -> SearchPreview {
        try await send("POST", "search-profile/preview", body: try Self.encoder.encode(update.previewBody),
                       decoder: Self.plainDecoder)
    }

    public func profileSuggestions() async throws -> ProfileSuggestions {
        try await send("GET", "search-profile/suggestions", decoder: Self.plainDecoder)
    }

    public func cvProfile() async throws -> CVProfileData {
        try await send("GET", "cv-profile", decoder: Self.plainDecoder)
    }

    public func saveCVProfile(text: String, rescore: Bool = true) async throws -> CVProfileData {
        struct Body: Encodable { let text: String; let rescore: Bool }
        return try await send("PUT", "cv-profile", body: try Self.encoder.encode(Body(text: text, rescore: rescore)),
                              decoder: Self.plainDecoder)
    }

    public func rescore() async throws -> RescoreStatus {
        try await send("POST", "rescore", body: Data("{}".utf8), decoder: Self.plainDecoder)
    }
}
