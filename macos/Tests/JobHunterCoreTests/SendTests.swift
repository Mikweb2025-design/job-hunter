import Foundation
import Testing
@testable import JobHunterCore

// MARK: - Helpers

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// Fixture with some top-level keys replaced.
private func fixture(_ name: String, patch: [String: Any]) throws -> Data {
    var obj = try #require(try JSONSerialization.jsonObject(with: fixture(name)) as? [String: Any])
    for (k, v) in patch { obj[k] = v }
    return try JSONSerialization.data(withJSONObject: obj)
}

/// Records every call; never touches Apple Mail.
final class FakeSender: MailSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(MailMessage, MailDelivery)] = []
    var failWith: Error?

    var calls: [(MailMessage, MailDelivery)] { lock.withLock { _calls } }
    var sendCalls: Int { calls.filter { $0.1 == .send }.count }

    func deliver(_ message: MailMessage, _ delivery: MailDelivery) async throws -> String? {
        if let failWith { throw failWith }
        lock.withLock { _calls.append((message, delivery)) }
        return nil
    }
}

/// URLProtocol stub with its own state (independent of the other suites' stub).
final class SendStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var body: Data; var error: URLError.Code? = nil }
    nonisolated(unsafe) static var routes: [String: Reply] = [:]   // "METHOD /path-suffix"
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: Data?)] = []

    static func reset() { routes = [:]; requests = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path()
        let body = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open(); defer { stream.close() }
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            return data
        }
        Self.requests.append((method, path, body))
        let reply = Self.routes.first { key, _ in
            let parts = key.split(separator: " ", maxSplits: 1).map(String.init)
            return parts[0] == method && path.hasSuffix(parts[1])
        }?.value ?? Reply(status: 404, body: Data(#"{"detail":"no route"}"#.utf8))
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

    static var sentPosts: [[String: Any]] {
        requests.filter { $0.method == "POST" && $0.path.hasSuffix("/sent") }
            .compactMap { $0.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }
}

private func makeAPI() -> APIClient {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [SendStub.self]
    return APIClient(config: ServerConfig(baseURL: URL(string: "https://jobs.example.org")!,
                                          username: "u", password: "p"),
                     session: URLSession(configuration: cfg))
}

private func coordinator(_ sender: FakeSender, ledger: SendLedger = InMemoryLedger(),
                         cvExists: Bool = true) -> SendCoordinator {
    SendCoordinator(api: makeAPI(), sender: sender, ledger: ledger, attachmentPath: "~/Bewerbung/CV.pdf",
                    fileExists: { _ in cvExists }, now: { Date(timeIntervalSince1970: 1_790_000_000) })
}

private func sentOK() throws -> SendStub.Reply {
    // POST /sent returns {sent, job}; build it from fixtures.
    let sent = try #require(try JSONSerialization.jsonObject(with: fixture("sent")) as? [String: Any])
    let entry = try #require((sent["items"] as? [[String: Any]])?.first)
    let job = try JSONSerialization.jsonObject(with: fixture("job_detail"))
    return .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["sent": entry, "job": job]))
}

// MARK: - Decoding

@Suite("Send decoding")
struct SendDecodingTests {
    @Test func sendSettings() throws {
        let s = try APIClient.decode(SendSettings.self, from: fixture("send_settings"))
        #expect(s.mode == "auto" && !s.dryRun && !s.killSwitch)
        #expect(s.autoMinScore == 80 && s.dailyCap == 5 && s.companyCooldownDays == 90)
        #expect(s.fromAddress == "info@daniele-michelin.com" && s.senderName == "Daniele Michelin")
        #expect(s.blocklist.contains("IONOS") && s.requireLetter)
        #expect(s.sentTotal == 1 && s.dryRunTotal == 1)
    }

