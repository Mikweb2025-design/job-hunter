import Foundation

// MARK: - Cached server data

/// Last known server state, persisted so the app keeps working while the server is down.
public struct CacheSnapshot: Codable, Sendable, Equatable {
    /// When the data was last fetched successfully from the server.
    public var savedAt: Date
    /// Server the data belongs to (job ids are per server; a cache of another server is ignored).
    public var serverURL: String
    /// All jobs (`status=all`), unfiltered; the app filters locally.
    public var jobs: [JobSummary]
    /// Job details opened at least once (posting text, letter, notes).
    public var details: [Int: JobDetail]
    public var stats: Stats?
    public var sendSettings: SendSettings?
    public var sentLog: [SentEntry]
    /// Letters written on this Mac (e.g. "KI (opencode)"): the server only knows "manuell".
    public var letterOrigins: [Int: LocalLetterOrigin]
    /// Last known outbox (what was waiting to be sent).
    public var outbox: Outbox?
    /// Failed send attempts on this Mac.
    public var sendFailures: [SendFailure]

    public init(savedAt: Date, serverURL: String, jobs: [JobSummary] = [], details: [Int: JobDetail] = [:],
                stats: Stats? = nil, sendSettings: SendSettings? = nil, sentLog: [SentEntry] = [],
                letterOrigins: [Int: LocalLetterOrigin] = [:], outbox: Outbox? = nil,
                sendFailures: [SendFailure] = []) {
        self.outbox = outbox
        self.sendFailures = sendFailures
        self.savedAt = savedAt
        self.serverURL = serverURL
        self.jobs = jobs
        self.details = details
        self.stats = stats
        self.sendSettings = sendSettings
        self.sentLog = sentLog
        self.letterOrigins = letterOrigins
    }

    // Tolerant decoding: fields added later must not invalidate an older cache file.
    private enum CodingKeys: String, CodingKey {
        case savedAt, serverURL, jobs, details, stats, sendSettings, sentLog, letterOrigins, outbox, sendFailures
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        serverURL = try c.decode(String.self, forKey: .serverURL)
        jobs = try c.decodeIfPresent([JobSummary].self, forKey: .jobs) ?? []
        details = try c.decodeIfPresent([Int: JobDetail].self, forKey: .details) ?? [:]
        stats = try c.decodeIfPresent(Stats.self, forKey: .stats)
        sendSettings = try c.decodeIfPresent(SendSettings.self, forKey: .sendSettings)
        sentLog = try c.decodeIfPresent([SentEntry].self, forKey: .sentLog) ?? []
        letterOrigins = try c.decodeIfPresent([Int: LocalLetterOrigin].self, forKey: .letterOrigins) ?? [:]
        outbox = try? c.decodeIfPresent(Outbox.self, forKey: .outbox)
        sendFailures = (try? c.decodeIfPresent([SendFailure].self, forKey: .sendFailures)) ?? []
    }
}

/// Origin label of a letter written locally; shown while the server still has exactly this text.
public struct LocalLetterOrigin: Codable, Sendable, Equatable {
    public var origin: String
    public var text: String
    public var at: Date

    public init(origin: String, text: String, at: Date) {
        self.origin = origin
        self.text = text
        self.at = at
    }
}

// MARK: - Pending changes (offline edits)

public enum PendingField: String, Codable, Sendable, CaseIterable {
    case status, notes, appliedDate, letter, description
    // Tracker fields (08.10.2026). Older servers reject them (422) → shown as "abgelehnt".
    case interviewAt, followUpAt, closeReason

    public var label: String {
        switch self {
        case .status: "Status"
        case .notes: "Notizen"
        case .appliedDate: "Beworben am"
        case .letter: "Anschreiben"
        case .description: "Anzeigentext"
        case .interviewAt: "Gesprächstermin"
        case .followUpAt: "Nachfassen am"
        case .closeReason: "Absagegrund"
        }
    }

    /// The field's current value in a server detail (`nil` = empty applied date).
    public func value(in d: JobDetail) -> String? {
        switch self {
        case .status: d.summary.status.rawValue
        case .notes: d.notes
        case .appliedDate: d.summary.appliedDate
        case .letter: d.letter
        case .description: d.description
        case .interviewAt: d.summary.interviewAt
        case .followUpAt: d.summary.followUpAt
        case .closeReason: d.summary.closeReason
        }
    }

