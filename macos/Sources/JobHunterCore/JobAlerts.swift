import Foundation

// Jobs from job-alert e-mails (LinkedIn, StepStone, Indeed).
//
// The job boards have no public jobs API and their terms forbid bots/scraping, so nothing here
// ever requests a job-board page. The app only reads the alert e-mails the user already
// receives in Apple Mail (read-only, see `AppleMailAlertReader`), extracts title / company /
// location / link and posts them to the server (`POST /api/v1/jobs/import`).

// MARK: - Models

/// Board an alert e-mail comes from; the raw value is the server's `source`.
public enum AlertSource: String, Codable, Sendable, CaseIterable {
    case linkedin = "linkedin-alert"
    case stepstone = "stepstone-alert"
    case indeed = "indeed-alert"

    public var label: String {
        switch self {
        case .linkedin: "LinkedIn (Job-Alert)"
        case .stepstone: "StepStone (Job-Alert)"
        case .indeed: "Indeed (Job-Alert)"
        }
    }

    /// Sender addresses (substring match) whose messages are read. LinkedIn: only the job
    /// e-mails, not invitations/notifications.
    public static let senderPatterns = [
        "jobalerts-noreply@linkedin.com", "jobs-noreply@linkedin.com", "jobs-listings@linkedin.com",
        "stepstone.de", "indeed.com",
    ]

    public static func from(sender: String) -> AlertSource? {
        let s = sender.lowercased()
        if s.contains("linkedin.com") { return .linkedin }
        if s.contains("stepstone.de") { return .stepstone }
        if s.contains("indeed.com") { return .indeed }
        return nil
    }
}

/// One job found in an alert e-mail (the body of `POST /api/v1/jobs/import`).
public struct AlertJob: Codable, Sendable, Hashable {
    public var source: String
    public var externalId: String
    public var title: String
    public var company: String
    public var location: String
    public var url: String
    /// ISO-8601 time the e-mail was received.
    public var receivedAt: String
    public var description: String?

    public init(source: AlertSource, externalId: String, title: String, company: String, location: String,
                url: String, receivedAt: Date, description: String? = nil) {
        self.source = source.rawValue
        self.externalId = externalId
        self.title = title
        self.company = company
        self.location = location
        self.url = url
        self.receivedAt = ISO8601DateFormatter().string(from: receivedAt)
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case source, title, company, location, url, description
        case externalId = "external_id"
        case receivedAt = "received_at"
    }

    var key: String { "\(source)|\(externalId)" }
}

/// One alert e-mail as read from Mail.
public struct AlertMailMessage: Sendable, Equatable {
    /// RFC Message-ID (stable across mailboxes) – used to remember processed messages.
    public var id: String
    public var receivedAt: Date
    public var sender: String
    public var subject: String
    /// Raw RFC 822 source.
    public var source: String

    public init(id: String, receivedAt: Date, sender: String, subject: String, source: String) {
        self.id = id
        self.receivedAt = receivedAt
        self.sender = sender
        self.subject = subject
        self.source = source
    }
}

/// Response of `POST /api/v1/jobs/import`.
public struct ImportResult: Decodable, Sendable, Equatable {
    public var received: Int
    public var imported: Int
    public var duplicates: Int
    public var invalid: Int
    public var importedIds: [Int]
    public var duplicateIds: [Int]
}

// MARK: - MIME (just enough for alert e-mails)

public enum MIMEText {
    /// First text/plain and text/html body of a raw message (multipart, quoted-printable,
    /// base64, UTF-8 / ISO-8859-1 / Windows-1252).
    public static func bodies(of raw: String) -> (plain: String?, html: String?) {
        var plain: String?, html: String?
        walk(raw.replacingOccurrences(of: "\r\n", with: "\n"), plain: &plain, html: &html, depth: 0)
        return (plain, html)
    }

