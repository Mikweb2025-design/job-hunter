import Foundation

// MARK: - E-mail applications (server: jobhunter.outbox / /api/v1/outbox …)

/// `send:` section of the server's config.yaml plus live counters (`GET /api/v1/send-settings`).
public struct SendSettings: Codable, Sendable, Hashable {
    public var mode: String              // off | approve | auto
    public var dryRun: Bool
    public var killSwitch: Bool
    public var autoMinScore: Int
    public var dailyCap: Int
    public var companyCooldownDays: Int
    public var blocklist: [String]
    public var requireLetter: Bool
    public var fromAddress: String
    public var senderName: String
    public var subjectTemplate: String
    public var cvAttachment: String?
    public var sentToday: Int
    public var sentTotal: Int
    public var dryRunTotal: Int
    public var dryRunToday: Int
    public var remainingToday: Int
    /// Sender block for the cover-letter PDF (newer servers).
    public var applicant: Applicant?
    /// Editable auto-send score (newer servers): current value, config.yaml value, allowed range.
    public var autoMinScoreInfo: AutoMinScoreInfo?
    /// Relocation filter (newest servers; nil on older ones = no info, not "off").
    public var locationFilter: LocationFilter?
}

public struct AutoMinScoreInfo: Codable, Sendable, Hashable {
    public var autoMinScore: Int
    public var configValue: Int
    public var overridden: Bool
    public var min: Int
    public var max: Int
}

/// Umzugsfilter from `GET /api/v1/send-settings` (newest servers).
/// Any shape decodes: unknown keys are ignored, wrong types and non-objects
/// become "present but empty" so old/new servers never break the settings load.
public struct LocationFilter: Codable, Sendable, Hashable {
    public var maxDistanceKm: Int?
    public var mode: String?

    public init(maxDistanceKm: Int? = nil, mode: String? = nil) {
        self.maxDistanceKm = maxDistanceKm
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case maxDistanceKm, mode
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        maxDistanceKm = (try? c?.decodeIfPresent(Int.self, forKey: .maxDistanceKm)) ?? nil
        mode = (try? c?.decodeIfPresent(String.self, forKey: .mode)) ?? nil
    }

    /// One-line German summary for the settings row.
    public var summary: String {
        var parts: [String] = []
        if let mode, !mode.isEmpty { parts.append(mode) }
        if let km = maxDistanceKm { parts.append("max. \(km) km") }
        return parts.isEmpty ? "aktiv" : parts.joined(separator: " · ")
    }
}

/// `GET /api/v1/views`: labels, order and counts of the server-computed workflow
/// views (`jobhunter.views`; newest servers add `far`). Missing keys mean an older
/// server — the app then falls back to its static sidebar.
public struct ServerViews: Codable, Sendable, Hashable {
    public var counts: [String: Int]
    public var labels: [String: String]
    public var order: [String]
    public var todayLimit: Int?

    public init(counts: [String: Int] = [:], labels: [String: String] = [:],
                order: [String] = [], todayLimit: Int? = nil) {
        self.counts = counts
        self.labels = labels
        self.order = order
        self.todayLimit = todayLimit
    }

    private enum CodingKeys: String, CodingKey {
        case counts, labels, order, todayLimit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = (try? c.decodeIfPresent([String: Int].self, forKey: .counts)) ?? [:]
        labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        order = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? []
        todayLimit = (try? c.decodeIfPresent(Int.self, forKey: .todayLimit)) ?? nil
    }
}

/// Rendered e-mail as the server would send it.
public struct OutgoingEmail: Codable, Sendable, Hashable {
    public var to: String?
    public var from: String
    public var senderName: String
    public var sender: String
    public var subject: String
    public var body: String
    public var attachment: String?
}

public struct OutboxItem: Codable, Sendable, Hashable, Identifiable {
    public var jobId: Int
    public var title: String
    public var company: String?
    public var score: Int?
    public var reason: String            // approved | auto
    public var email: OutgoingEmail
    public var id: Int { jobId }

    public var isApproved: Bool { reason == "approved" }
}

/// `GET /api/v1/outbox`: what may be sent *now* (all gating already applied by the server).
public struct Outbox: Codable, Sendable, Hashable {
    public var mode: String
    public var dryRun: Bool
    public var killSwitch: Bool
    public var sentToday: Int
    public var sentTotal: Int
    public var dryRunTotal: Int
    public var remainingToday: Int
    public var count: Int
    public var items: [OutboxItem]
}

