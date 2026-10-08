import Foundation
import Testing
@testable import JobHunterCore

/// Builds a JobSummary from the server's JSON shape (only the fields that matter here).
private func job(_ id: Int, status: String, applied: String? = nil, sentAt: String? = nil, statusAt: String? = nil,
                 interview: String? = nil, followUp: String? = nil, reason: String? = nil, source: String = "arbeitsagentur",
                 notes: String? = nil, email: String? = nil) throws -> JobSummary {
    var obj: [String: Any] = [
        "id": id, "title": "Job \(id)", "company": "Firma \(id)", "source": source, "fetched_at": "2026-09-01T08:00:00+00:00",
        "score": 70, "status": status, "remote": false, "salary_predicted": false, "also_seen_on": [], "has_letter": true,
    ]
    obj["applied_date"] = applied
    obj["status_updated_at"] = statusAt
    obj["interview_at"] = interview
    obj["follow_up_at"] = followUp
    obj["close_reason"] = reason
    obj["notes"] = notes
    obj["apply_email"] = email
    if let sentAt { obj["send_state"] = ["state": "sent", "sent_at": sentAt, "to": "jobs@firma.de"] }
    let data = try JSONSerialization.data(withJSONObject: obj)
    return try APIClient.decode(JobSummary.self, from: data)
}

private func date(_ s: String) -> Date { Tracker.interviewDate(s + "T12:00")! }

@Suite("Tracker")
struct TrackerTests {
    @Test func appliedResponseAndChannelRules() throws {
        let manual = try job(1, status: "beworben", applied: "2026-10-01")
        let mailed = try job(2, status: "beworben", sentAt: "2026-10-02T06:00:00+00:00")
        let ownNo = try job(3, status: "absage")                                   // never applied
        let rejected = try job(4, status: "absage", applied: "2026-09-20")
        let dup = try job(5, status: "absage", applied: "2026-09-20", reason: "duplikat")
        let withdrawn = try job(6, status: "absage", applied: "2026-09-20", reason: "kein_interesse")
        let far = try job(7, status: "zu_weit")
        #expect(Tracker.isApplied(manual) && Tracker.isApplied(mailed) && Tracker.isApplied(rejected))
        #expect(!Tracker.isApplied(ownNo) && !Tracker.isApplied(dup) && !Tracker.isApplied(far))
        #expect(Tracker.hasResponse(rejected) && !Tracker.hasResponse(withdrawn) && !Tracker.hasResponse(manual))
        #expect(Tracker.channel(mailed)?.isEmail == true)
        #expect(Tracker.channel(mailed)?.label == "✉ E-Mail gesendet am 02.10.2026")
        #expect(Tracker.channel(manual)?.label == "🖐 manuell beworben am 01.10.2026")
        #expect(Tracker.channel(far) == nil)
        #expect(Tracker.appliedDay(mailed) == Tracker.day("2026-10-02"))
    }

    @Test func followUpAfter14DaysOrAtReminder() throws {
        let now = date("2026-10-20")
        let old = try job(1, status: "beworben", applied: "2026-10-05")      // 15 days
        let fresh = try job(2, status: "beworben", applied: "2026-10-10")
        let snoozed = try job(3, status: "beworben", applied: "2026-09-01", followUp: "2026-10-25")
        let reminder = try job(4, status: "beworben", applied: "2026-10-18", followUp: "2026-10-20")
        let talk = try job(5, status: "gespraech", applied: "2026-09-01")
        #expect(Tracker.followUpDue(old, now: now))
        #expect(!Tracker.followUpDue(fresh, now: now))
        #expect(!Tracker.followUpDue(snoozed, now: now))
        #expect(Tracker.followUpDue(reminder, now: now))
        #expect(!Tracker.followUpDue(talk, now: now))
        #expect(Tracker.followUps([fresh, reminder, old, talk], now: now).map(\.id) == [1, 4])
        #expect(Tracker.nextStep(old, now: now) == "Nachfassen – seit 15 Tagen keine Antwort")
        #expect(Tracker.nextStep(fresh, now: now) == "Auf Antwort warten (Nachfassen ab 24.10.2026)")
    }

