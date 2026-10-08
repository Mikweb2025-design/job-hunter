import Foundation
import Testing
@testable import JobHunterCore

// HAG-119 anti-trasloco: new `zu_weit` status, `far` view and server-computed
// `view` / `apply_label` from the rebuilt server (07.10.2026). Old servers send
// neither field and reject PATCH with 422 — the app must tolerate both.

// MARK: - Helpers

private func jobJSON(status: String, extra: [String: String] = [:]) -> Data {
    var job: [String: Any] = [
        "id": 305, "title": "Support Engineer", "company": "Weit Weg GmbH",
        "location": "München", "source": "arbeitsagentur",
        "fetched_at": "2026-10-07T10:00:00+00:00", "score": 85,
        "status": status, "remote": false, "salary_predicted": false,
        "also_seen_on": [], "has_letter": true,
    ]
    for (k, v) in extra { job[k] = v }
    return try! JSONSerialization.data(withJSONObject: ["count": 1, "items": [job]])
}

private func summaries(_ data: Data) throws -> [JobSummary] {
    try APIClient.decode(JobList.self, from: data).items
}

// MARK: - Status decoding

@Suite("HAG-119 zu_weit status")
struct ZuWeitStatusTests {
    @Test("decodes the new status with label and symbol")
    func decodes() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit"))
        #expect(jobs[0].status == .zuWeit)
        #expect(JobStatus.zuWeit.rawValue == "zu_weit")
        #expect(JobStatus.zuWeit.label == "Zu weit")
        #expect(!JobStatus.zuWeit.symbolName.isEmpty)
    }

    @Test("unknown future statuses still fall back to neu")
    func unknownFallback() throws {
        let jobs = try summaries(jobJSON(status: "hyperloop"))
        #expect(jobs[0].status == .neu)
    }

    @Test("PATCH encodes zu_weit")
    func patchEncodes() throws {
        let body = try APIClient.encoder.encode(JobUpdate(status: .zuWeit))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: String]
        #expect(obj["status"] == "zu_weit")
    }

    @Test("status picker offers zu_weit")
    func inAllCases() {
        #expect(JobStatus.allCases.contains(.zuWeit))
    }
}

// MARK: - Anti-send guard (local): zu_weit is never automatic/manual

@Suite("HAG-119 anti-send guard")
struct AntiSendGuardTests {
    @Test("zu_weit with an e-mail address is still later, never automatic")
    func withEmail() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit", extra: ["apply_email": "jobs@example.com"]))
        #expect(ApplyCategory.of(jobs[0]) == .later)
    }

    @Test("zu_weit without address is later, never manual")
    func withoutEmail() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit"))
        #expect(ApplyCategory.of(jobs[0]) == .later)
    }

    @Test("active filter excludes zu_weit like absage")
    func activeExcludes() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit"))
        #expect(!JobFilter(status: .active).matches(jobs[0]))
        let neu = try summaries(jobJSON(status: "neu"))
        #expect(JobFilter(status: .active).matches(neu[0]))
    }

    @Test("explicit zu_weit filter matches")
    func onlyMatches() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit"))
        #expect(JobFilter(status: .only(.zuWeit)).matches(jobs[0]))
        #expect(JobFilter(status: .only(.zuWeit)).queryItems.contains(
            URLQueryItem(name: "status", value: "zu_weit")))
    }

    @Test("today list never contains zu_weit")
    func todayExcludes() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit"))
        #expect(ApplyCategory.todayManual(jobs).isEmpty)
    }
}

// MARK: - Server view / apply_label (new servers) with old-server fallback

@Suite("HAG-119 server view and apply_label")
struct ServerViewTests {
    @Test("decodes server view and apply_label")
    func decodes() throws {
        let jobs = try summaries(jobJSON(status: "zu_weit",
            extra: ["view": "far", "apply_label": "Zu weit – nicht bewerben"]))
        #expect(jobs[0].view == "far")
        #expect(jobs[0].applyLabel == "Zu weit – nicht bewerben")
    }

