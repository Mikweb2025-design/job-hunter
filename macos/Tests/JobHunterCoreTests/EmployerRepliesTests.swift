import Foundation
import Testing
@testable import JobHunterCore

private func job(_ id: Int, status: String, applied: String? = "2026-10-01", replyKind: String? = nil,
                 replyAt: String? = nil, docs: String? = nil, email: String? = nil) throws -> JobSummary {
    var obj: [String: Any] = [
        "id": id, "title": "Job \(id)", "company": "Firma \(id)", "source": "arbeitsagentur",
        "fetched_at": "2026-09-01T08:00:00+00:00", "score": 70, "status": status, "remote": false,
        "salary_predicted": false, "also_seen_on": [], "has_letter": true,
    ]
    obj["applied_date"] = applied
    obj["reply_kind"] = replyKind
    obj["reply_at"] = replyAt
    obj["docs_requested"] = docs
    obj["apply_email"] = email
    return try APIClient.decode(JobSummary.self, from: JSONSerialization.data(withJSONObject: obj))
}

private func day(_ s: String) -> Date { Tracker.interviewDate(s + "T12:00")! }

actor FakeReplyReader: EmployerReplyReading {
    var messages: [AlertMailMessage]
    private(set) var lastSenderKeys: [String] = []
    init(_ messages: [AlertMailMessage]) { self.messages = messages }
    func replyMessages(account: String, daysBack: Int, skipIDs: [String], senderKeys: [String],
                       maxCount: Int) async throws -> [AlertMailMessage] {
        lastSenderKeys = senderKeys
        return messages.filter { !skipIDs.contains($0.id) }
    }
}

actor FakeReplyAPI: EmployerReplyAPI {
    var fail: APIError?
    private(set) var received: [EmployerReplyMail] = []
    init(fail: APIError? = nil) { self.fail = fail }
    func setFail(_ e: APIError?) { fail = e }
    func employerReplies(_ items: [EmployerReplyMail]) async throws -> RepliesResult {
        if let fail { throw fail }
        received += items
        return RepliesResult(received: items.count, matched: [7], unmatched: items.count - 1, duplicates: 0, invalid: 0,
                             statusChanged: [], kinds: ["unterlagen": 1, "eingang": items.count - 1])
    }
}

@Suite("Antworten der Firmen")
struct EmployerRepliesTests {
    @Test func rueckfrageAndDocumentsCountAsRueckmeldung() throws {
        let asked = try job(1, status: "beworben", replyKind: "unterlagen", replyAt: "2026-10-05T09:00:00+00:00",
                            docs: "Arbeitszeugnisse, Gehaltsvorstellung")
        let talked = try job(2, status: "beworben", replyKind: "rueckfrage", replyAt: "2026-10-04T09:00:00+00:00")
        let silent = try job(3, status: "beworben")
        #expect(Tracker.hasResponse(asked) && Tracker.hasResponse(talked) && !Tracker.hasResponse(silent))
        #expect(Tracker.openRequests(asked) == ["Arbeitszeugnisse", "Gehaltsvorstellung"])
        #expect(Tracker.nextStep(asked) == "Nachreichen / beantworten: Arbeitszeugnisse, Gehaltsvorstellung")
        #expect(Tracker.nextStep(talked, now: day("2026-10-06")) == "Rückfrage der Firma beantwortet? Dann auf Antwort warten")

        let m = Tracker.metrics([asked, talked, silent], now: day("2026-10-20"))
        #expect(m.applied == 3 && m.responses == 2 && m.responseRate == 67)
        #expect(m.rueckfragen == 2 && m.docsRequested == 1 && m.openRequests == 1 && m.waiting == 1)
        #expect(m.requested.map(\.item) == ["Arbeitszeugnisse", "Gehaltsvorstellung"])
        #expect(m.avgDaysToAnswer == 3.5)
        #expect(Tracker.actionNeeded([asked, talked, silent]).map(\.id) == [1])
    }

    @Test func noFollowUpWhileRequestsAreOpenAndCountFromTheReply() throws {
        let now = day("2026-10-20")
        let open = try job(1, status: "beworben", applied: "2026-10-01", replyKind: "unterlagen",
                           replyAt: "2026-10-03T09:00:00+00:00", docs: "Zeugnis")
        #expect(!Tracker.followUpDue(open, now: now))
        let answered = try job(2, status: "beworben", applied: "2026-10-01", replyKind: "rueckfrage",
                               replyAt: "2026-10-14T09:00:00+00:00")
        #expect(Tracker.followUpFrom(answered) == Tracker.day("2026-10-24"))
        #expect(!Tracker.followUpDue(answered, now: now))
        // closed jobs never show open requests
        let rejected = try job(3, status: "absage", replyKind: "absage", docs: "Zeugnis")
        #expect(Tracker.openRequests(rejected).isEmpty)
    }

