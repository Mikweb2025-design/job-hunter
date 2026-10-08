import Foundation
import Testing
@testable import JobHunterCore

// MARK: - Fixture helpers

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// MARK: - Decoding (fixtures generated from the real backend, scripts/make_fixtures.py)

@Suite("Decoding")
struct DecodingTests {
    @Test func jobList() throws {
        let list = try APIClient.decode(JobList.self, from: fixture("jobs"))
        #expect(list.count == list.items.count)
        #expect(list.items.count == 5)
        let scores = list.items.map(\.score)
        #expect(scores == scores.sorted(by: >))
        let top = try #require(list.items.first)
        #expect(top.title == "Cloud Support Engineer (m/w/d)")
        #expect(top.status == .beworben)
        #expect(top.remote)
        #expect(top.hasLetter)
        #expect(top.fetchedDate != nil)
        #expect(top.link?.host() == "www.adzuna.de")
        #expect(list.items.contains { !$0.alsoSeenOn.isEmpty })
    }

    @Test func jobDetail() throws {
        let d = try APIClient.decode(JobDetail.self, from: fixture("job_detail"))
        #expect(d.id == d.summary.id)
        #expect(d.summary.status == .beworben)
        #expect(d.summary.appliedDate != nil)
        #expect(d.notes == "Über das Portal beworben")
        #expect(!d.description.isEmpty)
        #expect(!d.letter.isEmpty)
        #expect(d.letterIsTemplate)
        #expect(d.reason == nil)
        #expect(d.scoreBreakdown.keywords == 32)
        #expect(d.scoreBreakdown.matched.contains("Python"))
        #expect(d.scoreBreakdown.titleMatch == "Support Engineer")
        #expect(d.scoreBreakdown.salary == 20)
        #expect(!d.scoreBreakdown.isExcluded)
        #expect(d.summary.salaryText == "52.000 € – 62.000 €")
    }

    @Test func excludedJobDetail() throws {
        let d = try APIClient.decode(JobDetail.self, from: fixture("job_detail_excluded"))
        #expect(d.summary.score == 0)
        #expect(d.scoreBreakdown.isExcluded)
        #expect(d.scoreBreakdown.titleMatch == nil)
    }

    @Test func stats() throws {
        let s = try APIClient.decode(Stats.self, from: fixture("stats"))
        #expect(s.total == 5)
        #expect(s.count(.beworben) == 1)
        #expect(s.count(.neu) == 4)
        #expect(s.count(.angebot) == 0)
        // Older servers do not know every status (e.g. zu_weit): keys must be known,
        // not exhaustive.
        #expect(Set(s.byStatus.keys).isSubset(of: Set(JobStatus.allCases.map(\.rawValue))))
        #expect(s.sources == ["adzuna", "arbeitsagentur"])
        #expect(s.newSinceLastRun == 5)
        #expect(s.threshold == 70)
        #expect(s.lastRun?.newJobs == 5)
        #expect(s.lastRun?.errors.isEmpty == true)
    }

    @Test func healthAndRun() throws {
        let h = try APIClient.decode(Health.self, from: fixture("health"))
        #expect(h.ok && h.apiVersion == 1 && !h.llmEnabled)
        let r = try APIClient.decode(RunResponse.self, from: fixture("run"))
        #expect(r.started && r.running)
    }

    @Test func unknownStatusFallsBackInsteadOfFailing() throws {
        let json = #"{"count":1,"items":[{"id":1,"title":"X","source":"rss","fetched_at":"2026-10-03T06:30:00+00:00","score":50,"status":"archiviert","remote":false,"salary_predicted":false,"also_seen_on":[],"has_letter":false}]}"#
        let list = try APIClient.decode(JobList.self, from: Data(json.utf8))
        #expect(list.items[0].status == .neu)
        #expect(list.items[0].company == nil)
    }

    @Test func missingFieldGivesReadableError() {
        #expect(throws: APIError.self) {
            try APIClient.decode(JobList.self, from: Data(#"{"count":1,"items":[{"id":1}]}"#.utf8))
        }
    }
}

// MARK: - Dates, URLs, helpers

@Suite("Helpers")
struct HelperTests {
    @Test(arguments: [
        "2026-10-03T08:57:18+00:00",
        "2026-10-03T08:57:18.164469+00:00",
        "2026-10-03T08:57:18.1+00:00",
        "2026-10-03T08:57:18Z",
    ])
    func parsesServerTimestamps(_ value: String) throws {
        let d = try #require(ServerDate.parse(value))
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
        #expect(c.year == 2026 && c.month == 10 && c.day == 3 && c.hour == 8 && c.minute == 57 && c.second == 18)
    }

