import Foundation
import Testing
@testable import JobHunterCore

/// Real LinkedIn alert e-mails (anonymized: recipient, profile links, tracking/login tokens removed).
private func eml(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "eml", subdirectory: "Fixtures/alerts"))
    return try String(contentsOf: url, encoding: .utf8)
}

private let received = Date(timeIntervalSince1970: 1_790_983_643)  // 2026-10-02T23:27:23Z

private func message(_ name: String, id: String = "<a@x>", sender: String = "LinkedIn Jobbenachrichtigungen <jobalerts-noreply@linkedin.com>") throws -> AlertMailMessage {
    AlertMailMessage(id: id, receivedAt: received, sender: sender, subject: "Jobbenachrichtigung", source: try eml(name))
}

@Suite("Job-Alert parser")
struct JobAlertParserTests {
    @Test func mimeDecodesQuotedPrintableParts() throws {
        let (plain, html) = MIMEText.bodies(of: try eml("linkedin_alert_support"))
        let p = try #require(plain)
        #expect(p.contains("Jobangebot ansehen: https://www.linkedin.com/comm/jobs/view/4416593964?alertAction=markasviewed"))
        #expect(p.contains("Ihre Jobbenachrichtigung wurde erstellt: Support in Berlin, Berlin, Deutschland."))
        #expect(try #require(html).contains("Technical Onboarding Specialist (m/w/d)"))
    }