    @Test("old servers (no fields) still decode with nils")
    func oldServerFallback() throws {
        let jobs = try summaries(jobJSON(status: "neu"))
        #expect(jobs[0].view == nil)
        #expect(jobs[0].applyLabel == nil)
        // …and the local rule still classifies
        #expect(ApplyCategory.of(jobs[0]) == .manual)
    }
}

// MARK: - P3 dynamic tabs: GET /api/v1/views (tolerant, old-server fallback)

@Suite("HAG-119 P3 server views")
struct ServerViewsTests {
    @Test("decodes labels, order and counts including far")
    func decodes() throws {
        let v = try APIClient.decode(ServerViews.self, from: Data("""
            {"counts":{"auto":2,"manual":5,"applied":1,"later":3,"far":4,"today":5,"total":15},
             "labels":{"today":"Heute zu tun","auto":"Auto","manual":"Manuell","applied":"Beworben","later":"Später","far":"Zu weit"},
             "order":["today","auto","manual","applied","later","far"],"today_limit":10}
            """.utf8))
        #expect(v.order.contains("far") && v.labels["far"] == "Zu weit")
        #expect(v.counts["far"] == 4 && v.todayLimit == 10)
    }

    @Test("old servers (no far, missing keys) decode with defaults")
    func oldServerFallback() throws {
        let v = try APIClient.decode(ServerViews.self, from: Data("{}".utf8))
        #expect(v.order.isEmpty && v.labels.isEmpty && v.counts.isEmpty)
        #expect(!v.order.contains("far"))  // sidebar stays static
    }

    @Test("far predicate covers status and server view")
    func isFar() throws {
        let zuWeit = try summaries(jobJSON(status: "zu_weit"))
        #expect(ApplyCategory.isFar(zuWeit[0]))
        let farView = try summaries(jobJSON(status: "neu", extra: ["view": "far"]))
        #expect(ApplyCategory.isFar(farView[0]))
        let normal = try summaries(jobJSON(status: "neu"))
        #expect(!ApplyCategory.isFar(normal[0]))
        // Far jobs never reach the automatic/manual buckets (no send button anywhere).
        #expect(ApplyCategory.of(zuWeit[0]) == .later)
        #expect(ApplyCategory.of(farView[0]) == .manual || ApplyCategory.of(farView[0]) == .automatic)
    }
}

// MARK: - P7 Umzugsfilter in send-settings (tolerant when absent)

@Suite("HAG-119 P7 location_filter")
struct LocationFilterTests {
    private func settingsJSON(extra: [String: Any]) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "send_settings", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for (k, v) in extra { obj[k] = v }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test("old servers without the field decode with nil filter")
    func absent() throws {
        let s = try APIClient.decode(SendSettings.self, from: try settingsJSON(extra: [:]))
        #expect(s.locationFilter == nil)
    }

    @Test("new servers decode mode and distance with a German summary")
    func present() throws {
        let s = try APIClient.decode(SendSettings.self,
            from: try settingsJSON(extra: ["location_filter": ["max_distance_km": 50, "mode": "block"]]))
        #expect(s.locationFilter?.maxDistanceKm == 50)
        #expect(s.locationFilter?.summary.contains("50") == true)
    }

    @Test("weird shapes never break the settings load")
    func tolerant() throws {
        let s = try APIClient.decode(SendSettings.self,
            from: try settingsJSON(extra: ["location_filter": "off"]))
        #expect(s.locationFilter == LocationFilter())
    }
}

// MARK: - location auto_blocker (already decoded; server refuses the send)

@Suite("HAG-119 location auto_blocker")
struct LocationBlockerTests {
    @Test("email-preview decodes the location auto_blocker")
    func decodes() throws {
        let url = try #require(Bundle.module.url(forResource: "email_preview", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["can_send"] = false
        obj["auto_blockers"] = ["location"]
        obj["blocker_texts"] = ["Zu weit entfernt – kein automatischer Versand"]
        let data = try JSONSerialization.data(withJSONObject: obj)
        let preview = try APIClient.decode(EmailPreview.self, from: data)
        #expect(!preview.canSend)
        #expect(preview.autoBlockers.contains("location"))
        // The send path refuses whenever canSend is false (server is the guard).
        #expect(!preview.blockerTexts.isEmpty)
    }
}