    @Test func outbox() throws {
        let o = try APIClient.decode(Outbox.self, from: fixture("outbox"))
        #expect(o.count == 1 && o.items.count == 1)
        let item = try #require(o.items.first)
        #expect(item.reason == "auto" && !item.isApproved)
        #expect(item.email.to == "jobs@acme.de")
        #expect(item.email.subject == "Bewerbung als Cloud Support Engineer")
        #expect(item.email.sender == "Daniele Michelin <info@daniele-michelin.com>")
        #expect(item.email.body.hasPrefix("Sehr geehrte Damen und Herren,"))
    }

    @Test func previewAndSentLog() throws {
        let p = try APIClient.decode(EmailPreview.self, from: fixture("email_preview"))
        #expect(p.canSend && p.autoEligible && p.inOutbox && p.blockers.isEmpty)
        #expect(p.sendState.state == "ready" && p.applyEmail == "jobs@acme.de" && p.applyEmailSource == "phrase")
        let sent = try APIClient.decode(EmailPreview.self, from: fixture("email_preview_sent"))
        #expect(!sent.canSend && sent.blockers.contains("already_sent"))
        #expect(sent.sendState.isSent && sent.sendState.to == "karriere@beta.de")
        #expect(sent.sent.count == 2 && sent.sent.contains { $0.dryRun } && sent.sent.contains { !$0.dryRun })
        let log = try APIClient.decode(SentList.self, from: fixture("sent"))
        #expect(log.count == 2 && log.sentTotal == 1 && log.dryRunTotal == 1)
        #expect(log.items.first?.sentDate != nil)
    }

    @Test func jobListCarriesSendState() throws {
        let list = try APIClient.decode(JobList.self, from: fixture("jobs_with_mail"))
        let acme = try #require(list.items.first { $0.company == "Acme GmbH" })
        #expect(acme.applyEmail == "jobs@acme.de" && acme.applyMethod == "email")
        #expect(acme.sendState?.state == "email")
        let beta = try #require(list.items.first { $0.company == "Beta AG" })
        #expect(beta.sendState?.isSent == true && beta.status == .beworben)
        #expect(list.items.contains { $0.sendState?.state == "manual" })
        // Older servers without these fields still decode (see DecodingTests.jobList).
        #expect(try APIClient.decode(JobList.self, from: fixture("jobs")).items.allSatisfy { $0.applyEmail == nil || true })
    }

    @Test func sentReportEncoding() throws {
        let r = SentReport(dryRun: false, sentAt: "2026-10-03T08:15:00Z", to: "a@b.de", subject: "S", body: "B", trigger: "auto")
        let json = String(decoding: try APIClient.encoder.encode(r), as: UTF8.self)
        #expect(json == #"{"body":"B","dry_run":false,"sent_at":"2026-10-03T08:15:00Z","subject":"S","to":"a@b.de","trigger":"auto"}"#)
        let back = try JSONDecoder().decode(SentReport.self, from: try JSONEncoder().encode(r))
        #expect(back == r)
        #expect(String(decoding: try APIClient.encoder.encode(JobUpdate(applyEmail: "")), as: UTF8.self) == #"{"apply_email":""}"#)
    }

    @Test func bannerKinds() throws {
        var s = try APIClient.decode(SendSettings.self, from: fixture("send_settings"))
        #expect(SendBannerKind.from(nil, autoSendEnabled: true) == .unknown)
        #expect(SendBannerKind.from(s, autoSendEnabled: true) == .auto)
        #expect(SendBannerKind.from(s, autoSendEnabled: false) == .approve)
        #expect(SendBannerKind.auto.headline(s) == "AUTOMATISCHER VERSAND AKTIV – 1 von 5 heute")
        s.dryRun = true
        #expect(SendBannerKind.from(s, autoSendEnabled: true) == .test)
        #expect(SendBannerKind.test.headline(s) == "TESTMODUS – es werden keine E-Mails versendet")
        s.mode = "off"
        #expect(SendBannerKind.from(s, autoSendEnabled: true) == .off)
        #expect(SendBannerKind.off.headline(s) == "Versand aus")
        s.killSwitch = true
        #expect(SendBannerKind.from(s, autoSendEnabled: true) == .kill)
    }

