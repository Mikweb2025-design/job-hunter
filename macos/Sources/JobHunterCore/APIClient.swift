import Foundation

public struct ServerConfig: Sendable, Equatable {
    public var baseURL: URL
    public var username: String
    public var password: String

    public init(baseURL: URL, username: String, password: String) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    /// Validates user input like "jobs.example.org" or "http://localhost:8000/".
    public static func normalizedURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host(), !host.isEmpty else { return nil }
        return url
    }
}

public enum APIError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unreachable(String)
    case insecureConnection
    case unauthorized
    case notFound
    case server(status: Int, detail: String?)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Server nicht konfiguriert. Bitte Server-URL, Benutzer und Passwort in den Einstellungen eintragen."
        case .unreachable(let why):
            "Server nicht erreichbar (\(why)). Läuft job-hunter und stimmt die URL?"
        case .insecureConnection:
            "Unverschlüsselte HTTP-Verbindung blockiert. Bitte HTTPS verwenden (HTTP ist nur für localhost/LAN erlaubt)."
        case .unauthorized:
            "Anmeldung fehlgeschlagen (401). Benutzer/Passwort prüfen (DASHBOARD_USER/DASHBOARD_PASSWORD)."
        case .notFound:
            "Nicht gefunden (404). Ist die Server-Version aktuell (API /api/v1)?"
        case .server(let status, let detail):
            "Serverfehler \(status)" + (detail.map { ": \($0)" } ?? "")
        case .decoding(let what):
            "Unerwartete Serverantwort: \(what)"
        case .transport(let why):
            "Netzwerkfehler: \(why)"
        }
    }

    public var isConnectivityProblem: Bool {
        switch self {
        case .unreachable, .transport, .insecureConnection: true
        default: false
        }
    }
}

/// Thin async client for the job-hunter JSON API (`/api/v1`). Tracker data, drafts and the
/// e-mail outbox. The server never sends mail; the app does (see `SendCoordinator`).
public struct APIClient: Sendable {
    public let config: ServerConfig
    private let session: URLSession