    /// Server timestamp of the field's last change, if the server records one.
    public func serverChangedAt(_ d: JobDetail) -> Date? {
        switch self {
        case .status: ServerDate.parse(d.summary.statusUpdatedAt)
        case .letter: ServerDate.parse(d.letterUpdatedAt)
        case .notes, .appliedDate, .description, .interviewAt, .followUpAt, .closeReason: nil
        }
    }
}

/// One local edit that still has to reach the server. Edits of the same field of the same
/// job are coalesced (latest value, original base).
public struct PendingChange: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var jobID: Int
    public var field: PendingField
    /// New value: status raw value, notes, "YYYY-MM-DD" (nil = clear) or the letter text.
    public var value: String?
    /// Server value when the field was first edited locally (for conflict detection).
    public var base: String?
    /// Time of the latest local edit.
    public var createdAt: Date
    /// Insertion counter: stable order for edits with the same timestamp.
    public var seq: Int
    /// Letter origin label shown locally ("KI (opencode)", "manuell").
    public var origin: String?
    /// Job title for the UI ("3 Änderungen warten …").
    public var title: String?

    public init(id: UUID = UUID(), jobID: Int, field: PendingField, value: String?, base: String?,
                createdAt: Date, seq: Int = 0, origin: String? = nil, title: String? = nil) {
        self.id = id
        self.jobID = jobID
        self.field = field
        self.value = value
        self.base = base
        self.createdAt = createdAt
        self.seq = seq
        self.origin = origin
        self.title = title
    }

    /// The PATCH body for tracker fields (`nil` for the letter, which uses PUT).
    public var jobUpdate: JobUpdate? {
        switch field {
        case .status: value.flatMap(JobStatus.init(rawValue:)).map { JobUpdate(status: $0) }
        case .notes: JobUpdate(notes: value ?? "")
        case .appliedDate: JobUpdate(appliedDate: value.map { .set($0) } ?? .clear)
        case .interviewAt: JobUpdate(interviewAt: value.map { .set($0) } ?? .clear)
        case .followUpAt: JobUpdate(followUpAt: value.map { .set($0) } ?? .clear)
        case .closeReason: JobUpdate(closeReason: value.map { .set($0) } ?? .clear)
        case .letter, .description: nil
        }
    }
}

public struct PendingQueue: Codable, Sendable, Equatable {
    public private(set) var changes: [PendingChange] = []
    private var nextSeq = 1

    public init(changes: [PendingChange] = []) {
        self.changes = changes
        nextSeq = (changes.map(\.seq).max() ?? 0) + 1
    }

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    /// Replay order: oldest edit first.
    public var ordered: [PendingChange] {
        changes.sorted { ($0.createdAt, $0.seq) < ($1.createdAt, $1.seq) }
    }

    public func changes(for jobID: Int) -> [PendingChange] { ordered.filter { $0.jobID == jobID } }

    /// Records a local edit. `base` is the last known server value; it is only used for the
    /// first edit of a field. An edit back to the base value cancels the pending change.
    public mutating func record(jobID: Int, field: PendingField, value: String?, base: String?,
                                at date: Date, origin: String? = nil, title: String? = nil) {
        if let i = changes.firstIndex(where: { $0.jobID == jobID && $0.field == field }) {
            var c = changes[i]
            if value == c.base && field != .letter && field != .description {
                changes.remove(at: i)
                return
            }
            c.value = value
            c.createdAt = date
            c.seq = nextSeq
            c.origin = origin ?? c.origin
            c.title = title ?? c.title
            changes[i] = c
        } else {
            if value == base && field != .letter && field != .description { return }
            changes.append(PendingChange(jobID: jobID, field: field, value: value, base: base, createdAt: date,
                                         seq: nextSeq, origin: origin, title: title))
        }
        nextSeq += 1
    }

    public mutating func remove(id: UUID) { changes.removeAll { $0.id == id } }
    public mutating func removeAll(ids: Set<UUID>) { changes.removeAll { ids.contains($0.id) } }

