import AppKit
import JobHunterCore
import Observation
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case today, recent, automatic, manual, applied, later, jobs, tracker, outbox
    var id: String { rawValue }

    var category: ApplyCategory? {
        switch self {
        case .automatic: .automatic
        case .manual: .manual
        case .applied: .applied
        case .later: .later
        default: nil
        }
    }
}

enum ConnectionState: Equatable {
    case unknown
    case ok
    case notConfigured
    case failed(String)
}

/// Progress of "Anschreiben mit KI schreiben" (single job or batch).
struct LetterJob: Equatable {
    var total: Int
    var done = 0
    var failed = 0
    var currentTitle: String?
    var startedAt = Date.now
}

/// Shared app state: data (server + local cache), offline queue, filters, menu-bar data,
/// periodic refresh, run trigger, e-mail sending, KI letters.
///
/// Offline model: every successful fetch is written to Application Support/JobHunter/cache.json.
/// Edits (status, notes, applied date, letter) always go into a pending queue
/// (pending.json) first and are replayed to the server whenever it is reachable
/// (`SyncEngine`, conflict rule in `ConflictResolver`). Nothing is ever *sent* (e-mail)
/// without the server.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    private(set) var store: LocalStore

    // Navigation
    var sidebarSelection: SidebarItem? = .today
    var selectedJobID: Int?

    // Data (server state as last seen; `allJobs`/`jobs` include pending local edits)
    private(set) var serverJobs: [JobSummary] = []
    private(set) var allJobs: [JobSummary] = []
    private(set) var jobs: [JobSummary] = []              // "Alle Stellen" with the filter applied
    private(set) var details: [Int: JobDetail] = [:]       // server versions of opened jobs
    private(set) var stats: Stats?
    private(set) var highScoreNew: [JobSummary] = []      // menu bar
    private(set) var sources: [String] = []
    private(set) var letterOrigins: [Int: LocalLetterOrigin] = [:]

    // Offline / sync
    private(set) var queue = PendingQueue()
    /// Time of the last successful fetch (also the time of the cached data).
    private(set) var dataDate: Date?
    private(set) var isSyncing = false
    private(set) var lastSyncProblem: String?

    // State
    private(set) var connection: ConnectionState = .unknown
    private(set) var isLoading = false
    private(set) var isRunActive = false
    private(set) var lastRefresh: Date?
    var transientMessage: String?

    // E-mail applications
    private(set) var sendSettings: SendSettings?
    private(set) var sentLog: [SentEntry] = []
    private(set) var outbox: Outbox?
    private(set) var sendFailures: [SendFailure] = []
    private(set) var isSending = false
    private(set) var lastSendError: String?
    /// Bumped after every send so open detail views reload their preview.
    private(set) var sendGeneration = 0
    let mailSender: MailSending

    // KI letters
    private(set) var letterJob: LetterJob?
    private(set) var letterJobIDs: Set<Int> = []
    private var letterBatch: Task<Void, Never>?
    private(set) var availableModels: [String] = OpencodeRunner.fallbackModels

    // Job-Alerts (LinkedIn/StepStone/Indeed e-mails in Apple Mail, read-only)
    private(set) var alertState = JobAlertState()
    private(set) var isImportingAlerts = false
    private(set) var lastAlertOutcome: JobAlertOutcome?
    let alertReader: AlertMailReading

    var filter = JobFilter() {
        didSet { if filter != oldValue { rebuildLists() } }
    }

    private var refreshLoop: Task<Void, Never>?
    private var runPoll: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init(settings: AppSettings, mailSender: MailSending = AppleMailSender(), store: LocalStore? = nil,
         alertReader: AlertMailReading = AppleMailAlertReader()) {
        self.settings = settings
        self.mailSender = mailSender
        self.alertReader = alertReader
        let key = ServerConfig.normalizedURL(settings.serverURL)?.absoluteString ?? settings.serverURL
        self.store = store ?? LocalStore(directory: LocalStore.directory(forServer: key))
        loadLocalState()
    }

    var bannerKind: SendBannerKind {
        SendBannerKind.from(connection == .ok ? sendSettings : nil, autoSendEnabled: settings.autoSendEnabled)
    }

    private var coordinator: SendCoordinator? {
        client.map { SendCoordinator(api: $0, sender: mailSender, ledger: settings.ledger, attachmentPath: settings.cvPath) }
    }

    var client: APIClient? { settings.serverConfig.map { APIClient(config: $0) } }

    var errorMessage: String? {
        switch connection {
        case .failed(let msg): msg
        case .notConfigured: APIError.notConfigured.errorDescription
        default: nil
        }
    }

    var isOnline: Bool { connection == .ok }
    /// Server not reachable (or failing) and we show cached data.
    var isOffline: Bool { if case .failed = connection { true } else { false } }
    var pendingCount: Int { queue.count }
    var blocklist: [String] { sendSettings?.blocklist ?? [] }

    // MARK: Local state (cache + queue)

    private var serverKey: String {
        ServerConfig.normalizedURL(settings.serverURL)?.absoluteString ?? settings.serverURL
    }

    private func loadLocalState() {
        queue = store.loadQueue()
        alertState = store.loadAlertState()
        guard let snap = store.loadSnapshot(), snap.serverURL == serverKey else {
            rebuildLists()
            return
        }
        serverJobs = snap.jobs
        details = snap.details
        stats = snap.stats
        sources = Self.withAlertSources(snap.stats?.sources ?? [])
        sendSettings = snap.sendSettings
        sentLog = snap.sentLog
        letterOrigins = snap.letterOrigins
        outbox = snap.outbox
        sendFailures = snap.sendFailures
        dataDate = snap.savedAt
        rebuildLists()
    }

    private func scheduleSave() {
        guard let date = dataDate ?? (serverJobs.isEmpty ? nil : Date.now) else { return }
        let snap = CacheSnapshot(savedAt: date, serverURL: serverKey, jobs: serverJobs, details: details,
                                 stats: stats, sendSettings: sendSettings, sentLog: sentLog,
                                 letterOrigins: letterOrigins, outbox: outbox, sendFailures: sendFailures)
        let store = self.store
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? store.saveSnapshot(snap)
        }
    }

    private func saveQueue() {
        do {
            try store.saveQueue(queue)
        } catch {
            transientMessage = "Lokale Änderungen konnten nicht gespeichert werden: \(error.localizedDescription)"
        }
    }

    /// Applies local edits and local letter origins to a server summary.
    func localize(_ s: JobSummary) -> JobSummary {
        var out = queue.apply(to: s)
        if out.letterOrigin == "manuell", let lo = letterOrigins[s.id],
           let d = details[s.id], d.letter == lo.text {
            out.letterOrigin = lo.origin
        }
        return out
    }

    func localize(_ d: JobDetail) -> JobDetail {
        var out = queue.apply(to: d)
        if out.summary.letterOrigin == "manuell", let lo = letterOrigins[d.id], out.letter == lo.text {
            out.summary.letterOrigin = lo.origin
        }
        return out
    }

    private func rebuildLists() {
        allJobs = serverJobs.map(localize)
        jobs = allJobs.filter { filter.matches($0, description: details[$0.id]?.description) }
        highScoreNew = NewJobDetector.highScoreUntriaged(allJobs, threshold: settings.notifyThreshold)
    }

    // MARK: Categories

    func category(of job: JobSummary) -> ApplyCategory { ApplyCategory.of(job, blocklist: blocklist) }

    /// Jobs of a sidebar category; the sidebar filters (except status) apply too.
    func jobs(in category: ApplyCategory) -> [JobSummary] {
        var f = filter
        f.status = .all
        return allJobs.filter { self.category(of: $0) == category && f.matches($0, description: details[$0.id]?.description) }
    }

    func count(_ category: ApplyCategory) -> Int { allJobs.filter { self.category(of: $0) == category }.count }

    var todayJobs: [JobSummary] { ApplyCategory.todayManual(allJobs, blocklist: blocklist, limit: 10) }

    /// Days shown in "Neu" (newly found / imported jobs, newest first).
    static let recentDays = 3

    /// Open jobs found or imported in the last `recentDays` days – newest first, so new job-alert
    /// imports (LinkedIn, StepStone, Indeed) are visible right away instead of deep in the score list.
    var recentJobs: [JobSummary] {
        let cutoff = Date.now.addingTimeInterval(-Double(Self.recentDays) * 86_400)
        return allJobs
            .filter { j in
                guard let d = j.fetchedDate, d >= cutoff else { return false }
                let c = category(of: j)
                return c != .applied && c != .later
            }
            .sorted { ($0.fetchedDate ?? .distantPast, $0.score) > ($1.fetchedDate ?? .distantPast, $1.score) }
    }

    func list(for item: SidebarItem) -> [JobSummary] {
        if let c = item.category { return jobs(in: c) }
        switch item {
        case .today: return todayJobs
        case .recent: return recentJobs
        default: return jobs
        }
    }

    // MARK: Lifecycle

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationManager.shared.setUp()
        NotificationManager.shared.onOpenJob = { [weak self] id in self?.open(jobID: id) }
        if settings.notificationsEnabled {
            Task { await NotificationManager.shared.requestAuthorization() }
        }
        restartAutoRefresh()
        Task { await loadModels() }
    }

    /// (Re)starts the periodic refresh with the configured interval. While offline it retries
    /// every 2 minutes (so pending changes go out soon after the server is back).
    func restartAutoRefresh() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let minutes = max(1, self?.settings.refreshMinutes ?? 15)
                let offline = self?.isOffline ?? false
                try? await Task.sleep(for: .seconds(offline ? min(minutes, 2) * 60 : minutes * 60))
            }
        }
    }

    func open(jobID: Int) {
        if sidebarSelection == nil || sidebarSelection == .outbox || sidebarSelection == .tracker {
            sidebarSelection = .jobs
        }
        selectedJobID = jobID
        NSApp.activate()
    }

    // MARK: Loading

    /// Full refresh: replay pending edits, then stats + all jobs (+ notifications), send state,
    /// outbox processing. On failure the cached data stays visible.
    func refresh() async {
        guard let client else {
            connection = .notConfigured
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // 1. Push local edits first, so the server state we fetch already contains them.
        await syncPending(client)
        if case .failed = connection, !queue.isEmpty, lastSyncProblem != nil {
            // Server still unreachable: no point in three more timeouts.
            return
        }
        do {
            async let statsReq = client.stats(minScore: settings.notifyThreshold)
            async let allReq = client.jobs(JobFilter(status: .all), limit: 5000)
            let (s, all) = try await (statsReq, allReq)
            stats = s
            sources = Self.withAlertSources(s.sources)
            serverJobs = all
            isRunActive = s.running
            connection = .ok
            lastRefresh = .now
            dataDate = .now
            rebuildLists()
            await updateHighScore(from: allJobs)
        } catch {
            fail(error)
            return
        }
        await refreshSendState(client)
        await loadSentLog()
        scheduleSave()
        if queue.isEmpty {
            await processOutbox()
        }
        await prefetchDetails(client)
        await autoReplaceTemplates(client)
        await importJobAlerts()
    }

    /// Source filter: the server's sources plus the job-alert sources (even before the first import).
    static func withAlertSources(_ sources: [String]) -> [String] {
        var out = sources
        for a in AlertSource.allCases where !out.contains(a.rawValue) { out.append(a.rawValue) }
        return out
    }

    // MARK: Job-Alerts (Apple Mail, read-only)

    /// Reads LinkedIn/StepStone/Indeed alert e-mails from Apple Mail, imports the jobs on the
    /// server (queued while offline). Automatic: after a refresh, at most every 15 minutes, only while Mail
    /// is running (never launches Mail by itself). `manual`: "Jetzt importieren".
    func importJobAlerts(manual: Bool = false) async {
        guard manual || settings.jobAlertsEnabled, !isImportingAlerts else { return }
        let mailRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.mail" }
        let due = alertState.lastRun.map { Date.now.timeIntervalSince($0) >= 900 } ?? true
        isImportingAlerts = true
        defer { isImportingAlerts = false }
        var state = alertState
        let api: JobImportAPI? = isOnline ? client : nil
        let outcome: JobAlertOutcome
        if manual || (due && mailRunning) {
            outcome = await JobAlertImporter.run(state: &state, reader: alertReader, api: api,
                                                 account: settings.jobAlertAccount, daysBack: settings.jobAlertDays)
        } else if api != nil, !state.pending.isEmpty {
            var o = JobAlertOutcome()  // only send what is still queued from an offline run
            await JobAlertImporter.flush(state: &state, api: api, outcome: &o)
            outcome = o
        } else {
            return
        }
        alertState = state
        do { try store.saveAlertState(state) } catch {
            transientMessage = "Job-Alerts: Zustand konnte nicht gespeichert werden: \(error.localizedDescription)"
        }
        lastAlertOutcome = outcome
        if manual || outcome.imported > 0 || outcome.mailError != nil {
            transientMessage = "Job-Alerts: " + outcome.summary
        }
        if outcome.imported > 0, let client, let all = try? await client.jobs(JobFilter(status: .all), limit: 5000) {
            if let s = try? await client.stats(minScore: settings.notifyThreshold) {
                stats = s
                sources = Self.withAlertSources(s.sources)
            }
            serverJobs = all
            rebuildLists()
            await updateHighScore(from: allJobs)
            scheduleSave()
        }
    }

    /// Mail accounts for the settings picker (read-only).
    func mailAccountNames() async -> [String] {
        (try? await (alertReader as? AppleMailAlertReader)?.accountNames()) ?? []
    }

    /// Caches posting text/letter of open jobs (best first) so they can be read, edited and
    /// given a KI letter while offline. Gentle: sequential, max. 40 per refresh, only missing ones.
    private func prefetchDetails(_ client: APIClient) async {
        let missing = allJobs
            .filter { [.automatic, .manual].contains(category(of: $0)) && details[$0.id] == nil }
            .sorted { $0.score > $1.score }
            .prefix(40)
        guard !missing.isEmpty else { return }
        for job in missing {
            guard isOnline, !Task.isCancelled else { break }
            guard let d = try? await client.job(id: job.id) else { break }
            details[job.id] = d
        }
        rebuildLists()
        scheduleSave()
    }

    // MARK: Offline queue

    /// "Jetzt synchronisieren".
    func syncNow() async {
        guard let client else { connection = .notConfigured; return }
        await syncPending(client)
        if isOnline { await refresh() }
    }

    private func syncPending(_ client: APIClient) async {
        guard !queue.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let snapshot = queue
        let result = await SyncEngine.replay(snapshot, api: client)
        // Edits made while replaying stay (their id is not in finishedIDs, or they were coalesced
        // into a finished change with a newer timestamp → re-record below).
        let finished = result.finishedIDs
        let changedMeanwhile = queue.changes.filter { c in
            finished.contains(c.id) && snapshot.changes.first(where: { $0.id == c.id }) != c
        }
        queue.removeAll(ids: finished)
        for c in changedMeanwhile {
            queue.record(jobID: c.jobID, field: c.field, value: c.value, base: result.details[c.jobID].flatMap(c.field.value(in:)),
                         at: c.createdAt, origin: c.origin, title: c.title)
        }
        saveQueue()
        for (id, d) in result.details { storeServerDetail(d, id: id) }
        if let error = result.stoppedError {
            lastSyncProblem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            fail(error)
        } else {
            lastSyncProblem = nil
            if !result.done.isEmpty || !result.conflicts.isEmpty { connection = .ok }
        }
        var notes: [String] = []
        if !result.done.isEmpty {
            notes.append(result.done.count == 1 ? "1 Änderung synchronisiert" : "\(result.done.count) Änderungen synchronisiert")
        }
        if !result.conflicts.isEmpty {
            let what = result.conflicts.map { "\($0.field.label) bei „\($0.title ?? "#\($0.jobID)")“" }.joined(separator: ", ")
            notes.append("Server war neuer, lokale Änderung verworfen: \(what)")
        }
        if !result.deferred.isEmpty {
            notes.append("Anzeigentext wartet: der Server unterstützt das Einfügen noch nicht (Backend aktualisieren)")
        }
        for (c, msg) in result.rejected {
            notes.append("\(c.field.label) bei „\(c.title ?? "#\(c.jobID)")“ abgelehnt: \(msg)")
        }
        if !notes.isEmpty { transientMessage = notes.joined(separator: " · ") }
        rebuildLists()
        scheduleSave()
    }

    private func storeServerDetail(_ d: JobDetail, id: Int) {
        details[id] = d
        if let i = serverJobs.firstIndex(where: { $0.id == id }) {
            // Keep the list's light send_state; take everything else from the detail.
            var s = d.summary
            if s.sendState == nil { s.sendState = serverJobs[i].sendState }
            serverJobs[i] = s
        }
    }

    /// Records a local edit, updates the UI immediately and tries to push it right away.
    private func recordEdit(id: Int, field: PendingField, value: String?, origin: String? = nil) -> JobDetail? {
        let server = details[id]
        let summary = serverJobs.first { $0.id == id }
        let base: String? = server.flatMap(field.value(in:)) ?? {
            switch field {
            case .status: return summary?.status.rawValue
            case .appliedDate: return summary?.appliedDate
            default: return nil
            }
        }()
        queue.record(jobID: id, field: field, value: value, base: base, at: .now, origin: origin,
                     title: summary?.title ?? server?.summary.title)
        saveQueue()
        rebuildLists()
        if isOnline, let client {
            Task { await self.syncPending(client) }
        }
        return server.map(localize)
    }

    func pendingChanges(for jobID: Int) -> [PendingChange] { queue.changes(for: jobID) }

    /// "Anzeigentext einfügen": stored locally first (works offline), then the server saves it,
    /// re-scores the job and writes the KI letter (unless the letter was written by hand).
    func saveDescription(id: Int, text: String) -> JobDetail? {
        recordEdit(id: id, field: .description, value: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Enough posting text for a KI letter? (Job alerts carry none until the user pastes it.)
    func hasPostingText(_ job: JobSummary) -> Bool {
        if job.descriptionLength != nil { return job.hasPostingText }
        return details[job.id].map { localize($0).hasPostingText } ?? true
    }

    // MARK: E-mail applications

    private var appVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }

    /// Server send settings + counters + outbox; also tells the server our "Automatisch senden" toggle.
    func refreshSendState(_ client: APIClient? = nil) async {
        guard let client = client ?? self.client else { return }
        if let s = try? await client.sendSettings() { sendSettings = s }
        if let o = try? await client.outbox() { outbox = o }
        try? await client.reportClientState(autoSendEnabled: settings.autoSendEnabled, appVersion: appVersion)
        rebuildLists()
    }

    func loadSentLog() async {
        guard let client else { return }
        if let list = try? await client.sentLog() {
            sentLog = list.items
            scheduleSave()
        }
    }

    /// After each refresh: send what the server's outbox allows (never in dry-run, never offline,
    /// never while local edits are still waiting).
    private func processOutbox() async {
        guard isOnline, queue.isEmpty, !isSending, let coordinator, let s = sendSettings,
              !s.dryRun, !s.killSwitch, s.mode != "off" else { return }
        isSending = true
        defer { isSending = false }
        let result = await coordinator.processOutbox(autoSendEnabled: settings.autoSendEnabled)
        await handle(result.outcomes)
        if let error = result.error, !(error is APIError) {
            lastSendError = error.localizedDescription
            transientMessage = "Versand gestoppt: \(error.localizedDescription)"
            recordFailure(jobID: result.failedItem?.jobId, to: result.failedItem?.email.to,
                          subject: result.failedItem?.email.subject, error: error)
            await NotificationManager.shared.notifySendProblem(error.localizedDescription)
        }
        if result.sentCount > 0 {
            await refreshAfterSend()
        }
    }

    private func recordFailure(jobID: Int?, to: String?, subject: String?, error: Error) {
        let job = jobID.flatMap { id in allJobs.first { $0.id == id } }
        sendFailures.insert(SendFailure(jobID: jobID, title: job?.title, company: job?.company, to: to ?? job?.applyEmail,
                                        subject: subject, message: error.localizedDescription, at: .now), at: 0)
        sendFailures = Array(sendFailures.prefix(50))
        scheduleSave()
    }

    func clearSendFailures() {
        sendFailures = []
        scheduleSave()
    }

    private func handle(_ outcomes: [SendCoordinator.Outcome]) async {
        for o in outcomes {
            if case .sent(let id, let to, let subject, let recorded) = o {
                let title = allJobs.first { $0.id == id }?.title ?? subject
                await NotificationManager.shared.notifySent(jobID: id, title: title, to: to)
                if !recorded {
                    transientMessage = "Gesendet an \(to), aber der Server hat es noch nicht gespeichert – wird wiederholt."
                }
            }
        }
    }

    private func refreshAfterSend() async {
        sendGeneration += 1
        await refreshSendState()
        await loadSentLog()
        if let client, let all = try? await client.jobs(JobFilter(status: .all), limit: 5000) {
            serverJobs = all
            rebuildLists()
            scheduleSave()
        }
    }

    /// "Per Mail senden" after the confirmation dialog. In dry-run only opens the message in Mail.
    /// Never offline, never while this job has unsynchronized edits (the server would render the
    /// old letter).
    func sendNow(jobID: Int) async throws -> SendCoordinator.Outcome {
        guard let coordinator else { throw APIError.notConfigured }
        guard isOnline else {
            throw SendError.mail("Offline – E-Mails werden nur gesendet, wenn der Server erreichbar ist.")
        }
        guard queue.changes(for: jobID).isEmpty else {
            throw SendError.mail("Diese Stelle hat noch nicht synchronisierte Änderungen – bitte erst synchronisieren.")
        }
        guard !isSending else { throw SendError.mail("Es wird gerade gesendet – bitte kurz warten.") }
        isSending = true
        defer { isSending = false }
        do {
            let outcome = try await coordinator.sendNow(jobID: jobID)
            await handle([outcome])
            await refreshAfterSend()
            return outcome
        } catch {
            if !(error is APIError) || (error as? APIError)?.isConnectivityProblem == false {
                recordFailure(jobID: jobID, to: nil, subject: nil, error: error)
            }
            throw error
        }
    }

    func emailPreview(id: Int) async throws -> EmailPreview {
        guard let client else { throw APIError.notConfigured }
        return try await client.emailPreview(id: id)
    }

    func setApplyEmail(id: Int, _ email: String) async throws -> JobDetail {
        guard let client else { throw APIError.notConfigured }
        guard isOnline else { throw SendError.mail("Offline – die Empfängeradresse kann nur online geändert werden.") }
        let d = try await client.update(id: id, JobUpdate(applyEmail: email))
        storeServerDetail(d, id: id)
        rebuildLists()
        scheduleSave()
        return localize(d)
    }

    /// Opens a really sent application in Mail (read-only lookup in the Sent mailbox).
    func openInMail(_ entry: SentEntry) async -> String? {
        var messageID = entry.messageId
        if messageID == nil, let sender = mailSender as? AppleMailSender {
            do {
                messageID = try await sender.findSentMessageID(subject: entry.subject, to: entry.to)
            } catch {
                return error.localizedDescription
            }
            if let messageID, let client {
                _ = try? await client.setSentMessageID(sentID: entry.id, messageID: messageID)
            }
        }
        guard let messageID, let url = AppleMailSender.messageURL(messageID: messageID) else {
            return "Nachricht im Postfach „Gesendet“ nicht gefunden (Betreff „\(entry.subject)“ an \(entry.to))."
        }
        NSWorkspace.shared.open(url)
        return nil
    }

    private func updateHighScore(from all: [JobSummary]) async {
        let threshold = settings.notifyThreshold
        guard let seen = settings.seenJobIDs else {
            // First launch: remember everything, don't flood with notifications.
            settings.seenJobIDs = Set(all.map(\.id))
            return
        }
        let fresh = NewJobDetector.newJobs(in: all, seen: seen, threshold: threshold)
        settings.seenJobIDs = NewJobDetector.pruned(seen.union(all.map(\.id)), current: all)
        if settings.notificationsEnabled, !fresh.isEmpty {
            await NotificationManager.shared.notify(newJobs: fresh, threshold: threshold)
        }
    }

    func fail(_ error: Error) {
        if let api = error as? APIError {
            connection = api == .notConfigured ? .notConfigured : .failed(api.errorDescription ?? "Fehler")
        } else {
            connection = .failed(error.localizedDescription)
        }
    }

    // MARK: Actions (work offline)

    /// Detail from the server; falls back to the cached copy when the server is unreachable.
    /// Returns the local view (pending edits applied).
    func loadDetail(id: Int) async throws -> JobDetail {
        if let client {
            do {
                let d = try await client.job(id: id)
                storeServerDetail(d, id: id)
                if !isOnline, connection != .notConfigured { connection = .ok }
                rebuildLists()
                scheduleSave()
                return localize(d)
            } catch {
                guard let cached = details[id] else {
                    if (error as? APIError)?.isConnectivityProblem == true || SyncEngine.isTransient(error) {
                        fail(error)
                        throw OfflineError.detailNotCached
                    }
                    throw error
                }
                if SyncEngine.isTransient(error) { fail(error) }
                return localize(cached)
            }
        }
        if let cached = details[id] { return localize(cached) }
        throw APIError.notConfigured
    }

    /// Detail without network (cache only).
    func cachedDetail(id: Int) -> JobDetail? { details[id].map(localize) }

    enum OfflineError: LocalizedError {
        case detailNotCached
        case needsServer(String)
        var errorDescription: String? {
            switch self {
            case .detailNotCached:
                "Offline – diese Stelle wurde noch nie geöffnet, daher ist kein Anzeigentext gespeichert. Sie erscheint, sobald der Server wieder erreichbar ist."
            case .needsServer(let what): "Offline – \(what) geht nur, wenn der Server erreichbar ist."
            }
        }
    }

    func setStatus(id: Int, _ status: JobStatus) -> JobDetail? {
        let r = recordEdit(id: id, field: .status, value: status.rawValue)
        // Server rule: "beworben" without date → today. Mirror it locally.
        let current = allJobs.first { $0.id == id }
        if status == .beworben, current?.appliedDate == nil {
            return recordEdit(id: id, field: .appliedDate, value: ServerDate.dayString(.now)) ?? r
        }
        return r
    }

    func saveTracker(id: Int, notes: String, appliedDate: String?) -> JobDetail? {
        _ = recordEdit(id: id, field: .notes, value: notes)
        return recordEdit(id: id, field: .appliedDate, value: appliedDate)
    }

    func saveLetter(id: Int, text: String, origin: String = "manuell") -> JobDetail? {
        if origin != "manuell" {
            letterOrigins[id] = LocalLetterOrigin(origin: origin, text: text, at: .now)
        } else {
            letterOrigins.removeValue(forKey: id)
        }
        scheduleSave()
        return recordEdit(id: id, field: .letter, value: text, origin: origin)
    }

    /// "Als beworben markieren" (manual applications).
    func markApplied(id: Int) -> JobDetail? { setStatus(id: id, .beworben) }

    func regenerateLetter(id: Int) async throws -> JobDetail {
        guard let client else { throw APIError.notConfigured }
        guard isOnline else { throw OfflineError.needsServer("„Neu generieren“ (Server-LLM)") }
        let d = try await client.regenerateLetter(id: id)
        storeServerDetail(d, id: id)
        letterOrigins.removeValue(forKey: id)
        rebuildLists()
        scheduleSave()
        return localize(d)
    }

    // MARK: KI letters (opencode CLI)

    var opencode: OpencodeRunner {
        OpencodeRunner(executable: settings.opencodePath, timeout: TimeInterval(settings.letterTimeout))
    }

    func loadModels() async {
        var models = OpencodeRunner.fallbackModels
        if let listed = try? await opencode.models(), !listed.isEmpty {
            models = listed
            for m in OpencodeRunner.fallbackModels where !models.contains(m) { models.append(m) }
        }
        if !models.contains(settings.letterModel) { models.insert(settings.letterModel, at: 0) }
        availableModels = models
    }

    func readCVProfile() throws -> String {
        let path = (settings.cvProfilePath as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else {
            throw LetterError.noProfile(path)
        }
        return text
    }

    enum LetterError: LocalizedError, Equatable {
        case noProfile(String)
        case busy
        case noPostingText
        var errorDescription: String? {
            switch self {
            case .noProfile(let p): "Profil nicht gefunden: \(p) (Einstellungen › KI-Anschreiben)."
            case .busy: "Es wird bereits ein Anschreiben geschrieben."
            case .noPostingText: "Kein Anzeigentext – Anzeigentext einfügen, dann KI-Anschreiben."
            }
        }
    }

    /// Writes the letter for one job with opencode and saves it (queued if offline).
    /// Returns the saved local detail and the duration.
    @discardableResult
    func writeLetterWithAI(id: Int) async throws -> (JobDetail?, TimeInterval) {
        guard !letterJobIDs.contains(id) else { throw LetterError.busy }
        letterJobIDs.insert(id)
        defer { letterJobIDs.remove(id) }
        let profile = try readCVProfile()
        let detail = try await loadDetail(id: id)
        guard detail.hasPostingText else { throw LetterError.noPostingText }
        let prompt = LetterPrompt.build(cvProfile: profile, job: detail)
        let start = Date.now
        let raw = try await opencode.writeLetter(model: settings.letterModel, prompt: prompt)
        let letter = try LetterOutputCleaner.clean(raw, sources: [profile, detail.description, detail.summary.title,
                                                                  detail.summary.company ?? ""],
                                                   company: detail.summary.company)
        let saved = saveLetter(id: id, text: letter, origin: LetterPrompt.originLabel)
        return (saved, Date.now.timeIntervalSince(start))
    }

    /// Jobs whose letter is still the template (or missing) and that are still open.
    var templateLetterJobs: [JobSummary] {
        allJobs.filter { ($0.letterOrigin == "vorlage" || !$0.hasLetter)
            && [.automatic, .manual].contains(category(of: $0)) && hasPostingText($0) }
            .sorted { $0.score > $1.score }
    }

    /// "Alle Vorlagen schreiben": sequential, cancellable.
    func writeAllTemplateLetters() {
        writeLetters(for: templateLetterJobs)
    }

    /// Jobs whose automatic KI attempt failed in this session (not retried on every refresh).
    private var autoLetterFailed: Set<Int> = []

    /// "Vorlagen automatisch durch KI ersetzen": after a refresh, open jobs that still have the
    /// template get an opencode letter – only if the server has no KI, or the server had 6 h and
    /// did not manage. Max. 20 per pass, sequential, cancellable like "Alle Vorlagen schreiben".
    private func autoReplaceTemplates(_ client: APIClient) async {
        guard settings.autoReplaceTemplates, letterBatch == nil, opencode.isInstalled else { return }
        guard let health = try? await client.health() else { return }
        let serverKI = health.llmEnabled
        if serverKI && (health.lettersRunning ?? false || health.running) { return }
        let cutoff = Date.now.addingTimeInterval(-6 * 3600)
        let targets = templateLetterJobs.filter { job in
            !autoLetterFailed.contains(job.id) && job.score > 0
                && (!serverKI || (job.fetchedDate ?? .now) < cutoff)
        }
        guard !targets.isEmpty else { return }
        writeLetters(for: Array(targets.prefix(20)), automatic: true)
    }

    private func writeLetters(for targets: [JobSummary], automatic: Bool = false) {
        guard letterBatch == nil else { return }
        guard !targets.isEmpty else {
            transientMessage = "Keine Vorlagen-Anschreiben offen."
            return
        }
        letterJob = LetterJob(total: targets.count)
        letterBatch = Task { [weak self] in
            var errors: [String] = []
            for job in targets {
                if Task.isCancelled { break }
                self?.letterJob?.currentTitle = job.title
                do {
                    try await self?.writeLetterWithAI(id: job.id)
                } catch {
                    self?.letterJob?.failed += 1
                    if automatic { self?.autoLetterFailed.insert(job.id) }
                    errors.append("\(job.title): \(error.localizedDescription)")
                    if let e = error as? LetterError, e != .noPostingText { break }
                }
                self?.letterJob?.done += 1
            }
            guard let self else { return }
            let j = self.letterJob
            self.transientMessage = (automatic ? "Vorlagen automatisch ersetzt: " : "KI-Anschreiben: ")
                + "\((j?.done ?? 0) - (j?.failed ?? 0)) geschrieben, \(j?.failed ?? 0) fehlgeschlagen"
                + (errors.first.map { " – zuletzt: \($0)" } ?? "")
            self.letterJob = nil
            self.letterBatch = nil
        }
    }

    func cancelLetterBatch() {
        letterBatch?.cancel()
    }

    var isWritingBatch: Bool { letterBatch != nil }

    // MARK: Anschreiben als PDF

    private let pdfExporter = LetterPDFExporter()

    /// Full letter document for a job (cached detail works offline). `letter` overrides the
    /// stored text (e.g. unsaved edits in the editor).
    func letterDocument(id: Int, letter: String? = nil) async throws -> LetterDocument {
        let detail: JobDetail
        if let d = cachedDetail(id: id) { detail = d } else { detail = try await loadDetail(id: id) }
        return LetterDocument.build(job: detail, letter: letter, applicant: settings.applicant)
    }

    /// "Als PDF speichern": ~/Bewerbung/Anschreiben/Anschreiben_<Firma>_<Datum>.pdf, shown in Finder.
    @discardableResult
    func saveLetterPDF(id: Int, letter: String? = nil) async throws -> URL {
        let doc = try await letterDocument(id: id, letter: letter)
        let url = try await pdfExporter.save(doc, folder: settings.letterPDFFolder)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    /// "Vorschau": temporary PDF opened in Preview.
    func previewLetterPDF(id: Int, letter: String? = nil) async throws {
        let doc = try await letterDocument(id: id, letter: letter)
        NSWorkspace.shared.open(try await pdfExporter.preview(doc))
    }

    // MARK: Server run

    /// "Jetzt suchen": starts a server-side run, then polls until it finishes and refreshes.
    func triggerRun() {
        guard let client else { connection = .notConfigured; return }
        runPoll?.cancel()
        runPoll = Task { [weak self] in
            do {
                let r = try await client.triggerRun()
                self?.isRunActive = true
                self?.transientMessage = r.started ? "Suchlauf gestartet …" : "Ein Suchlauf läuft bereits …"
                let deadline = Date.now.addingTimeInterval(45 * 60)
                while Date.now < deadline, !Task.isCancelled {
                    try await Task.sleep(for: .seconds(4))
                    let s = try await client.stats()
                    if !s.running { break }
                }
                self?.isRunActive = false
                await self?.refresh()
                if let n = self?.stats?.newSinceLastRun {
                    self?.transientMessage = n == 1 ? "Suchlauf fertig: 1 neue Stelle" : "Suchlauf fertig: \(n) neue Stellen"
                }
            } catch is CancellationError {
                self?.isRunActive = false
            } catch {
                self?.isRunActive = false
                self?.fail(error)
                self?.transientMessage = "Suchlauf nicht möglich: Server nicht erreichbar."
            }
        }
    }

    /// Settings → "Verbindung testen".
    func testConnection() async -> Result<Health, Error> {
        guard let client else { return .failure(APIError.notConfigured) }
        do {
            let h = try await client.health()
            connection = .ok
            return .success(h)
        } catch {
            fail(error)
            return .failure(error)
        }
    }

    /// Server URL changed in the settings: the cache of the old server does not apply.
    func serverChanged() {
        let dir = LocalStore.directory(forServer: serverKey)
        guard dir != store.directory else { return }
        store = LocalStore(directory: dir)
        queue = PendingQueue()
        letterOrigins = [:]
        sendFailures = []
        serverJobs = []
        details = [:]
        stats = nil
        sendSettings = nil
        sentLog = []
        outbox = nil
        dataDate = nil
        lastAlertOutcome = nil
        loadLocalState()
    }
}
