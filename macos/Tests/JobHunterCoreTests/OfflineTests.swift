import Foundation
import Testing
@testable import JobHunterCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func detail() throws -> JobDetail { try APIClient.decode(JobDetail.self, from: fixtureData("job_detail")) }
private func jobs(_ name: String = "jobs_with_mail") throws -> [JobSummary] {
    try APIClient.decode(JobList.self, from: fixtureData(name)).items
}

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "jh-test-\(UUID().uuidString)", directoryHint: .isDirectory)
}

// MARK: - Cache encode/decode

@Suite("Offline cache")
struct CacheTests {
    @Test func snapshotRoundTripThroughDisk() throws {
        let d = try detail()
        let settings = try APIClient.decode(SendSettings.self, from: fixtureData("send_settings"))
        let sent = try APIClient.decode(SentList.self, from: fixtureData("sent")).items
        let stats = try APIClient.decode(Stats.self, from: fixtureData("stats"))
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let snap = CacheSnapshot(savedAt: saved, serverURL: "https://example.org/jobs", jobs: try jobs(),
                                 details: [d.id: d], stats: stats, sendSettings: settings, sentLog: sent,
                                 letterOrigins: [4: LocalLetterOrigin(origin: "KI (opencode)", text: "x", at: saved)])
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        #expect(store.loadSnapshot() == nil)
        try store.saveSnapshot(snap)
        let back = try #require(store.loadSnapshot())
        #expect(back == snap)
        #expect(back.details[4]?.notes == "Über das Portal beworben")
        #expect(back.details[4]?.scoreBreakdown.matched.contains("Python") == true)
        #expect(back.jobs.first { $0.id == 7 }?.sendState?.isSent == true)
        #expect(back.sendSettings?.dryRun == settings.dryRun)
        #expect(back.letterOrigins[4]?.origin == "KI (opencode)")
    }

    @Test func detailEncodesFlat() throws {
        let d = try detail()
        let data = try JSONEncoder().encode(d)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["title"] as? String == d.summary.title)   // summary fields at top level
        #expect(obj["notes"] as? String == d.notes)
        #expect(try JSONDecoder().decode(JobDetail.self, from: data) == d)
    }

    @Test func olderCacheWithoutNewFieldsStillLoads() throws {
        let json = #"{"savedAt":"2026-10-03T10:00:00Z","serverURL":"https://x"}"#
        let snap = try LocalStore.decoder.decode(CacheSnapshot.self, from: Data(json.utf8))
        #expect(snap.jobs.isEmpty && snap.details.isEmpty && snap.sentLog.isEmpty)
    }

    @Test func perServerDirectory() {
        let base = URL(fileURLWithPath: "/tmp/jh")
        #expect(LocalStore.directory(forServer: "https://mikweb.eu/jobs", base: base).lastPathComponent == "mikweb.eu_jobs")
        #expect(LocalStore.directory(forServer: "http://127.0.0.1:8765", base: base).lastPathComponent == "127.0.0.1_8765")
    }

    @Test func corruptFilesFallBackToEmpty() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: dir.appending(path: "cache.json"))
        try Data("nope".utf8).write(to: dir.appending(path: "pending.json"))
        let store = LocalStore(directory: dir)
        #expect(store.loadSnapshot() == nil)
        #expect(store.loadQueue().isEmpty)
    }
}

// MARK: - Queue