    /// Local view of a job: server detail with the pending edits applied.
    public func apply(to detail: JobDetail) -> JobDetail {
        var d = detail
        for c in changes(for: detail.id) {
            switch c.field {
            case .status:
                if let s = c.value.flatMap(JobStatus.init(rawValue:)) {
                    d.summary.status = s
                    if s != .absage { d.summary.closeReason = nil }
                }
            case .notes:
                d.notes = c.value ?? ""
                d.summary.notes = d.notes
            case .appliedDate: d.summary.appliedDate = c.value
            case .interviewAt: d.summary.interviewAt = c.value
            case .followUpAt: d.summary.followUpAt = c.value
            case .closeReason: d.summary.closeReason = c.value
            case .letter:
                d.letter = c.value ?? ""
                d.summary.hasLetter = !(c.value ?? "").isEmpty
                d.summary.letterOrigin = c.origin ?? "manuell"
            case .description:
                d.description = c.value ?? ""
                d.summary.descriptionLength = d.description.trimmingCharacters(in: .whitespacesAndNewlines).count
            }
        }
        return d
    }

    public func apply(to summary: JobSummary) -> JobSummary {
        var s = summary
        for c in changes(for: summary.id) {
            switch c.field {
            case .status:
                if let st = c.value.flatMap(JobStatus.init(rawValue:)) {
                    s.status = st
                    if st != .absage { s.closeReason = nil }
                }
            case .appliedDate: s.appliedDate = c.value
            case .interviewAt: s.interviewAt = c.value
            case .followUpAt: s.followUpAt = c.value
            case .closeReason: s.closeReason = c.value
            case .letter:
                s.hasLetter = !(c.value ?? "").isEmpty
                s.letterOrigin = c.origin ?? "manuell"
            case .description:
                s.descriptionLength = (c.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
            case .notes: s.notes = c.value ?? ""
            }
        }
        return s
    }
}

// MARK: - Conflict rule

public enum ReplayDecision: Sendable, Equatable {
    /// Send the local value.
    case apply
    /// Server already has the local value.
    case alreadyInSync
    /// The server changed the same field after the local edit: server wins, local edit dropped.
    case serverNewer
}

public enum ConflictResolver {
    /// "Local change wins unless the server changed the same field later."
    /// The server changed the field if its value differs from the base the local edit started
    /// from; it changed it *later* only if it records a timestamp newer than the local edit
    /// (status_updated_at, letter_updated_at). Notes/applied date carry no timestamp → local wins.
    public static func decide(_ change: PendingChange, server: JobDetail) -> ReplayDecision {
        let current = change.field.value(in: server)
        if normalized(current) == normalized(change.value) { return .alreadyInSync }
        if normalized(current) == normalized(change.base) { return .apply }
        if let changedAt = change.field.serverChangedAt(server), changedAt > change.createdAt {
            return .serverNewer
        }
        return .apply
    }