/// Per-job badge state (`send_state` in job list/detail and the preview).
public struct SendStateInfo: Codable, Sendable, Hashable {
    /// sent | manual | ready | sendable | blocked | test | email
    public var state: String
    public var sentAt: String?
    public var to: String?
    public var testAt: String?
    public var approved: Bool?
    public var sentId: Int?

    public var isSent: Bool { state == "sent" }
}

public struct SentEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    public var jobId: Int
    public var company: String?
    public var title: String?
    public var to: String
    public var subject: String
    public var body: String
    public var sentAt: String
    public var dryRun: Bool
    public var messageId: String?
    public var trigger: String?

    public var sentDate: Date? { ServerDate.parse(sentAt) }
}

public struct SentList: Decodable, Sendable, Hashable {
    public var count: Int
    public var items: [SentEntry]
    public var sentToday: Int
    public var sentTotal: Int
    public var dryRunTotal: Int
}

/// `GET /api/v1/jobs/{id}/email-preview`.
public struct EmailPreview: Decodable, Sendable, Hashable {
    public var jobId: Int
    public var applyEmail: String?
    public var applyMethod: String
    public var applyEmailSource: String?
    public var mode: String
    public var dryRun: Bool
    public var email: OutgoingEmail?
    public var canSend: Bool
    public var autoEligible: Bool
    public var inOutbox: Bool
    public var approved: Bool
    public var blockers: [String]
    public var autoBlockers: [String]
    public var blockerTexts: [String]
    public var sendState: SendStateInfo
    public var sent: [SentEntry]
}

/// `POST /api/v1/jobs/{id}/sent` body.
public struct SentReport: Codable, Sendable, Equatable {
    public var dryRun: Bool
    public var sentAt: String
    public var messageId: String?
    public var to: String
    public var subject: String
    public var body: String
    public var trigger: String          // manual | approved | auto

    public init(dryRun: Bool, sentAt: String, messageId: String? = nil, to: String, subject: String,
                body: String, trigger: String) {
        self.dryRun = dryRun
        self.sentAt = sentAt
        self.messageId = messageId
        self.to = to
        self.subject = subject
        self.body = body
        self.trigger = trigger
    }

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run", sentAt = "sent_at", messageId = "message_id", to, subject, body, trigger
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(dryRun, forKey: .dryRun)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encodeIfPresent(messageId, forKey: .messageId)
        try c.encode(to, forKey: .to)
        try c.encode(subject, forKey: .subject)
        try c.encode(body, forKey: .body)
        try c.encode(trigger, forKey: .trigger)
    }
}

public struct SentResponse: Decodable, Sendable {
    public var sent: SentEntry
    public var job: JobDetail
}

/// A send attempt that failed on this Mac (shown as "Fehler ❌" in the Postausgang).
public struct SendFailure: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var jobID: Int?
    public var title: String?
    public var company: String?
    public var to: String?
    public var subject: String?
    public var message: String
    public var at: Date

    public init(id: UUID = UUID(), jobID: Int?, title: String?, company: String?, to: String?, subject: String?,
                message: String, at: Date) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.company = company
        self.to = to
        self.subject = subject
        self.message = message
        self.at = at
    }
}

/// Overall state for the banner ("TESTMODUS …" / "AUTOMATISCHER VERSAND AKTIV …" / "Versand aus").
public enum SendBannerKind: String, Sendable, Equatable {
    case unknown, off, kill, test, approve, auto

    public static func from(_ s: SendSettings?, autoSendEnabled: Bool) -> SendBannerKind {
        guard let s else { return .unknown }
        if s.killSwitch { return .kill }
        if s.mode == "off" { return .off }
        if s.dryRun { return .test }
        if s.mode == "auto" && autoSendEnabled { return .auto }
        return .approve
    }

    public func headline(_ s: SendSettings?) -> String {
        let today = s.map { "\($0.sentToday) von \($0.dailyCap) heute" } ?? ""
        switch self {
        case .unknown: return "Versandstatus unbekannt (Server nicht erreichbar) – es wird nichts gesendet"
        case .off: return "Versand aus"
        case .kill: return "NOT-AUS – Versand gestoppt"
        case .test: return "TESTMODUS – es werden keine E-Mails versendet"
        case .approve: return "ECHTER VERSAND nur per Klick/Freigabe – \(today)"
        case .auto: return "AUTOMATISCHER VERSAND AKTIV – \(today)"
        }
    }
}