@Suite("Pending queue")
struct QueueTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func coalescesSameFieldKeepsBase() {
        var q = PendingQueue()
        q.record(jobID: 1, field: .notes, value: "a", base: "", at: t0)
        q.record(jobID: 1, field: .notes, value: "ab", base: "a", at: t0.addingTimeInterval(5))
        #expect(q.count == 1)
        #expect(q.changes[0].value == "ab")
        #expect(q.changes[0].base == "")
        #expect(q.changes[0].createdAt == t0.addingTimeInterval(5))
    }

    @Test func revertingToBaseCancels() {
        var q = PendingQueue()
        q.record(jobID: 1, field: .status, value: "beworben", base: "neu", at: t0)
        q.record(jobID: 1, field: .status, value: "neu", base: "beworben", at: t0 + 1)
        #expect(q.isEmpty)
        q.record(jobID: 1, field: .status, value: "neu", base: "neu", at: t0)
        #expect(q.isEmpty)
    }

    @Test func orderedByEditTime() {
        var q = PendingQueue()
        q.record(jobID: 2, field: .status, value: "interessant", base: "neu", at: t0 + 10)
        q.record(jobID: 1, field: .notes, value: "x", base: "", at: t0)
        q.record(jobID: 3, field: .letter, value: "L", base: "", at: t0 + 10)  // same time: insertion order
        q.record(jobID: 1, field: .notes, value: "xy", base: "", at: t0 + 20)  // re-edit moves to the end
        #expect(q.ordered.map(\.jobID) == [2, 3, 1])
    }

    @Test func persistsAndKeepsSequence() throws {
        var q = PendingQueue()
        q.record(jobID: 1, field: .appliedDate, value: nil, base: "2026-10-01", at: t0)
        q.record(jobID: 1, field: .letter, value: "Text", base: "", at: t0, origin: "KI (opencode)", title: "Job")
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(directory: dir)
        try store.saveQueue(q)
        var back = store.loadQueue()
        #expect(back == q)
        #expect(back.changes[1].origin == "KI (opencode)")
        back.record(jobID: 9, field: .notes, value: "n", base: "", at: t0)
        #expect(back.changes.last!.seq > q.changes.map(\.seq).max()!)
    }

    @Test func overlayAppliesLocalValues() throws {
        let d = try detail()
        var q = PendingQueue()
        q.record(jobID: d.id, field: .status, value: "gespraech", base: "beworben", at: t0)
        q.record(jobID: d.id, field: .notes, value: "Telefonat Montag", base: d.notes, at: t0)
        q.record(jobID: d.id, field: .letter, value: "Neuer Text", base: d.letter, at: t0, origin: "KI (opencode)")
        q.record(jobID: 999, field: .notes, value: "andere Stelle", base: "", at: t0)
        let local = q.apply(to: d)
        #expect(local.summary.status == .gespraech)
        #expect(local.notes == "Telefonat Montag")
        #expect(local.letter == "Neuer Text")
        #expect(local.summary.letterOrigin == "KI (opencode)")
        #expect(q.apply(to: d.summary).status == .gespraech)
    }

    @Test func patchBodies() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        func body(_ f: PendingField, _ v: String?) throws -> String {
            let c = PendingChange(jobID: 1, field: f, value: v, base: nil, createdAt: t0)
            return String(decoding: try enc.encode(try #require(c.jobUpdate)), as: UTF8.self)
        }
        #expect(try body(.status, "beworben") == #"{"status":"beworben"}"#)
        #expect(try body(.appliedDate, nil) == #"{"applied_date":null}"#)
        #expect(try body(.appliedDate, "2026-10-03") == #"{"applied_date":"2026-10-03"}"#)
        #expect(try body(.notes, "n") == #"{"notes":"n"}"#)
        #expect(PendingChange(jobID: 1, field: .letter, value: "x", base: nil, createdAt: t0).jobUpdate == nil)
    }
}

// MARK: - Conflict rule

@Suite("Conflict rule")
struct ConflictTests {
    // Fixture: status beworben, status_updated_at 2026-10-03T10:01:26Z, letter_updated_at same.
    let serverStatusChange = ServerDate.parse("2026-10-03T10:01:26+00:00")!

    @Test func localWinsWhenServerUnchanged() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .status, value: "gespraech", base: "beworben",
                              createdAt: serverStatusChange.addingTimeInterval(-3600))
        #expect(ConflictResolver.decide(c, server: d) == .apply)
    }

    @Test func serverWinsWhenChangedLater() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .status, value: "absage", base: "neu",
                              createdAt: serverStatusChange.addingTimeInterval(-60))
        #expect(ConflictResolver.decide(c, server: d) == .serverNewer)
    }

    @Test func localWinsWhenServerChangedEarlier() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .status, value: "absage", base: "neu",
                              createdAt: serverStatusChange.addingTimeInterval(60))
        #expect(ConflictResolver.decide(c, server: d) == .apply)
    }

    @Test func alreadyInSync() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .notes, value: d.notes + "  ", base: "", createdAt: .now)
        #expect(ConflictResolver.decide(c, server: d) == .alreadyInSync)
    }

    @Test func notesWithoutTimestampLocalWins() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .notes, value: "lokal", base: "alt", createdAt: .distantPast)
        #expect(ConflictResolver.decide(c, server: d) == .apply)
    }

    @Test func letterChangedOnServerLater() throws {
        let d = try detail()
        let c = PendingChange(jobID: 4, field: .letter, value: "lokal", base: "ganz alt",
                              createdAt: ServerDate.parse(d.letterUpdatedAt)!.addingTimeInterval(-10))
        #expect(ConflictResolver.decide(c, server: d) == .serverNewer)
    }
}