    private static func normalized(_ v: String?) -> String {
        (v ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Replay

/// The subset of the API used to replay pending changes (fake in tests).
public protocol JobSyncAPI: Sendable {
    func job(id: Int) async throws -> JobDetail
    func update(id: Int, _ update: JobUpdate) async throws -> JobDetail
    func saveLetter(id: Int, text: String) async throws -> JobDetail
    /// Pasted posting text (server re-scores and may start a KI letter).
    func saveDescription(id: Int, text: String) async throws -> JobDetail
}

extension JobSyncAPI {
    public func saveDescription(id: Int, text: String) async throws -> JobDetail { throw APIError.notFound }
}

extension APIClient: JobSyncAPI {
    public func saveDescription(id: Int, text: String) async throws -> JobDetail {
        try await saveDescription(id: id, text: text, writeLetter: true)
    }
}

extension APIClient: JobImportAPI {}

public struct ReplayResult: Sendable {
    /// Changes the server now has (sent or already in sync).
    public var done: [PendingChange] = []
    /// Dropped because the server changed the field later.
    public var conflicts: [PendingChange] = []
    /// Dropped because the server rejected them for good (404/422 …), with the message.
    public var rejected: [(PendingChange, String)] = []
    /// Kept queued: the server does not support this change yet (e.g. pasted posting text on an
    /// older server).
    public var deferred: [PendingChange] = []
    /// Fresh server details of the touched jobs.
    public var details: [Int: JobDetail] = [:]
    /// Set when replay stopped because the server is (again) unreachable; the remaining
    /// changes stay queued.
    public var stoppedError: Error?

    public var finishedIDs: Set<UUID> {
        Set(done.map(\.id) + conflicts.map(\.id) + rejected.map(\.0.id))
    }
}

public enum SyncEngine {
    /// Errors that mean "try again later" (keep the change queued).
    public static func isTransient(_ error: Error) -> Bool {
        guard let api = error as? APIError else { return true }
        switch api {
        case .unreachable, .transport, .insecureConnection, .unauthorized, .notConfigured, .decoding: return true
        case .server(let status, _): return status >= 500 || status == 429 || status == 408
        case .notFound: return false
        }
    }

    /// Replays the queue oldest-first. Stops at the first transient error.
    public static func replay(_ queue: PendingQueue, api: JobSyncAPI) async -> ReplayResult {
        var result = ReplayResult()
        for change in queue.ordered {
            do {
                let server: JobDetail
                if let known = result.details[change.jobID] {
                    server = known
                } else {
                    server = try await api.job(id: change.jobID)
                }
                result.details[change.jobID] = server
                switch ConflictResolver.decide(change, server: server) {
                case .alreadyInSync:
                    result.done.append(change)
                case .serverNewer:
                    result.conflicts.append(change)
                case .apply:
                    let updated: JobDetail
                    if change.field == .letter {
                        updated = try await api.saveLetter(id: change.jobID, text: change.value ?? "")
                    } else if change.field == .description {
                        updated = try await api.saveDescription(id: change.jobID, text: change.value ?? "")
                    } else if let body = change.jobUpdate {
                        updated = try await api.update(id: change.jobID, body)
                    } else {
                        result.rejected.append((change, "ungültiger Wert"))
                        continue
                    }
                    result.details[change.jobID] = updated
                    result.done.append(change)
                }
            } catch {
                if change.field == .description, (error as? APIError) == .notFound, result.details[change.jobID] != nil {
                    // The job exists but the server has no /description endpoint yet (older
                    // version): keep the pasted text queued instead of dropping it.
                    result.deferred.append(change)
                    continue
                }
                if isTransient(error) {
                    result.stoppedError = error
                    break
                }
                result.rejected.append((change, (error as? LocalizedError)?.errorDescription ?? "\(error)"))
            }
        }
        return result
    }
}

// MARK: - Files

/// JSON files in ~/Library/Application Support/JobHunter (cache.json, pending.json).
public final class LocalStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL = LocalStore.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.appending(path: "JobHunter", directoryHint: .isDirectory)
    }

    /// Per-server folder (job ids and pending edits belong to one server):
    /// `…/JobHunter/<host>_<path>`. `JOBHUNTER_DATA_DIR` overrides the base folder (tests).
    public static func directory(forServer serverURL: String,
                                 base: URL = LocalStore.baseDirectory) -> URL {
        let key = serverURL.lowercased()
            .replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9.-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return base.appending(path: key.isEmpty ? "default" : key, directoryHint: .isDirectory)
    }

    public static var baseDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["JOBHUNTER_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        }
        return defaultDirectory
    }

    var cacheURL: URL { directory.appending(path: "cache.json") }
    var queueURL: URL { directory.appending(path: "pending.json") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func loadSnapshot() -> CacheSnapshot? {
        lock.withLock {
            guard let data = try? Data(contentsOf: cacheURL) else { return nil }
            return try? Self.decoder.decode(CacheSnapshot.self, from: data)
        }
    }

    public func saveSnapshot(_ snapshot: CacheSnapshot) throws {
        try write(Self.encoder.encode(snapshot), to: cacheURL)
    }

    public func loadQueue() -> PendingQueue {
        lock.withLock {
            guard let data = try? Data(contentsOf: queueURL),
                  let q = try? Self.decoder.decode(PendingQueue.self, from: data) else { return PendingQueue() }
            return q
        }
    }

    public func saveQueue(_ queue: PendingQueue) throws {
        try write(Self.encoder.encode(queue), to: queueURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        }
    }
}