    @Test func parsesDayOnlyAndRejectsGarbage() {
        #expect(ServerDate.parse("2026-09-30") != nil)
        #expect(ServerDate.parse("") == nil)
        #expect(ServerDate.parse(nil) == nil)
        #expect(ServerDate.parse("gestern") == nil)
    }

    @Test func normalizesServerURL() {
        #expect(ServerConfig.normalizedURL("jobs.example.org")?.absoluteString == "https://jobs.example.org")
        #expect(ServerConfig.normalizedURL(" http://localhost:8000/ ")?.absoluteString == "http://localhost:8000")
        #expect(ServerConfig.normalizedURL("https://example.org/jobhunter/")?.absoluteString == "https://example.org/jobhunter")
        #expect(ServerConfig.normalizedURL("") == nil)
        #expect(ServerConfig.normalizedURL("ftp://example.org") == nil)
    }

    @Test func filterQueryItems() {
        #expect(JobFilter().queryItems == [URLQueryItem(name: "status", value: "aktiv")])
        let f = JobFilter(status: .only(.gespraech), minScore: 70, source: "adzuna", sinceDays: 7, query: "  Linux ")
        #expect(f.queryItems == [
            URLQueryItem(name: "status", value: "gespraech"),
            URLQueryItem(name: "min_score", value: "70"),
            URLQueryItem(name: "source", value: "adzuna"),
            URLQueryItem(name: "since", value: "7"),
            URLQueryItem(name: "q", value: "Linux"),
        ])
        #expect(JobFilter(status: .all).queryItems.isEmpty)
    }

    @Test func jobUpdateEncoding() throws {
        func json(_ u: JobUpdate) throws -> String {
            String(decoding: try APIClient.encoder.encode(u), as: UTF8.self)
        }
        #expect(try json(JobUpdate(status: .beworben)) == #"{"status":"beworben"}"#)
        #expect(try json(JobUpdate(notes: "", appliedDate: .clear)) == #"{"applied_date":null,"notes":""}"#)
        #expect(try json(JobUpdate(appliedDate: .set("2026-10-01"))) == #"{"applied_date":"2026-10-01"}"#)
    }

    @Test func newJobDetection() throws {
        let jobs = try APIClient.decode(JobList.self, from: fixture("jobs")).items
        let high = NewJobDetector.highScoreUntriaged(jobs, threshold: 50)
        #expect(high.allSatisfy { $0.status == .neu && $0.score >= 50 })
        #expect(high.map(\.score) == high.map(\.score).sorted(by: >))
        let seen = Set(high.dropFirst().map(\.id))
        let fresh = NewJobDetector.newJobs(in: jobs, seen: seen, threshold: 50)
        #expect(fresh.map(\.id) == Array(high.prefix(1)).map(\.id))
        #expect(NewJobDetector.newJobs(in: jobs, seen: Set(jobs.map(\.id)), threshold: 0).isEmpty)
        let big = Set(1...3000)
        #expect(NewJobDetector.pruned(big, current: jobs, keep: 100).count == 100)
    }
}