// MARK: - Replay

actor FakeSyncAPI: JobSyncAPI {
    var details: [Int: JobDetail]
    var calls: [String] = []
    var failAfter: Int?          // calls allowed before the server goes down
    var rejectID: Int?

    init(details: [Int: JobDetail]) { self.details = details }

    func setFailAfter(_ n: Int?) { failAfter = n }
    func setReject(_ id: Int?) { rejectID = id }

    private func gate(_ call: String) throws {
        if let n = failAfter, calls.count >= n { throw APIError.unreachable("down") }
        calls.append(call)
    }

    func job(id: Int) async throws -> JobDetail {
        try gate("GET \(id)")
        if id == rejectID { throw APIError.notFound }
        guard let d = details[id] else { throw APIError.notFound }
        return d
    }

    func update(id: Int, _ update: JobUpdate) async throws -> JobDetail {
        try gate("PATCH \(id)")
        var d = details[id]!
        if let s = update.status { d.summary.status = s }
        if let n = update.notes { d.notes = n }
        switch update.appliedDate {
        case .set(let v): d.summary.appliedDate = v
        case .clear: d.summary.appliedDate = nil
        case nil: break
        }
        details[id] = d
        return d
    }

    func saveDescription(id: Int, text: String) async throws -> JobDetail {
        try gate("PUT description \(id)")
        var d = details[id]!
        d.description = text
        details[id] = d
        return d
    }

    func saveLetter(id: Int, text: String) async throws -> JobDetail {
        try gate("PUT \(id)")
        var d = details[id]!
        d.letter = text
        d.summary.letterOrigin = "manuell"
        details[id] = d
        return d
    }
}

@Suite("Replay")
struct ReplayTests {
    func setup() throws -> (FakeSyncAPI, PendingQueue, JobDetail) {
        var a = try detail()
        var b = a
        b.summary.id = 5
        b.summary.status = .neu
        b.summary.statusUpdatedAt = nil
        a.notes = ""
        let api = FakeSyncAPI(details: [4: a, 5: b])
        let t = ServerDate.parse("2026-10-04T08:00:00+00:00")!   // after all server timestamps
        var q = PendingQueue()
        q.record(jobID: 5, field: .status, value: "interessant", base: "neu", at: t)
        q.record(jobID: 4, field: .notes, value: "Notiz", base: "", at: t + 1)
        q.record(jobID: 4, field: .letter, value: "Brief", base: a.letter, at: t + 2, origin: "KI (opencode)")
        q.record(jobID: 5, field: .notes, value: "B", base: b.notes, at: t + 3)
        return (api, q, a)
    }