    @Test func linkedInSupportAlert() throws {
        let jobs = JobAlertParser.parse(try message("linkedin_alert_support"))
        #expect(jobs.count == 6)
        #expect(jobs.map(\.title) == [
            "Technical Onboarding Specialist (m/w/d)",
            "Customer Support Agent GER/ENG (all genders)",
            "Associate Premium Support Specialist (d/f/m) - German Speaking",
            "Customer Support Associate (f/m/d)",
            "Cloud Support Engineer (German & English speaking), Support Engineering",
            "Support Specialist (Backoffice/Payments) (m/w/d)",
        ])
        #expect(jobs.map(\.company) == ["Jameda", "Cardmarket.com", "Personio", "Moss", "Amazon Web Services (AWS)", "ablefy"])
        let first = try #require(jobs.first)
        #expect(first.location == "Berlin, Berlin, Deutschland")
        #expect(first.externalId == "4416593964")
        #expect(first.url == "https://www.linkedin.com/jobs/view/4416593964/")  // no tracking/login parameters
        #expect(first.source == "linkedin-alert")
        #expect(jobs[4].location == "Berlin, Deutschland")
        #expect(jobs.allSatisfy { !$0.url.contains("?") })
    }

    @Test func linkedInKundendienstAlertSkipsNoiseLines() throws {
        let jobs = JobAlertParser.parse(try message("linkedin_alert_kundendienst"))
        #expect(jobs.count == 6)
        #expect(jobs[0].title == "Mitarbeiter für die Notrufzentrale (w/m/div.)")
        #expect(jobs[0].company == "Bosch" && jobs[0].location == "Berlin, Berlin, Deutschland")
        #expect(jobs[1].company == "Lassie")
        #expect(jobs.last?.company == "Empion by Factorial")
        #expect(jobs.last?.location == "Metropolregion Berlin/Brandenburg")
    }

    @Test func linkedInHTMLFallbackMatchesPlainText() throws {
        let (plain, html) = MIMEText.bodies(of: try eml("linkedin_alert_support"))
        let fromPlain = JobAlertParser.linkedInPlain(try #require(plain), receivedAt: received)
        var seen = Set<String>()
        let fromHTML = JobAlertParser.linkedInHTML(try #require(html), receivedAt: received)
            .filter { seen.insert($0.externalId).inserted }
        #expect(fromHTML.map(\.externalId) == fromPlain.map(\.externalId))
        #expect(fromHTML.map(\.title) == fromPlain.map(\.title))
        #expect(fromHTML.map(\.company) == fromPlain.map(\.company))
        #expect(fromHTML.map(\.location) == fromPlain.map(\.location))
    }

    @Test func linkedInIDsAndOtherSenders() throws {
        #expect(JobAlertParser.linkedInID(in: "https://de.linkedin.com/jobs/view/support-at-acme-4416593964?trk=x") == "4416593964")
        #expect(JobAlertParser.linkedInID(in: "https://evil.example/jobs/view/4416593964") == nil)
        #expect(AlertSource.from(sender: "Indeed <alert@indeed.com>") == .indeed)
        #expect(AlertSource.from(sender: "\"Lisa von Stepstone\" <info@email.stepstone.de>") == .stepstone)
        #expect(AlertSource.from(sender: "foo@example.com") == nil)
        // Welcome / ToS mails of the same senders contain no jobs.
        let welcome = AlertMailMessage(id: "w", receivedAt: received, sender: "info@email.stepstone.de", subject: "Willkommen",
                                       source: "Content-Type: text/html; charset=utf-8\n\n<p>Willkommen bei Stepstone</p><a href=\"https://www.stepstone.de/\">Start</a>")
        #expect(JobAlertParser.parse(welcome).isEmpty)
    }

    // Synthetic samples in the layout of StepStone/Indeed alert mails (no real alert received yet).
    @Test func stepStoneAndIndeedHTML() {
        let stepstone = """
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <table><tr><td><a href=3D"https://www.stepstone.de/stellenangebote--IT-Support-Engineer-m-w-d-Berlin-Acme-GmbH--12345678-inline.html?utm_source=3Djobagent&amp;cid=3Dx">IT Support Engineer (m/w/d)</a></td></tr>
        <tr><td>Acme GmbH</td></tr><tr><td>Berlin</td></tr></table>
        """
        let s = JobAlertParser.parse(AlertMailMessage(id: "s", receivedAt: received, sender: "jobagent@stepstone.de",
                                                      subject: "Neue Jobs", source: stepstone))
        #expect(s.count == 1)
        #expect(s.first?.title == "IT Support Engineer (m/w/d)" && s.first?.company == "Acme GmbH" && s.first?.location == "Berlin")
        #expect(s.first?.externalId == "12345678")
        #expect(s.first?.url == "https://www.stepstone.de/stellenangebote--IT-Support-Engineer-m-w-d-Berlin-Acme-GmbH--12345678-inline.html")

        let indeed = """
        Content-Type: text/html; charset=utf-8

        <div><a href="https://de.indeed.com/rc/clk/dl?jk=0123456789abcdef&amp;from=ja&amp;tk=zz"><b>Technical Support</b> Specialist</a>
        <div>Beta AG</div><div>10115 Berlin</div></div>
        """
        let i = JobAlertParser.parse(AlertMailMessage(id: "i", receivedAt: received, sender: "Indeed <alert@indeed.com>",
                                                      subject: "Jobs", source: indeed))
        #expect(i.count == 1)
        #expect(i.first?.title == "Technical Support Specialist" && i.first?.company == "Beta AG" && i.first?.location == "10115 Berlin")
        #expect(i.first?.url == "https://de.indeed.com/viewjob?jk=0123456789abcdef")
    }

    @Test func encodesSnakeCaseForServer() throws {
        let job = AlertJob(source: .linkedin, externalId: "1", title: "T", company: "C", location: "L",
                           url: "https://www.linkedin.com/jobs/view/1/", receivedAt: received)
        let json = String(decoding: try JSONEncoder().encode([job]), as: UTF8.self)
        #expect(json.contains("\"external_id\":\"1\"") && json.contains("\"received_at\":\"2026-10-02T"))
        #expect(json.contains("\"source\":\"linkedin-alert\""))
    }
}

// MARK: - Importer

actor FakeAlertReader: AlertMailReading {
    var messages: [AlertMailMessage]
    var skipped: [[String]] = []
    var error: Error?
    init(_ messages: [AlertMailMessage]) { self.messages = messages }
    func setError(_ e: Error?) { error = e }
    func alertMessages(account: String, daysBack: Int, skipIDs: [String]) async throws -> [AlertMailMessage] {
        skipped.append(skipIDs.sorted())
        if let error { throw error }
        return messages.filter { !skipIDs.contains($0.id) }
    }
}

actor FakeImportAPI: JobImportAPI {
    var batches: [[AlertJob]] = []
    var known = Set<String>()
    var failure: APIError?
    func setFailure(_ e: APIError?) { failure = e }
    func importJobs(_ jobs: [AlertJob]) async throws -> ImportResult {
        if let failure { throw failure }
        batches.append(jobs)
        var ids: [Int] = [], dups: [Int] = []
        for j in jobs {
            if known.insert(j.externalId).inserted { ids.append(Int(j.externalId.suffix(4)) ?? 0) } else { dups.append(1) }
        }
        return ImportResult(received: jobs.count, imported: ids.count, duplicates: dups.count, invalid: 0,
                            importedIds: ids, duplicateIds: dups)
    }
}

@Suite("Job-Alert importer")
struct JobAlertImporterTests {
    @Test func importsOnceAndRemembersMessages() async throws {
        let reader = FakeAlertReader([try message("linkedin_alert_support", id: "<1@li>"),
                                      try message("linkedin_alert_kundendienst", id: "<2@li>")])
        let api = FakeImportAPI()
        var state = JobAlertState()
        let out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        // 12 jobs in two mails, 2 appear in both → 10 unique are sent
        #expect(out.messages == 2 && out.jobsFound == 12 && out.imported == 10 && out.queued == 0)
        #expect(state.pending.isEmpty && Set(state.processed.keys) == ["<1@li>", "<2@li>"])
        #expect(state.lastSummary?.contains("10 neu importiert") == true)

        let again = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(again.messages == 0 && again.imported == 0)
        #expect(await reader.skipped.last == ["<1@li>", "<2@li>"])
        #expect(await api.batches.count == 1)
    }

    @Test func offlineQueuesAndFlushesLater() async throws {
        let reader = FakeAlertReader([try message("linkedin_alert_support", id: "<1@li>")])
        let api = FakeImportAPI()
        var state = JobAlertState()
        var out = await JobAlertImporter.run(state: &state, reader: reader, api: nil, account: "a", daysBack: 14, now: received)
        #expect(out.queued == 6 && state.pending.count == 6 && state.processed.count == 1)

        await api.setFailure(.unreachable("down"))
        out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(out.queued == 6 && out.serverError != nil && out.messages == 0)

        await api.setFailure(nil)
        out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(out.imported == 6 && out.queued == 0 && state.pending.isEmpty)
    }

    @Test func rejectedBatchIsDroppedAndMailErrorsReported() async throws {
        let reader = FakeAlertReader([try message("linkedin_alert_support", id: "<1@li>")])
        let api = FakeImportAPI()
        await api.setFailure(.server(status: 422, detail: "invalid"))
        var state = JobAlertState()
        let out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(out.invalid == 6 && state.pending.isEmpty)

        await reader.setError(SendError.mail("Keine Berechtigung"))
        let failed = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(failed.mailError?.contains("Keine Berechtigung") == true)
        #expect(failed.summary.hasPrefix("Mail nicht lesbar"))
    }

    @Test func olderServerWithoutImportKeepsQueue() async throws {
        let reader = FakeAlertReader([try message("linkedin_alert_support", id: "<1@li>")])
        let api = FakeImportAPI()
        var state = JobAlertState()
        for failure in [APIError.notFound, .server(status: 405, detail: "Method Not Allowed")] {
            await api.setFailure(failure)
            let out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
            #expect(out.queued == 6 && state.pending.count == 6 && out.invalid == 0)
        }
        await api.setFailure(nil)
        let out = await JobAlertImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, now: received)
        #expect(out.imported == 6 && state.pending.isEmpty)
    }

    @Test func oldProcessedIDsArePruned() async {
        let reader = FakeAlertReader([])
        var state = JobAlertState()
        state.processed = ["<old@x>": received.addingTimeInterval(-200 * 86_400), "<new@x>": received]
        state.parserVersion = JobAlertParser.version
        _ = await JobAlertImporter.run(state: &state, reader: reader, api: nil, account: "a", daysBack: 14, now: received)
        #expect(Array(state.processed.keys) == ["<new@x>"])
    }

    @Test func stateRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jh-alerts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        #expect(store.loadAlertState() == JobAlertState())
        var s = JobAlertState()
        s.processed["<1@x>"] = received
        s.pending = [AlertJob(source: .indeed, externalId: "abcdef0123", title: "T", company: "C", location: "L",
                              url: "https://de.indeed.com/viewjob?jk=abcdef0123", receivedAt: received)]
        s.lastRun = received
        try store.saveAlertState(s)
        #expect(store.loadAlertState() == s)
    }
}