    @Test func jobUpdateEncodesReplyFields() throws {
        let set = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JobUpdate(replyKind: .set("rueckfrage")))) as? [String: Any]
        #expect(set?["reply_kind"] as? String == "rueckfrage" && set?["docs_requested"] == nil)
        let clear = String(data: try JSONEncoder().encode(JobUpdate(docsRequested: .clear)), encoding: .utf8)
        #expect(clear == #"{"docs_requested":null}"#)
        let c = PendingChange(jobID: 1, field: .docsRequested, value: nil, base: "Zeugnis", createdAt: .now)
        #expect(c.jobUpdate == JobUpdate(docsRequested: .clear))
        var q = PendingQueue()
        q.record(jobID: 1, field: .replyKind, value: "unterlagen", base: nil, at: .now)
        let s = q.apply(to: try job(1, status: "beworben"))
        #expect(s.replyKind == "unterlagen" && Tracker.hasResponse(s))
    }

    @Test func senderKeysIncludeAppliedDomainsAndATS() throws {
        let keys = EmployerReplyFilter.senderKeys(applied: [
            try job(1, status: "beworben", email: "jobs@zollbeispiel.de"),
            try job(2, status: "neu", applied: nil, email: "hr@nichtbeworben.de"),
        ])
        #expect(keys.contains("@zollbeispiel.de") && keys.contains("personio.de"))
        #expect(!keys.contains("@nichtbeworben.de"))
    }

    @Test func importerSkipsAlertsAndOwnMailsQueuesOfflineAndFlushes() async throws {
        let msgs = [
            AlertMailMessage(id: "<1>", receivedAt: .now, sender: "Zoll <jobs@zollbeispiel.de>",
                             subject: "Deine Bewerbung bei Zoll", source: "Kannst Du uns die Arbeitszeugnisse zukommen lassen?"),
            AlertMailMessage(id: "<2>", receivedAt: .now, sender: "LinkedIn <jobs-noreply@linkedin.com>",
                             subject: "Ihre Bewerbung wurde gesendet", source: "x"),
            AlertMailMessage(id: "<3>", receivedAt: .now, sender: "Ich <info@example.org>", subject: "Bewerbung als X", source: "y"),
            AlertMailMessage(id: "<4>", receivedAt: .now, sender: "HR <karriere@firma.de>", subject: "Eingangsbestätigung Bewerbung", source: "z"),
        ]
        let reader = FakeReplyReader(msgs)
        var state = JobAlertState()
        // offline: queued
        var out = await EmployerReplyImporter.run(state: &state, reader: reader, api: nil, account: "a", daysBack: 14,
                                                  senderKeys: ["personio.de"], ownAddresses: ["info@example.org"])
        #expect(out.mails == 2 && out.queued == 2 && state.pendingReplies?.map(\.messageId) == ["<1>", "<4>"])
        #expect(state.processedReplies?.count == 4)
        // online, nothing new in Mail: the queue goes out
        let api = FakeReplyAPI()
        out = await EmployerReplyImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14,
                                              senderKeys: [])
        #expect(out.mails == 0 && out.queued == 0 && out.matched == 1 && out.requests == 1)
        #expect(await api.received.map(\.messageId) == ["<1>", "<4>"])
        #expect(out.summary == "1 Rückfrage/Unterlagen-Anfrage")
    }

    @Test func olderServerKeepsTheQueue() async throws {
        let reader = FakeReplyReader([AlertMailMessage(id: "<1>", receivedAt: .now, sender: "a@b.de", subject: "Ihre Bewerbung", source: "x")])
        let api = FakeReplyAPI(fail: .notFound)
        var state = JobAlertState()
        let out = await EmployerReplyImporter.run(state: &state, reader: reader, api: api, account: "a", daysBack: 14, senderKeys: [])
        #expect(out.queued == 1 && out.serverError?.contains("Backend aktualisieren") == true)
        await api.setFail(nil)
        let again = await EmployerReplyImporter.run(state: &state, reader: nil, api: api, account: "a", daysBack: 14, senderKeys: [])
        #expect(again.queued == 0 && state.pendingReplies?.isEmpty == true)
    }

    @Test func stepStoneForwardedFeedbackIsAReply() {
        let fwd = AlertMailMessage(id: "<s>", receivedAt: .now, sender: "Stepstone <info@email.stepstone.de>",
                                   subject: "Neuigkeiten zu deiner Bewerbung als IT User Support Specialist bei Beispiel LLP", source: "x")
        let sent = AlertMailMessage(id: "<t>", receivedAt: .now, sender: "Stepstone <info@email.stepstone.de>",
                                    subject: "Daniele, deine Bewerbung als X ist raus", source: "x")
        #expect(EmployerReplyFilter.isCandidate(fwd) && !EmployerReplyFilter.isCandidate(sent))
    }

    @Test func stateDecodesWithoutReplyFields() throws {
        let old = #"{"processed":{},"pending":[]}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(JobAlertState.self, from: old)
        #expect(s.processedReplies == nil && s.pendingReplies == nil)
    }

    @Test func releaseVersionsAndVersionFile() throws {
        #expect(ReleaseVersion.same("1.1.0", "1.1") && ReleaseVersion.same("1.1.0", "1.1.4"))
        #expect(!ReleaseVersion.same("1.1.0", "1.0") && !ReleaseVersion.same(nil, "1.1.0"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: root.appending(path: "VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(v.split(separator: ".").count == 3)
        let h = try APIClient.decode(Health.self, from: Data(#"{"ok":true,"api_version":1,"running":false,"llm_enabled":true,"server_time":"x","version":"1.1.0"}"#.utf8))
        #expect(h.version == "1.1.0" && ReleaseVersion.same(h.version, v))
    }
}