    @Test func replaysInOrderAndOnlyFetchesEachJobOnce() async throws {
        let (api, q, _) = try setup()
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.stoppedError == nil)
        #expect(r.done.count == 4)
        #expect(await api.calls == ["GET 5", "PATCH 5", "GET 4", "PATCH 4", "PUT 4", "PATCH 5"])
        #expect(r.details[4]?.letter == "Brief")
        #expect(r.details[5]?.summary.status == .interessant)
        #expect(r.finishedIDs == Set(q.changes.map(\.id)))
    }

    @Test func stopsWhenServerGoesDownAndKeepsRest() async throws {
        let (api, q, _) = try setup()
        await api.setFailAfter(3)   // GET 5, PATCH 5, GET 4 succeed; PATCH 4 fails
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.done.count == 1)
        #expect(r.stoppedError != nil)
        var rest = q
        rest.removeAll(ids: r.finishedIDs)
        #expect(rest.ordered.map(\.field) == [.notes, .letter, .notes])
        #expect(rest.ordered.first?.jobID == 4)
    }

    @Test func serverNewerIsDroppedAsConflict() async throws {
        var d = try detail()
        d.summary.status = .absage
        d.summary.statusUpdatedAt = "2026-10-05T00:00:00+00:00"
        let api = FakeSyncAPI(details: [4: d])
        var q = PendingQueue()
        q.record(jobID: 4, field: .status, value: "gespraech", base: "beworben",
                 at: ServerDate.parse("2026-10-04T00:00:00+00:00")!)
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.conflicts.count == 1 && r.done.isEmpty)
        #expect(await api.calls == ["GET 4"])
    }

    @Test func permanentErrorDropsOnlyThatChange() async throws {
        let (api, q, _) = try setup()
        await api.setReject(5)
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.rejected.count == 2)
        #expect(r.done.count == 2)
        #expect(r.stoppedError == nil)
    }

    @Test func pastedPostingTextIsQueuedAndReplayed() async throws {
        let d = try detail()
        let api = FakeSyncAPI(details: [4: d])
        let text = String(repeating: "Anzeigentext ", count: 30)
        var q = PendingQueue()
        q.record(jobID: 4, field: .description, value: text, base: d.description, at: .now)
        let local = q.apply(to: d)
        #expect(local.description == text && local.hasPostingText)
        #expect(local.summary.descriptionLength == text.trimmingCharacters(in: .whitespaces).count)
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.done.count == 1 && r.details[4]?.description == text)
        #expect(await api.calls == ["GET 4", "PUT description 4"])
    }

    @Test func descriptionOnOlderServerStaysQueued() async throws {
        let d = try detail()
        let api = OldServerAPI(detail: d)
        var q = PendingQueue()
        q.record(jobID: 4, field: .description, value: "Text", base: d.description, at: .now)
        let r = await SyncEngine.replay(q, api: api)
        #expect(r.deferred.count == 1 && r.rejected.isEmpty && r.finishedIDs.isEmpty && r.stoppedError == nil)
    }

    @Test func transientClassification() {
        #expect(SyncEngine.isTransient(APIError.unreachable("x")))
        #expect(SyncEngine.isTransient(APIError.server(status: 503, detail: nil)))
        #expect(!SyncEngine.isTransient(APIError.server(status: 422, detail: nil)))
        #expect(!SyncEngine.isTransient(APIError.notFound))
    }
}

// MARK: - Categories / local filter

@Suite("Apply categories")
struct CategoryTests {
    @Test func categories() throws {
        let all = try jobs()
        let cat = Dictionary(uniqueKeysWithValues: all.map { ($0.id, ApplyCategory.of($0)) })
        #expect(cat[6] == .automatic)   // jobs@acme.de, neu
        #expect(cat[7] == .applied)     // sent
        #expect(cat[4] == .applied)     // beworben
        #expect(cat[3] == .manual)      // no address
        var rejected = all.first { $0.id == 3 }!
        rejected.status = .absage
        #expect(ApplyCategory.of(rejected) == .later)
    }

    @Test func blocklistMakesItManual() throws {
        var acme = try jobs().first { $0.id == 6 }!
        #expect(ApplyCategory.of(acme, blocklist: ["ACME"]) == .manual)
        acme.company = nil
        #expect(ApplyCategory.of(acme, blocklist: ["ACME"]) == .automatic)
    }

    @Test func todayIsManualByScore() throws {
        let today = ApplyCategory.todayManual(try jobs(), limit: 2)
        #expect(today.map(\.id) == [3, 1])
    }

    @Test func localFilterMatchesServerSemantics() throws {
        let all = try jobs()
        let now = ServerDate.parse("2026-10-03T12:00:00+00:00")!
        func ids(_ f: JobFilter) -> [Int] { all.filter { f.matches($0, now: now) }.map(\.id) }
        #expect(ids(JobFilter(status: .only(.beworben))) == [4, 7])
        #expect(ids(JobFilter(status: .all, minScore: 80)) == [4, 6, 7])
        #expect(ids(JobFilter(status: .all, query: "acme")) == [6])
        let d = try detail()
        #expect(JobFilter(status: .all, query: "fastapi").matches(d.summary, description: d.description + " FastAPI", now: now))
    }
}

// MARK: - Letters (opencode)

@Suite("KI-Anschreiben")
struct LetterTests {
    let profile = """
    # Profil
    <!-- Hinweis für den Editor -->
    - Technischer Support für eine Nextcloud-Plattform mit rund 15.000 Instanzen
    - rund 200 Tickets pro Woche, seit 2008 bei IONOS/STRATO
    """