@Suite("StepStone-Alert (echte Mail)")
struct StepStoneAlertTests {
    @Test func parsesJobFromPlainTextBlock() throws {
        let msg = AlertMailMessage(id: "<stepstone-test-1@example.com>", receivedAt: .now,
                                   sender: "Lisa Stein von Stepstone <info@jobagent.stepstone.de>",
                                   subject: "Du bist ein guter Match", source: try eml("stepstone_alert_match"))
        let jobs = JobAlertParser.parse(msg)
        #expect(jobs.count == 1)
        let j = try #require(jobs.first)
        #expect(j.source == "stepstone-alert")
        #expect(j.title == "IT User Support Specialist")
        #expect(j.company == "Greenberg Traurig Germany, LLP")
        #expect(j.location == "Berlin")
        #expect(j.url.hasPrefix("https://click.stepstone.de/"))
        #expect(j.description?.contains("50.000 - 60.000") == true)
        #expect(j.description?.contains("Ihre Aufgaben") == true)   // full posting text from the mail
        #expect((j.description?.count ?? 0) > 300)
        #expect(j.description?.contains("Diesen Job melden") == false)
        #expect(j.externalId == JobAlertParser.stableID("IT User Support Specialist|Greenberg Traurig Germany, LLP"))
    }

    @Test func welcomeMailHasNoJobs() {
        let src = "From: info@email.stepstone.de\nContent-Type: text/plain; charset=utf-8\n\nWillkommen bei Stepstone\n\nSuche starten\nhttps://click.stepstone.de/f/a/x"
        let msg = AlertMailMessage(id: "w", receivedAt: .now, sender: "info@email.stepstone.de", subject: "Willkommen", source: src)
        #expect(JobAlertParser.parse(msg).isEmpty)
    }