    @Test func nextStepForAllStatuses() throws {
        let now = date("2026-10-08")
        #expect(Tracker.nextStep(try job(1, status: "neu"), category: .automatic, now: now).hasPrefix("Wird per E-Mail"))
        #expect(Tracker.nextStep(try job(1, status: "interessant"), category: .manual, now: now) == "Manuell über das Portal bewerben")
        #expect(Tracker.nextStep(try job(1, status: "gespraech"), now: now) == "Gesprächstermin eintragen")
        #expect(Tracker.nextStep(try job(1, status: "gespraech", interview: "2026-10-12T10:30"), now: now)
                == "Gespräch am 12.10.2026 10:30 vorbereiten")
        #expect(Tracker.nextStep(try job(1, status: "gespraech", interview: "2026-10-01T10:30"), now: now)
                == "Rückmeldung nach dem Gespräch abwarten")
        #expect(Tracker.nextStep(try job(1, status: "angebot"), now: now) == "Angebot prüfen und antworten")
        #expect(Tracker.nextStep(try job(1, status: "absage", reason: "duplikat"), now: now) == "Abgeschlossen (Duplikat)")
        #expect(Tracker.nextStep(try job(1, status: "zu_weit"), now: now) == "Kein Umzug – nicht bewerben")
    }

    @Test func metricsKPIsWeeksAndSources() throws {
        let now = date("2026-10-08")   // Thursday, week starts Monday 05.10.
        let jobs = [
            try job(1, status: "beworben", applied: "2026-10-06"),
            try job(2, status: "beworben", sentAt: "2026-10-07T06:00:00+00:00", source: "linkedin-alert"),
            try job(3, status: "gespraech", applied: "2026-09-28", statusAt: "2026-10-02T10:00:00+00:00",
                    interview: "2026-10-12T10:00"),
            try job(4, status: "absage", applied: "2026-09-24", statusAt: "2026-09-28T10:00:00+00:00"),
            try job(5, status: "absage", reason: "duplikat"),
            try job(6, status: "neu"),
            try job(7, status: "zu_weit"),
        ]
        let m = Tracker.metrics(jobs, now: now)
        #expect(m.found == 7 && m.applied == 4 && m.thisWeek == 2)
        #expect(m.byEmail == 1 && m.manual == 3)
        #expect(m.responses == 2 && m.responseRate == 50)
        #expect(m.interviews == 1 && m.offers == 0 && m.rejections == 1 && m.waiting == 2)
        #expect(m.avgDaysToAnswer == 4.0)  // (4 + 4) / 2
        #expect(m.weeks.count == 12)
        #expect(m.weeks.last?.applications == 2)
        #expect(m.weeks.reduce(0) { $0 + $1.applications } == 4)
        #expect(m.weeks.reduce(0) { $0 + $1.responses } == 2)
        #expect(m.bySource.first?.label == "arbeitsagentur" && m.bySource.first?.applications == 3)
        #expect(Tracker.upcomingInterviews(jobs, now: now).map(\.id) == [3])
        #expect(Tracker.column(.absage, in: jobs).count == 2)
        #expect(Tracker.column(.zuWeit, in: jobs).map(\.id) == [7])
    }

    @Test func followUpDraftIsGermanAndOnlyADraft() throws {
        let j = try job(9, status: "beworben", applied: "2026-09-20", email: "hr@firma.de")
        let d = Tracker.followUpDraft(j, applicantName: "Daniele Michelin")
        #expect(d.to == "hr@firma.de")
        #expect(d.subject == "Nachfrage zu meiner Bewerbung als Job 9")
        #expect(d.body.contains("am 20.09.2026 habe ich mich bei Ihnen als Job 9 beworben"))
        #expect(d.body.hasSuffix("Daniele Michelin"))
        let url = try #require(d.mailtoURL)
        #expect(url.scheme == "mailto" && url.absoluteString.contains("hr@firma.de?subject=Nachfrage"))
        let sent = try job(10, status: "beworben", sentAt: "2026-09-20T06:00:00+00:00")
        #expect(Tracker.followUpDraft(sent, applicantName: "X").to == "jobs@firma.de")
    }

    @Test func icsAndNoteHelpers() throws {
        let start = try #require(Tracker.interviewDate("2026-10-12T10:00"))
        let ics = Tracker.icsEvent(title: "Support, Engineer", company: "ACME", start: start, uid: "u1")
        #expect(ics.contains("BEGIN:VEVENT") && ics.contains("DTSTART:20261012T080000Z"))  // 10:00 Berlin (CEST) = 08:00 UTC
        #expect(ics.contains("SUMMARY:Vorstellungsgespräch: Support\\, Engineer – ACME"))
        #expect(Tracker.interviewString(start) == "2026-10-12T10:00")
        #expect(Tracker.appendNote("", "A") == "A" && Tracker.appendNote("X\n", "A") == "X\nA")
    }

    @Test func trackerFieldsDecodeEncodeAndQueue() throws {
        let j = try job(3, status: "absage", applied: "2026-09-01", interview: "2026-10-12T10:00", followUp: "2026-10-20",
                        reason: "duplikat", notes: "Notiz")
        #expect(j.interviewAt == "2026-10-12T10:00" && j.followUpAt == "2026-10-20" && j.closeReason == "duplikat")
        #expect(j.notes == "Notiz")
        // PATCH bodies
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let set = String(data: try enc.encode(JobUpdate(interviewAt: .set("2026-10-12T10:00"))), encoding: .utf8)
        #expect(set == #"{"interview_at":"2026-10-12T10:00"}"#)
        let clear = String(data: try enc.encode(JobUpdate(followUpAt: .clear, closeReason: .clear)), encoding: .utf8)
        #expect(clear == #"{"close_reason":null,"follow_up_at":null}"#)
        // Offline queue applies the new fields locally and builds the PATCH
        var q = PendingQueue()
        q.record(jobID: 3, field: .interviewAt, value: "2026-11-01T09:00", base: j.interviewAt, at: .now)
        q.record(jobID: 3, field: .notes, value: "Neu", base: "Notiz", at: .now)
        q.record(jobID: 3, field: .status, value: "beworben", base: "absage", at: .now)
        let local = q.apply(to: j)
        #expect(local.interviewAt == "2026-11-01T09:00" && local.notes == "Neu" && local.status == .beworben)
        #expect(local.closeReason == nil)  // leaving "absage" clears the reason (like the server)
        #expect(q.changes.first { $0.field == .interviewAt }?.jobUpdate == JobUpdate(interviewAt: .set("2026-11-01T09:00")))
        #expect(PendingChange(jobID: 1, field: .followUpAt, value: nil, base: "x", createdAt: .now).jobUpdate
                == JobUpdate(followUpAt: .clear))
    }
}