    private static func walk(_ entity: String, plain: inout String?, html: inout String?, depth: Int) {
        guard depth < 8 else { return }
        let (headers, body) = split(entity)
        let ctype = headers["content-type"] ?? "text/plain"
        let mime = ctype.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
        if mime.hasPrefix("multipart/"), let boundary = param("boundary", in: ctype) {
            for part in parts(body, boundary: boundary) {
                walk(part, plain: &plain, html: &html, depth: depth + 1)
            }
            return
        }
        guard mime == "text/plain" || mime == "text/html" else { return }
        let cte = (headers["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let bytes: Data
        switch cte {
        case "quoted-printable": bytes = quotedPrintable(body)
        case "base64": bytes = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data()
        default: bytes = Data(body.utf8)
        }
        let text = decode(bytes, charset: param("charset", in: ctype))
        if mime == "text/plain", plain == nil { plain = text }
        if mime == "text/html", html == nil { html = text }
    }

    static func split(_ entity: String) -> ([String: String], String) {
        let range = entity.range(of: "\n\n")
        let head = range.map { String(entity[..<$0.lowerBound]) } ?? entity
        let body = range.map { String(entity[$0.upperBound...]) } ?? ""
        var headers: [String: String] = [:]
        var lastKey: String?
        for line in head.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let k = lastKey {
                headers[k, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if headers[k] == nil { headers[k] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                lastKey = k
            }
        }
        return (headers, body)
    }

    static func param(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let kv = piece.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { continue }
            return kv[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func parts(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var out: [String] = []
        var current: [Substring]?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == delimiter || trimmed == delimiter + "--" {
                if let current { out.append(current.joined(separator: "\n")) }
                current = trimmed == delimiter ? [] : nil
                if trimmed != delimiter { break }
            } else if current != nil {
                current?.append(line)
            }
        }
        return out
    }

    static func quotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.replacingOccurrences(of: "=\n", with: "").utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: b - 48
            case 65...70: b - 55
            case 97...102: b - 87
            default: nil
            }
        }
        while i < bytes.count {
            if bytes[i] == 61, i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    static func decode(_ data: Data, charset: String?) -> String {
        switch (charset ?? "utf-8").lowercased() {
        case "iso-8859-1", "latin1", "iso-8859-15":
            return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }
    }
}

// MARK: - HTML helpers

enum HTMLText {
    /// Visible text of an HTML fragment, one line per block element.
    static func text(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(style|script|head)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(br|/p|/div|/tr|/td|/li|/h\\d|/table|/a)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return entities(s)
    }

    static func entities(_ s: String) -> String {
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&nbsp;": " ", "&auml;": "ä", "&ouml;": "ö", "&uuml;": "ü", "&Auml;": "Ä", "&Ouml;": "Ö",
                     "&Uuml;": "Ü", "&szlig;": "ß", "&middot;": "·", "&ndash;": "–", "&mdash;": "—", "&euro;": "€"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // Numeric entities (&#228; &#xE4;)
        let regex = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let num = UInt32(ns.substring(with: m.range(at: 2)), radix: isHex ? 16 : 10)
            result += num.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    /// Non-empty, trimmed lines (also drops invisible padding characters LinkedIn uses).
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map(clean)
            .filter { !$0.isEmpty }
    }

    static func clean(_ s: some StringProtocol) -> String {
        let invisible = CharacterSet(charactersIn: "\u{034F}\u{200B}\u{200C}\u{200D}\u{FEFF}\u{00AD}\u{FFFC}")
        let filtered = String(String.UnicodeScalarView(s.unicodeScalars.filter { !invisible.contains($0) }))
        return filtered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Anchor {
        var href: String
        var text: String
        /// Offset (UTF-16) just after `</a>`.
        var end: Int
    }

    static func anchors(_ html: String) -> [Anchor] {
        let regex = try! NSRegularExpression(pattern: "<a\\b[^>]*?href\\s*=\\s*\"([^\"]*)\"[^>]*>([\\s\\S]*?)</a>",
                                             options: [.caseInsensitive])
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
            Anchor(href: entities(ns.substring(with: m.range(at: 1))),
                   text: clean(text(ns.substring(with: m.range(at: 2))).replacingOccurrences(of: "\n", with: " ")),
                   end: m.range.location + m.range.length)
        }
    }

    /// Text lines that follow position `offset` (max. `limit` UTF-16 units of HTML).
    static func linesAfter(_ html: String, offset: Int, limit: Int = 1500) -> [String] {
        let ns = html as NSString
        let len = min(limit, ns.length - offset)
        guard len > 0 else { return [] }
        return lines(text(ns.substring(with: NSRange(location: offset, length: len))))
    }
}

// MARK: - Parsers

public enum JobAlertParser {
    /// Jobs in one alert e-mail (empty for other mails from the same sender, e.g. "Willkommen").
    public static func parse(_ message: AlertMailMessage) -> [AlertJob] {
        guard let source = AlertSource.from(sender: message.sender) else { return [] }
        let (plain, html) = MIMEText.bodies(of: message.source)
        let jobs: [AlertJob]
        switch source {
        case .linkedin:
            let fromPlain = plain.map { linkedInPlain($0, receivedAt: message.receivedAt) } ?? []
            jobs = fromPlain.isEmpty ? (html.map { linkedInHTML($0, receivedAt: message.receivedAt) } ?? []) : fromPlain
        case .stepstone:
            jobs = html.map { stepStoneHTML($0, receivedAt: message.receivedAt) } ?? []
        case .indeed:
            jobs = html.map { indeedHTML($0, receivedAt: message.receivedAt) } ?? []
        }
        var seen = Set<String>()
        return jobs.filter { seen.insert($0.key).inserted }
    }

    // MARK: LinkedIn

    static let linkedInIDPattern = "/jobs/view/(?:[^/?#\"\\s]*?-)?(\\d{6,})"

    /// Canonical link without tracking parameters (and without the login token LinkedIn adds).
    public static func linkedInURL(id: String) -> String { "https://www.linkedin.com/jobs/view/\(id)/" }

    public static func linkedInID(in url: String) -> String? {
        guard let host = URLComponents(string: url)?.host?.lowercased(), host.hasSuffix("linkedin.com") else { return nil }
        return firstMatch(linkedInIDPattern, in: url)
    }

    /// Lines in LinkedIn alerts that are not title/company/location.
    static let linkedInNoise = try! NSRegularExpression(pattern: """
        (?ix)^(?:
          .*jobbenachrichtigung.* | .*benachrichtigen\\s+sie.* | .*job\\s*alert.* | \\d+\\+?\\s+neue\\s+jobs.* |
          \\d+\\+?\\s+new\\s+jobs.* | ihre\\s+aktuellen\\s+jobempfehlungen.* | alle\\s+jobs\\s+anzeigen.* | see\\s+all\\s+jobs.* |
          dieses\\s+unternehmen\\s+ist\\s+aktiv.* | aktiv\\s+auf\\s+personalsuche | actively\\s+(?:hiring|recruiting).* |
          schnellbewerbung | easy\\s+apply | mit\\s+lebenslauf.*bewerben | apply\\s+with\\s+.* | einfach\\s+bewerben | gesponsert | promoted | neu | new |
          \\d+\\s+(?:kontakt|kontakte|connection|connections|ehemalige|alumni).* | vor\\s+\\d+.* | \\d+\\s+\\w+\\s+ago |
          -{3,} | =+ | jobangebot\\s+ansehen.* | view\\s+job.*
        )$
        """)

    static func isLinkedInNoise(_ line: String) -> Bool {
        let ns = line as NSString
        return linkedInNoise.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Plain-text part: blocks "Title / Company / Location / … / Jobangebot ansehen: <url>".
    static func linkedInPlain(_ text: String, receivedAt: Date) -> [AlertJob] {
        let linkLine = try! NSRegularExpression(pattern: "^(?:Jobangebot ansehen|Job ansehen|Stelle ansehen|View job|Zum Jobangebot)\\s*:\\s*(\\S+)",
                                                options: .caseInsensitive)
        var jobs: [AlertJob] = []
        var block: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = HTMLText.clean(raw)
            let ns = line as NSString
            if let m = linkLine.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let url = ns.substring(with: m.range(at: 1))
                let fields = block.filter { !isLinkedInNoise($0) }
                block = []
                guard let id = linkedInID(in: url), let title = fields.first else { continue }
                var company = fields.count > 1 ? fields[1] : ""
                var location = fields.count > 2 ? fields[2] : ""
                if location.isEmpty, let dot = company.range(of: " · ") {
                    location = String(company[dot.upperBound...])
                    company = String(company[..<dot.lowerBound])
                }
                jobs.append(AlertJob(source: .linkedin, externalId: id, title: title, company: company,
                                     location: location, url: linkedInURL(id: id), receivedAt: receivedAt))
            } else if line.hasPrefix("---") {
                block = []
            } else if !line.isEmpty {
                block.append(line)
            }
        }
        return jobs
    }

    /// HTML part: `<a href=".../jobs/view/<id>">Title</a>` followed by "Company · Location".
    static func linkedInHTML(_ html: String, receivedAt: Date) -> [AlertJob] {
        var jobs: [AlertJob] = []
        for a in HTMLText.anchors(html) {
            guard let id = linkedInID(in: a.href), !a.text.isEmpty, !isLinkedInNoise(a.text) else { continue }
            let after = HTMLText.linesAfter(html, offset: a.end).filter { !isLinkedInNoise($0) }
            var company = "", location = ""
            if let first = after.first {
                let parts = first.components(separatedBy: " · ")
                company = parts[0]
                location = parts.count > 1 ? parts[1...].joined(separator: " · ") : (after.count > 1 ? after[1] : "")
            }
            jobs.append(AlertJob(source: .linkedin, externalId: id, title: a.text, company: company,
                                 location: location, url: linkedInURL(id: id), receivedAt: receivedAt))
        }
        return jobs
    }

    // MARK: StepStone (layout of their "Jobagent" e-mails; no real sample yet)

    static let stepStonePattern = "stepstone\\.de(/stellenangebote--[^?#\"\\s]*?--(\\d{5,})(?:-inline)?\\.html)"

    static func stepStoneHTML(_ html: String, receivedAt: Date) -> [AlertJob] {
        var jobs: [AlertJob] = []
        for a in HTMLText.anchors(html) {
            let href = a.href.removingPercentEncoding ?? a.href
            guard let path = firstMatch(stepStonePattern, in: href, group: 1),
                  let id = firstMatch(stepStonePattern, in: href, group: 2),
                  !a.text.isEmpty, a.text.count > 3 else { continue }
            let after = HTMLText.linesAfter(html, offset: a.end, limit: 1200)
                .filter { !$0.lowercased().hasPrefix("http") && $0 != a.text }
            jobs.append(AlertJob(source: .stepstone, externalId: id, title: a.text,
                                 company: after.first ?? "", location: after.count > 1 ? after[1] : "",
                                 url: "https://www.stepstone.de" + path, receivedAt: receivedAt))
        }
        return jobs
    }

    // MARK: Indeed (layout of their job-alert e-mails; no real sample yet)

    static func indeedHTML(_ html: String, receivedAt: Date) -> [AlertJob] {
        var jobs: [AlertJob] = []
        for a in HTMLText.anchors(html) {
            let href = a.href.removingPercentEncoding ?? a.href
            guard href.lowercased().contains("indeed.com"),
                  let jk = firstMatch("[?&](?:jk|vjk)=([0-9a-fA-F]{10,20})", in: href),
                  !a.text.isEmpty, a.text.count > 3 else { continue }
            let after = HTMLText.linesAfter(html, offset: a.end, limit: 1200)
                .filter { !$0.lowercased().hasPrefix("http") && $0 != a.text }
            jobs.append(AlertJob(source: .indeed, externalId: jk.lowercased(), title: a.text,
                                 company: after.first ?? "", location: after.count > 1 ? after[1] : "",
                                 url: "https://de.indeed.com/viewjob?jk=\(jk.lowercased())", receivedAt: receivedAt))
        }
        return jobs
    }

    static func firstMatch(_ pattern: String, in s: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }
}

// MARK: - Import state + run (Mail → parse → server, queued while offline)

/// Persisted per server in the app's data folder (job-alerts.json): processed messages,
/// jobs waiting for the server, last run.
public struct JobAlertState: Codable, Sendable, Equatable {
    /// Message-ID → when it was processed.
    public var processed: [String: Date] = [:]
    /// Parsed jobs not yet accepted by the server (offline queue).
    public var pending: [AlertJob] = []
    public var lastRun: Date?
    public var lastSummary: String?

    public init() {}
}

public protocol AlertMailReading: Sendable {
    /// Alert e-mails of the last `daysBack` days in the account's INBOX, except `skipIDs`.
    func alertMessages(account: String, daysBack: Int, skipIDs: [String]) async throws -> [AlertMailMessage]
}

public protocol JobImportAPI: Sendable {
    func importJobs(_ jobs: [AlertJob]) async throws -> ImportResult
}

public struct JobAlertOutcome: Sendable, Equatable {
    public var messages = 0
    public var jobsFound = 0
    public var imported = 0
    public var duplicates = 0
    public var invalid = 0
    public var queued = 0
    public var importedIDs: [Int] = []
    public var mailError: String?
    public var serverError: String?

    public init() {}

    public var summary: String {
        var parts: [String] = []
        if let mailError { parts.append("Mail nicht lesbar – \(mailError)") }
        parts.append(messages == 1 ? "1 neue Alert-Mail" : "\(messages) neue Alert-Mails")
        parts.append(jobsFound == 1 ? "1 Stelle gefunden" : "\(jobsFound) Stellen gefunden")
        parts.append("\(imported) neu importiert")
        if duplicates > 0 { parts.append("\(duplicates) schon bekannt") }
        if invalid > 0 { parts.append("\(invalid) ungültig") }
        if queued > 0 { parts.append("\(queued) warten auf den Server" + (serverError.map { " (\($0))" } ?? "")) }
        return parts.joined(separator: " · ")
    }
}

public enum JobAlertImporter {
    public static let batchSize = 200

    /// Reads new alert e-mails, parses them, queues the jobs and sends the queue to the server
    /// (`api == nil`: offline, only queue). Processed messages are remembered so they are never
    /// parsed twice; jobs stay queued until the server accepted them.
    public static func run(state: inout JobAlertState, reader: AlertMailReading, api: JobImportAPI?,
                           account: String, daysBack: Int, now: Date = .now) async -> JobAlertOutcome {
        var out = JobAlertOutcome()
        do {
            let messages = try await reader.alertMessages(account: account, daysBack: daysBack,
                                                         skipIDs: Array(state.processed.keys))
            var known = Set(state.pending.map(\.key))
            for msg in messages where state.processed[msg.id] == nil {
                out.messages += 1
                let jobs = JobAlertParser.parse(msg)
                out.jobsFound += jobs.count
                for job in jobs where known.insert(job.key).inserted {
                    state.pending.append(job)
                }
                state.processed[msg.id] = now
            }
        } catch {
            out.mailError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        await flush(state: &state, api: api, outcome: &out)
        // Forget processed ids long after they left the read window.
        let keep = now.addingTimeInterval(-Double(max(daysBack, 1) + 60) * 86_400)
        state.processed = state.processed.filter { $0.value >= keep }
        state.lastRun = now
        state.lastSummary = out.summary
        return out
    }

    /// Older server without `POST /jobs/import` (404, or 405 from `/jobs/{id}`): keep the queue.
    static func serverLacksImport(_ e: APIError) -> Bool {
        if e == .notFound { return true }
        if case .server(let status, _) = e, status == 405 { return true }
        return false
    }

    public static func flush(state: inout JobAlertState, api: JobImportAPI?, outcome out: inout JobAlertOutcome) async {
        guard let api else {
            out.queued = state.pending.count
            return
        }
        while !state.pending.isEmpty {
            let batch = Array(state.pending.prefix(batchSize))
            do {
                let r = try await api.importJobs(batch)
                out.imported += r.imported
                out.duplicates += r.duplicates
                out.invalid += r.invalid
                out.importedIDs += r.importedIds
                state.pending.removeFirst(batch.count)
            } catch {
                if let api = error as? APIError, serverLacksImport(api) {
                    out.serverError = "Server kennt den Job-Alert-Import noch nicht (Backend aktualisieren) – Stellen bleiben gespeichert"
                    break
                }
                if let api = error as? APIError, !SyncEngine.isTransient(api) {
                    // Rejected for good (e.g. 422): drop the batch instead of retrying forever.
                    out.serverError = api.errorDescription
                    out.invalid += batch.count
                    state.pending.removeFirst(batch.count)
                    continue
                }
                out.serverError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                break
            }
        }
        out.queued = state.pending.count
    }
}

extension LocalStore {
    var alertsURL: URL { directory.appending(path: "job-alerts.json") }

    public func loadAlertState() -> JobAlertState {
        guard let data = try? Data(contentsOf: alertsURL),
              let s = try? Self.decoder.decode(JobAlertState.self, from: data) else { return JobAlertState() }
        return s
    }

    public func saveAlertState(_ state: JobAlertState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(state).write(to: alertsURL, options: [.atomic])
    }
}