    @Test func promptContainsRulesProfileAndPosting() throws {
        let d = try detail()
        let p = LetterPrompt.build(cvProfile: profile, job: d)
        #expect(p.contains("3 bis 4 kurze Absätze"))
        #expect(p.contains("ersten 90 Tagen"))
        #expect(p.contains("Erfinde NIEMALS Zahlen"))
        #expect(p.contains("Gib ausschließlich den Brieftext aus"))
        #expect(p.contains("15.000 Instanzen"))
        #expect(!p.contains("Hinweis für den Editor"))
        #expect(p.contains("Titel: \(LetterFormatting.letterTitle(d.summary.title, company: d.summary.company))"))
        #expect(p.contains("Unternehmen: Beispiel Cloud GmbH"))
        #expect(p.contains("Gehalt: 52000 – 62000 EUR/Jahr"))
        #expect(p.contains(String(d.description.prefix(80))))
    }

    @Test func promptTruncatesLongPosting() throws {
        var d = try detail()
        d.description = String(repeating: "x", count: 20_000) + "ENDE"
        #expect(!LetterPrompt.build(cvProfile: profile, job: d).contains("ENDE"))
    }

    let good = """
    Bei IONOS/STRATO betreue ich seit 2008 den technischen Support für eine Nextcloud-Plattform mit rund 15.000 Instanzen und kenne die Anforderungen an einen verlässlichen Cloud-Support aus erster Hand.

    Dort löse ich im Second- und Third-Level-Support komplexe Linux-Fälle, analysiere Störungen bis zur Ursache und schreibe FAQ-Artikel, damit Kolleginnen und Kollegen wiederkehrende Anfragen selbst lösen können.

    Ihre Stelle reizt mich, weil Sie ausdrücklich Erfahrung mit Objektspeicher suchen. In den ersten 90 Tagen würde ich mich in Ihr Ticket-System einarbeiten und die häufigsten Anfragen dokumentieren.

    Über die Einladung zu einem persönlichen Gespräch freue ich mich.
    """

    @Test func cleansPlainOutputWithANSIAndHeader() throws {
        let raw = "\u{1B}[0m\n> build · big-pickle\n\u{1B}[0m\n\u{1B}[1m" + good + "\u{1B}[0m\n"
        #expect(try LetterOutputCleaner.clean(raw) == good)
    }

    @Test func extractsTextFromJSONEvents() throws {
        let ev: [[String: Any]] = [
            ["type": "step_start", "part": ["type": "step-start"]],
            ["type": "text", "part": ["type": "text", "text": "Ich lese kurz nach."]],
            ["type": "tool_use", "part": ["type": "tool", "tool": "read"]],
            ["type": "text", "part": ["type": "text", "text": "\"" + good + "\""]],
            ["type": "step_finish", "part": ["type": "step-finish"]],
        ]
        let raw = try ev.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n")
        #expect(try LetterOutputCleaner.clean(raw) == good)
    }

    @Test func dropsSalutationClosingAndPreamble() throws {
        let raw = "Hier ist das Anschreiben:\n\n```\nSehr geehrte Damen und Herren,\n\n" + good +
            "\n\nMit freundlichen Grüßen\nDaniele Michelin\n```"
        #expect(try LetterOutputCleaner.clean(raw) == good)
    }