    @Test func messageURL() {
        #expect(AppleMailSender.messageURL(messageID: "<abc.123@mail.example>")?.absoluteString == "message://%3Cabc.123@mail.example%3E")
        #expect(AppleMailSender.messageURL(messageID: "x@y")?.absoluteString == "message://%3Cx@y%3E")
    }

    @Test func appleScriptKeepsValuesOutOfSource() {
        // Values are passed as Apple Event parameters to handlers, never interpolated.
        let src = AppleMailSender.scriptSource
        #expect(src.contains("on send_mail(senderAddress, senderName, toAddress, theSubject, theBody, attachmentPath, shouldSend)"))
        #expect(src.contains("if shouldSend then"))
        #expect(!src.contains("\\("))
    }
}

// MARK: - Requests

/// One serialized suite: all tests share SendStub's static routes.
@Suite("Send requests + coordinator", .serialized)
struct SendStubbedTests {
    @Test func endpointsPathsAndMethods() async throws {
        SendStub.reset()
        let api = makeAPI()
        SendStub.routes = [
            "GET /send-settings": .init(status: 200, body: try fixture("send_settings")),
            "GET /outbox": .init(status: 200, body: try fixture("outbox")),
            "GET /email-preview": .init(status: 200, body: try fixture("email_preview")),
            "POST /approve": .init(status: 200, body: try fixture("email_preview")),
            "DELETE /approve": .init(status: 200, body: try fixture("email_preview")),
            "GET /sent": .init(status: 200, body: try fixture("sent")),
            "POST /client-state": .init(status: 200, body: Data(#"{"ok":true}"#.utf8)),
            "POST /sent": try sentOK(),
        ]
        _ = try await api.sendSettings()
        _ = try await api.outbox()
        _ = try await api.emailPreview(id: 6)
        _ = try await api.approve(id: 6)
        _ = try await api.unapprove(id: 6)
        _ = try await api.sentLog(limit: 10)
        try await api.reportClientState(autoSendEnabled: true, appVersion: "1.1")
        _ = try await api.recordSent(id: 6, SentReport(dryRun: true, sentAt: "2026-10-03T08:00:00Z", to: "a@b.de",
                                                       subject: "S", body: "B", trigger: "manual"))
        let seen = SendStub.requests.map { "\($0.method) \($0.path)" }
        #expect(seen == ["GET /api/v1/send-settings", "GET /api/v1/outbox", "GET /api/v1/jobs/6/email-preview",
                         "POST /api/v1/jobs/6/approve", "DELETE /api/v1/jobs/6/approve", "GET /api/v1/sent",
                         "POST /api/v1/client-state", "POST /api/v1/jobs/6/sent"])
        let cs = try #require(SendStub.requests[6].body)
        let obj = try #require(try JSONSerialization.jsonObject(with: cs) as? [String: Any])
        #expect(obj["auto_send_enabled"] as? Bool == true && obj["client"] as? String == "macos")
        #expect(SendStub.sentPosts.first?["dry_run"] as? Bool == true)
    }