    @Test func olderParserVersionRereadsMails() async {
        var state = JobAlertState()
        state.processed = ["<old@x>": .now]
        state.parserVersion = 1
        struct NoMail: AlertMailReading { func alertMessages(account: String, daysBack: Int, skipIDs: [String]) async throws -> [AlertMailMessage] { [] } }
        _ = await JobAlertImporter.run(state: &state, reader: NoMail(), api: nil, account: "a", daysBack: 14)
        #expect(state.processed.isEmpty)
        #expect(state.parserVersion == JobAlertParser.version)
    }
}

@Suite("Links für Alert-Stellen")
struct JobLinksTests {
    private func job(source: String, url: String?, title: String = "IT User Support Specialist",
                     company: String? = "Greenberg Traurig Germany, LLP", location: String? = "Berlin") throws -> JobSummary {
        var dict: [String: Any] = ["id": 61, "title": title, "source": source, "fetched_at": "2026-10-04T08:26:47+00:00",
                                   "score": 60, "status": "neu", "remote": false, "salary_predicted": false,
                                   "also_seen_on": [String](), "has_letter": true]
        if let company { dict["company"] = company }
        if let location { dict["location"] = location }
        if let url { dict["url"] = url }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        return try dec.decode(JobSummary.self, from: data)
    }

    @Test func stepStoneTrackingLinkIsReplacedBySearch() throws {
        let j = try job(source: "stepstone-alert", url: "https://click.stepstone.de/f/a/abc~~/AAAmIhA~/xyz")
        #expect(JobLinks.isTracking(j.link))
        let apply = try #require(JobLinks.applyLink(for: j))
        #expect(apply.absoluteString == "https://www.stepstone.de/jobs/it-user-support-specialist-greenberg-traurig-germany-llp/in-berlin")
        let titles = JobLinks.alternatives(for: j).map(\.title)
        #expect(titles.contains("Auf StepStone suchen"))
        #expect(titles.contains { $0.hasPrefix("Link aus der E-Mail") })
    }

    @Test func normalLinksStay() throws {
        let j = try job(source: "linkedin-alert", url: "https://www.linkedin.com/jobs/view/4300000001/")
        #expect(JobLinks.applyLink(for: j)?.absoluteString == "https://www.linkedin.com/jobs/view/4300000001/")
        #expect(!JobLinks.alternatives(for: j).map(\.title).contains("Auf StepStone suchen"))
    }

    @Test func slugHandlesUmlautsAndGender() {
        #expect(JobLinks.slug("Systemadministrator (m/w/d) Öffentlicher Dienst") == "systemadministrator-oeffentlicher-dienst")
    }
}

@Suite("Auto-Score")
struct AutoScoreTests {
    @Test func decodesInfo() throws {
        let json = #"{"auto_min_score":70,"config_value":80,"overridden":true,"min":50,"max":100}"#
        let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
        let i = try dec.decode(AutoMinScoreInfo.self, from: Data(json.utf8))
        #expect(i.autoMinScore == 70 && i.configValue == 80 && i.overridden && i.min == 50 && i.max == 100)
    }
}