    @Test func rejectsPlaceholdersShortAndEmpty() {
        #expect(throws: LetterRejection.placeholder) {
            try LetterOutputCleaner.clean(good + " [Firmenname ergänzen]")
        }
        #expect(throws: LetterRejection.tooShort(21)) { try LetterOutputCleaner.clean("Ich bewerbe mich.  \n\n Ok") }
        #expect(throws: LetterRejection.empty) { try LetterOutputCleaner.clean("\u{1B}[0m\n> build · x\n") }
    }

    @Test func rejectsInventedNumbers() throws {
        let invented = good.replacingOccurrences(of: "15.000", with: "40.000")
        #expect(throws: LetterRejection.inventedNumbers(["40000"])) {
            try LetterOutputCleaner.clean(invented, sources: [profile])
        }
        #expect(try LetterOutputCleaner.clean(good, sources: [profile]) == good)
    }

    @Test func requiresParagraphsLengthAndNoFloskel() throws {
        let onePar = LetterOutputCleaner.paragraphs(good).joined(separator: " ")
        #expect(throws: LetterRejection.tooFewParagraphs) { try LetterOutputCleaner.clean(onePar) }
        // single line breaks between paragraphs are accepted and normalized
        #expect(try LetterOutputCleaner.clean(good.replacingOccurrences(of: "\n\n", with: "\n")) == good)
        let long = good + "\n\n" + String(repeating: "Ich ergänze noch viele Details. ", count: 60)
        #expect(throws: LetterRejection.tooLong(LetterOutputCleaner.normalizeParagraphs(long).count)) {
            try LetterOutputCleaner.clean(long)
        }
        #expect(throws: LetterRejection.floskel) { try LetterOutputCleaner.clean("Hiermit bewerbe ich mich. " + good) }
        let bracket = good.replacingOccurrences(of: "IONOS/STRATO", with: "]init[ AG")
        #expect(try LetterOutputCleaner.clean(bracket, company: "]init[ AG") == bracket)
        #expect(throws: LetterRejection.placeholder) { try LetterOutputCleaner.clean(bracket) }
    }

    @Test func rulesMatchBackend() throws {
        // LETTER_RULES in ~/job-hunter/jobhunter/llm.py must stay identical (checked when the repo is there).
        let path = NSHomeDirectory() + "/job-hunter/jobhunter/llm.py"
        guard let py = try? String(contentsOfFile: path, encoding: .utf8),
              let start = py.range(of: "LETTER_RULES = \"\"\""),
              let end = py.range(of: "\"\"\"", range: start.upperBound..<py.endIndex) else { return }
        #expect(String(py[start.upperBound..<end.lowerBound]) == LetterPrompt.rules)
    }

    @Test func parsesModelList() {
        let out = "\u{1B}[0mopencode/big-pickle\nollama/maternion/spark-x2.5:4b-q4_K_M\n\nsome warning text\nopencode/big-pickle\n"
        #expect(OpencodeRunner.parseModels(out) == ["opencode/big-pickle", "ollama/maternion/spark-x2.5:4b-q4_K_M"])
    }

    @Test func missingExecutableIsReported() async {
        let r = OpencodeRunner(executable: "/nonexistent/opencode", timeout: 1)
        await #expect(throws: OpencodeError.notInstalled("/nonexistent/opencode")) {
            _ = try await r.writeLetter(model: "x/y", prompt: "p")
        }
    }

    @Test func timeoutKillsProcess() async throws {
        // /bin/sleep stands in for a hanging CLI.
        let r = OpencodeRunner(executable: "/bin/sleep", timeout: 1)
        let start = Date()
        await #expect(throws: OpencodeError.timeout(1)) { _ = try await r.run(["30"]) }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

// MARK: - End-to-end (opt-in): really runs opencode once on a real job

@Suite("opencode end-to-end")
struct OpencodeE2ETests {
    /// `JOBHUNTER_E2E_JOB=/path/job.json` (an `/api/v1/jobs/{id}` response) enables it;
    /// optional `JOBHUNTER_E2E_MODEL`. Only generates text, sends nothing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JOBHUNTER_E2E_JOB"] != nil))
    func writesALetterForARealJob() async throws {
        let env = ProcessInfo.processInfo.environment
        let job = try APIClient.decode(JobDetail.self, from: Data(contentsOf: URL(fileURLWithPath: env["JOBHUNTER_E2E_JOB"]!)))
        let profile = try String(contentsOfFile: LetterPrompt.defaultCVProfilePath, encoding: .utf8)
        let prompt = LetterPrompt.build(cvProfile: profile, job: job)
        let model = env["JOBHUNTER_E2E_MODEL"] ?? OpencodeRunner.defaultModel
        let start = Date()
        let raw = try await OpencodeRunner(timeout: 120).writeLetter(model: model, prompt: prompt)
        let secs = Date().timeIntervalSince(start)
        print("E2E raw output (\(raw.count) chars, \(String(format: "%.1f", secs)) s)")
        let letter = try LetterOutputCleaner.clean(raw, sources: [profile, job.description, job.summary.title, job.summary.company ?? ""])
        print("E2E model=\(model) duration=\(String(format: "%.1f", secs))s job=\(job.summary.title)\n---\n\(letter)\n---")
        #expect(!letter.contains("["))
        #expect(letter.count >= LetterOutputCleaner.minLength)
    }
}

/// Server before the "Anzeigentext einfügen" endpoint: jobs exist, PUT /description is 404.
struct OldServerAPI: JobSyncAPI {
    let detail: JobDetail
    func job(id: Int) async throws -> JobDetail { detail }
    func update(id: Int, _ update: JobUpdate) async throws -> JobDetail { detail }
    func saveLetter(id: Int, text: String) async throws -> JobDetail { detail }
}