    @Test func approveConflictIsReadable() async throws {
        SendStub.reset()
        SendStub.routes = ["POST /approve": .init(status: 409, body: Data(#"{"detail":"Senden nicht erlaubt: Tageslimit erreicht","blockers":["daily_cap"]}"#.utf8))]
        await #expect(throws: APIError.server(status: 409, detail: "Senden nicht erlaubt: Tageslimit erreicht")) {
            try await makeAPI().approve(id: 1)
        }
    }

    // MARK: Coordinator (fake sender: Apple Mail is never touched)

    @Test func dryRunOutboxNeverSends() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: ["dry_run": true])),
                           "POST /sent": try sentOK()]
        let sender = FakeSender()
        let r = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(sender.calls.isEmpty)
        #expect(r.outcomes.isEmpty && r.error == nil)
        #expect(SendStub.sentPosts.isEmpty)
    }

    @Test func dryRunManualOnlyDrafts() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /email-preview": .init(status: 200, body: try fixture("email_preview", patch: ["dry_run": true])),
                           "POST /sent": try sentOK()]
        let sender = FakeSender()
        let outcome = try await coordinator(sender).sendNow(jobID: 6)
        #expect(outcome == .drafted(jobID: 6, to: "jobs@acme.de", subject: "Bewerbung als Cloud Support Engineer"))
        #expect(sender.calls.count == 1 && sender.calls[0].1 == .draftOnly)
        #expect(sender.sendCalls == 0)
        #expect(SendStub.sentPosts.count == 1 && SendStub.sentPosts[0]["dry_run"] as? Bool == true)
    }

    @Test func realManualSendRecords() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /email-preview": .init(status: 200, body: try fixture("email_preview")),
                           "POST /sent": try sentOK()]
        let sender = FakeSender()
        let ledger = InMemoryLedger()
        let outcome = try await coordinator(sender, ledger: ledger).sendNow(jobID: 6)
        #expect(outcome == .sent(jobID: 6, to: "jobs@acme.de", subject: "Bewerbung als Cloud Support Engineer", recorded: true))
        let (msg, delivery) = try #require(sender.calls.first)
        #expect(delivery == .send)
        #expect(msg.fromAddress == "info@daniele-michelin.com" && msg.senderHeader == "Daniele Michelin <info@daniele-michelin.com>")
        #expect(msg.attachmentPath?.hasSuffix("/Bewerbung/CV.pdf") == true && !(msg.attachmentPath?.hasPrefix("~") ?? true))
        let post = try #require(SendStub.sentPosts.first)
        #expect(post["dry_run"] as? Bool == false && post["trigger"] as? String == "manual" && post["to"] as? String == "jobs@acme.de")
        #expect(ledger.wasSent(6) && ledger.pending().isEmpty)
        // a second click is refused locally even if the server would allow it
        await #expect(throws: SendError.alreadySent) { try await coordinator(sender, ledger: ledger).sendNow(jobID: 6) }
        #expect(sender.sendCalls == 1)
    }

    @Test func blockedPreviewNeverSends() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /email-preview": .init(status: 200, body: try fixture("email_preview_sent"))]
        let sender = FakeSender()
        await #expect(throws: SendError.self) { try await coordinator(sender).sendNow(jobID: 7) }
        #expect(sender.calls.isEmpty)
    }

    @Test func autoNeedsToggleApprovedDoesNot() async throws {
        SendStub.reset()
        let o = try #require(try JSONSerialization.jsonObject(with: fixture("outbox")) as? [String: Any])
        var auto = try #require((o["items"] as? [[String: Any]])?.first)
        var approved = auto
        approved["job_id"] = 99
        approved["reason"] = "approved"
        auto["job_id"] = 6
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: ["items": [approved, auto], "count": 2])),
                           "POST /sent": try sentOK()]
        let sender = FakeSender()
        let off = await coordinator(sender).processOutbox(autoSendEnabled: false)
        #expect(sender.sendCalls == 1)  // only the approved one
        #expect(off.outcomes.contains(.skipped(jobID: 6, reason: "auto aus")))
        #expect(SendStub.sentPosts.map { $0["trigger"] as? String } == ["approved"])

        let sender2 = FakeSender()
        let on = await coordinator(sender2).processOutbox(autoSendEnabled: true)
        #expect(sender2.sendCalls == 2 && on.sentCount == 2)
    }

    @Test func autoItemInApproveModeIsNotSent() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: ["mode": "approve"]))]
        let sender = FakeSender()
        _ = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(sender.calls.isEmpty)
    }

    @Test(arguments: [["kill_switch": true], ["mode": "off"]] as [[String: any Sendable]])
    func killSwitchAndOff(_ patch: [String: any Sendable]) async throws {
        SendStub.reset()
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: patch))]
        let sender = FakeSender()
        _ = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(sender.calls.isEmpty)
    }

    @Test func unreachableServerNeverSends() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /outbox": .init(status: 0, body: Data(), error: .cannotConnectToHost)]
        let sender = FakeSender()
        let r = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(sender.calls.isEmpty)
        #expect((r.error as? APIError)?.isConnectivityProblem == true)
    }

    @Test func respectsRemainingBudget() async throws {
        SendStub.reset()
        let o = try #require(try JSONSerialization.jsonObject(with: fixture("outbox")) as? [String: Any])
        let item = try #require((o["items"] as? [[String: Any]])?.first)
        let items = (1...3).map { i -> [String: Any] in var x = item; x["job_id"] = 100 + i; return x }
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: ["items": items, "remaining_today": 2])),
                           "POST /sent": try sentOK()]
        let sender = FakeSender()
        _ = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(sender.sendCalls == 2)
    }

    @Test func missingCVStopsBeforeSending() async throws {
        SendStub.reset()
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox"))]
        let sender = FakeSender()
        let r = await coordinator(sender, cvExists: false).processOutbox(autoSendEnabled: true)
        #expect(sender.calls.isEmpty)
        if case .attachmentMissing = r.error as? SendError {} else { Issue.record("expected attachmentMissing, got \(String(describing: r.error))") }
    }

    @Test func mailErrorStopsBatch() async throws {
        SendStub.reset()
        let o = try #require(try JSONSerialization.jsonObject(with: fixture("outbox")) as? [String: Any])
        let item = try #require((o["items"] as? [[String: Any]])?.first)
        let items = (1...3).map { i -> [String: Any] in var x = item; x["job_id"] = 200 + i; return x }
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox", patch: ["items": items]))]
        let sender = FakeSender()
        sender.failWith = SendError.mail("Keine Berechtigung")
        let r = await coordinator(sender).processOutbox(autoSendEnabled: true)
        #expect(r.error as? SendError == .mail("Keine Berechtigung") && r.outcomes.isEmpty)
        #expect(SendStub.requests.filter { $0.path.hasSuffix("/sent") }.isEmpty)
    }

    @Test func ledgerPreventsResendAndRetriesReport() async throws {
        SendStub.reset()
        // Sending works, but the server fails to record it.
        SendStub.routes = ["GET /outbox": .init(status: 200, body: try fixture("outbox")),
                           "POST /sent": .init(status: 500, body: Data(#"{"detail":"db locked"}"#.utf8))]
        let sender = FakeSender()
        let ledger = InMemoryLedger()
        let r = await coordinator(sender, ledger: ledger).processOutbox(autoSendEnabled: true)
        #expect(r.outcomes == [.sent(jobID: 6, to: "jobs@acme.de", subject: "Bewerbung als Cloud Support Engineer", recorded: false)])
        #expect(ledger.pending().keys.contains(6))
        // Next refresh: the server still lists the job (it never heard of the send) -> not sent again,
        // and the pending report is delivered once the server works again.
        SendStub.routes["POST /sent"] = try sentOK()
        let r2 = await coordinator(sender, ledger: ledger).processOutbox(autoSendEnabled: true)
        #expect(sender.sendCalls == 1)
        #expect(r2.outcomes == [.skipped(jobID: 6, reason: "bereits gesendet")])
        #expect(ledger.pending().isEmpty)
    }

    @Test func userDefaultsLedgerPersists() throws {
        let suite = "jobhunter-test-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        let r = SentReport(dryRun: false, sentAt: "x", to: "a@b.de", subject: "S", body: "B", trigger: "auto")
        UserDefaultsLedger(defaults: d).markSent(5, report: r)
        let again = UserDefaultsLedger(defaults: d)
        #expect(again.wasSent(5) && !again.wasSent(6) && again.pending()[5] == r)
        again.markRecorded(5)
        #expect(UserDefaultsLedger(defaults: d).pending().isEmpty && UserDefaultsLedger(defaults: d).wasSent(5))
    }
}