    public init(config: ServerConfig, session: URLSession? = nil, timeout: TimeInterval = 20) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral  // no cookie/credential persistence
            cfg.timeoutIntervalForRequest = timeout
            cfg.timeoutIntervalForResource = 120
            cfg.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "JobHunter-macOS/1.0"]
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: Endpoints

    public func health() async throws -> Health {
        try await send("GET", "health")
    }

    public func jobs(_ filter: JobFilter = JobFilter(), limit: Int = 500) async throws -> [JobSummary] {
        let list: JobList = try await send("GET", "jobs",
                                           query: filter.queryItems + [URLQueryItem(name: "limit", value: String(limit))])
        return list.items
    }

    public func job(id: Int) async throws -> JobDetail {
        try await send("GET", "jobs/\(id)")
    }

    public func update(id: Int, _ update: JobUpdate) async throws -> JobDetail {
        try await send("PATCH", "jobs/\(id)", body: try Self.encoder.encode(update))
    }

    public func saveLetter(id: Int, text: String) async throws -> JobDetail {
        try await send("PUT", "jobs/\(id)/letter", body: try Self.encoder.encode(["letter": text]))
    }

    /// "Anzeigentext einfügen": saves the pasted posting text, the server re-scores the job and
    /// (writeLetter) starts a KI letter unless the letter was written by the user.
    public func saveDescription(id: Int, text: String, writeLetter: Bool = true) async throws -> JobDetail {
        struct Body: Encodable {
            let description: String
            let write_letter: Bool
        }
        return try await send("PUT", "jobs/\(id)/description",
                              body: try Self.encoder.encode(Body(description: text, write_letter: writeLetter)))
    }

    /// Jobs parsed from job-alert e-mails (`POST /api/v1/jobs/import`).
    public func importJobs(_ jobs: [AlertJob]) async throws -> ImportResult {
        try await send("POST", "jobs/import", body: try Self.encoder.encode(jobs))
    }

    public func regenerateLetter(id: Int) async throws -> JobDetail {
        try await send("POST", "jobs/\(id)/regenerate", body: Data("{}".utf8))
    }

    public func triggerRun() async throws -> RunResponse {
        try await send("POST", "run", body: Data("{}".utf8))
    }

    public func stats(minScore: Int? = nil) async throws -> Stats {
        try await send("GET", "stats", query: minScore.map { [URLQueryItem(name: "min_score", value: String($0))] } ?? [])
    }

    // MARK: E-mail applications

    public func sendSettings() async throws -> SendSettings {
        try await send("GET", "send-settings")
    }

    public func outbox() async throws -> Outbox {
        try await send("GET", "outbox")
    }

    public func emailPreview(id: Int) async throws -> EmailPreview {
        try await send("GET", "jobs/\(id)/email-preview")
    }

    public func approve(id: Int) async throws -> EmailPreview {
        try await send("POST", "jobs/\(id)/approve", body: Data("{}".utf8))
    }

    public func unapprove(id: Int) async throws -> EmailPreview {
        try await send("DELETE", "jobs/\(id)/approve")
    }

    public func recordSent(id: Int, _ report: SentReport) async throws -> SentResponse {
        try await send("POST", "jobs/\(id)/sent", body: try Self.encoder.encode(report))
    }

    public func sentLog(limit: Int = 500) async throws -> SentList {
        try await send("GET", "sent", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    public func setSentMessageID(sentID: Int, messageID: String) async throws -> SentEntry {
        try await send("PATCH", "sent/\(sentID)", body: try Self.encoder.encode(["message_id": messageID]))
    }

    public struct OK: Decodable, Sendable { public var ok: Bool }

    /// Tells the server (dashboard banner) whether "Automatisch senden" is on in this app.
    public func reportClientState(autoSendEnabled: Bool, appVersion: String?) async throws {
        struct Body: Encodable {
            let client = "macos"
            let auto_send_enabled: Bool
            let app_version: String?
        }
        let _: OK = try await send("POST", "client-state",
                                   body: try Self.encoder.encode(Body(auto_send_enabled: autoSendEnabled,
                                                                      app_version: appVersion)))
    }

    // MARK: Plumbing

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw APIError.decoding("Feld '\(key.stringValue)' fehlt (\(ctx.codingPath.map(\.stringValue).joined(separator: ".")))")
        } catch let DecodingError.typeMismatch(_, ctx), let DecodingError.valueNotFound(_, ctx) {
            throw APIError.decoding("Typfehler bei '\(ctx.codingPath.map(\.stringValue).joined(separator: "."))'")
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    public func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var url = config.baseURL.appending(path: "api/v1").appending(path: path)
        if !query.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = query
            url = comps.url!
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = Data("\(config.username):\(config.password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [],
                                    body: Data? = nil) async throws -> T {
        let req = makeRequest(method, path, query: query, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("keine HTTP-Antwort") }
        switch http.statusCode {
        case 200..<300:
            return try Self.decode(T.self, from: data)
        case 401, 403:
            if http.statusCode == 403, let detail = Self.detail(from: data) {
                throw APIError.server(status: 403, detail: detail)
            }
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            throw APIError.server(status: http.statusCode, detail: Self.detail(from: data))
        }
    }

    static func detail(from data: Data) -> String? {
        struct Detail: Decodable { let detail: String }
        if let d = try? JSONDecoder().decode(Detail.self, from: data) { return d.detail }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func map(_ error: URLError) -> APIError {
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet,
             .networkConnectionLost, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid, .cannotLoadFromNetwork:
            return .unreachable(error.localizedDescription)
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureConnection
        case .userAuthenticationRequired:
            return .unauthorized
        default:
            return .transport(error.localizedDescription)
        }
    }
}