// MARK: - Requests against a stubbed URLSession

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var body: Data; var error: URLError.Code? }
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            return data
        }
        let reply = Self.handler?(request) ?? Reply(status: 500, body: Data(), error: nil)
        if let code = reply.error {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Requests", .serialized)
struct RequestTests {
    let client: APIClient

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        client = APIClient(config: ServerConfig(baseURL: URL(string: "https://jobs.example.org/jh")!,
                                                username: "test-user", password: "test-pass"),
                           session: URLSession(configuration: cfg))
    }

    @Test func listRequestHasAuthPathAndQuery() async throws {
        let body = try fixture("jobs")
        StubProtocol.handler = { _ in .init(status: 200, body: body, error: nil) }
        let jobs = try await client.jobs(JobFilter(minScore: 60), limit: 50)
        #expect(jobs.count == 5)
        let req = try #require(StubProtocol.lastRequest)
        #expect(req.httpMethod == "GET")
        let comps = try #require(URLComponents(url: req.url!, resolvingAgainstBaseURL: false))
        #expect(comps.path == "/jh/api/v1/jobs")
        #expect(comps.queryItems?.contains(URLQueryItem(name: "min_score", value: "60")) == true)
        #expect(comps.queryItems?.contains(URLQueryItem(name: "limit", value: "50")) == true)
        let expected = "Basic " + Data("test-user:test-pass".utf8).base64EncodedString()
        #expect(req.value(forHTTPHeaderField: "Authorization") == expected)
    }

    @Test func patchSendsJSON() async throws {
        let body = try fixture("job_detail")
        StubProtocol.handler = { _ in .init(status: 200, body: body, error: nil) }
        let d = try await client.update(id: 4, JobUpdate(status: .beworben, notes: "x"))
        #expect(d.summary.status == .beworben)
        let req = try #require(StubProtocol.lastRequest)
        #expect(req.httpMethod == "PATCH")
        #expect(req.url?.path() == "/jh/api/v1/jobs/4")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [String: String]
        #expect(sent == ["status": "beworben", "notes": "x"])
    }

    @Test func letterRegenerateAndRun() async throws {
        let detail = try fixture("job_detail")
        let run = try fixture("run")
        StubProtocol.handler = { req in .init(status: req.url!.path().hasSuffix("/run") ? 202 : 200,
                                              body: req.url!.path().hasSuffix("/run") ? run : detail, error: nil) }
        _ = try await client.saveLetter(id: 4, text: "Hallo")
        #expect(StubProtocol.lastRequest?.httpMethod == "PUT")
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/jobs/4/letter")
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [String: String]
        #expect(sent == ["letter": "Hallo"])
        _ = try await client.regenerateLetter(id: 4)
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/jobs/4/regenerate")
        let r = try await client.triggerRun()
        #expect(r.started)
        #expect(StubProtocol.lastRequest?.httpMethod == "POST")
    }

    @Test func importJobsAndSaveDescription() async throws {
        let detail = try fixture("job_detail")
        let imported = Data(#"{"received":1,"imported":1,"duplicates":0,"invalid":0,"imported_ids":[50],"duplicate_ids":[],"items":[]}"#.utf8)
        StubProtocol.handler = { req in .init(status: 200, body: req.url!.path().hasSuffix("/import") ? imported : detail, error: nil) }
        let job = AlertJob(source: .linkedin, externalId: "4416593964", title: "T", company: "C", location: "Berlin",
                           url: "https://www.linkedin.com/jobs/view/4416593964/", receivedAt: Date(timeIntervalSince1970: 0))
        let r = try await client.importJobs([job])
        #expect(r.imported == 1 && r.importedIds == [50])
        #expect(StubProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/jobs/import")
        let sent = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [[String: String]]
        #expect(sent?.first?["external_id"] == "4416593964" && sent?.first?["source"] == "linkedin-alert")
        #expect(sent?.first?["received_at"] == "1970-01-01T00:00:00Z")

        _ = try await client.saveDescription(id: 4, text: "Anzeige")
        #expect(StubProtocol.lastRequest?.httpMethod == "PUT")
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/jobs/4/description")
        let body = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [String: Any]
        #expect(body?["description"] as? String == "Anzeige" && body?["write_letter"] as? Bool == true)
    }

    @Test func errorMapping() async throws {
        StubProtocol.handler = { _ in .init(status: 401, body: Data("Authentication required".utf8), error: nil) }
        await #expect(throws: APIError.unauthorized) { try await client.health() }

        StubProtocol.handler = { _ in .init(status: 404, body: Data(#"{"detail":"job not found"}"#.utf8), error: nil) }
        await #expect(throws: APIError.notFound) { try await client.job(id: 9) }

        StubProtocol.handler = { _ in .init(status: 502, body: Data(#"{"detail":"LLM-Fehler: timeout"}"#.utf8), error: nil) }
        await #expect(throws: APIError.server(status: 502, detail: "LLM-Fehler: timeout")) { try await client.regenerateLetter(id: 1) }

        StubProtocol.handler = { _ in .init(status: 0, body: Data(), error: .cannotConnectToHost) }
        do {
            _ = try await client.stats()
            Issue.record("expected error")
        } catch let e as APIError {
            #expect(e.isConnectivityProblem)
            #expect(e.errorDescription?.contains("nicht erreichbar") == true)
        }

        StubProtocol.handler = { _ in .init(status: 200, body: Data("<html>".utf8), error: nil) }
        do {
            _ = try await client.health()
            Issue.record("expected error")
        } catch let e as APIError {
            if case .decoding = e {} else { Issue.record("expected decoding error, got \(e)") }
        }
    }
}
