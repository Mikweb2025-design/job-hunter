import Foundation

// MARK: - Mail sender abstraction

/// One e-mail as handed to the mail client.
public struct MailMessage: Sendable, Equatable {
    public var fromAddress: String
    public var senderName: String
    public var to: String
    public var subject: String
    public var body: String
    /// Absolute path of the CV PDF; nil = no attachment.
    public var attachmentPath: String?

    public init(fromAddress: String, senderName: String, to: String, subject: String, body: String,
                attachmentPath: String?) {
        self.fromAddress = fromAddress
        self.senderName = senderName
        self.to = to
        self.subject = subject
        self.body = body
        self.attachmentPath = attachmentPath
    }

    public var senderHeader: String { "\(senderName) <\(fromAddress)>" }
}

public enum MailDelivery: Sendable, Equatable {
    /// Really send the message.
    case send
    /// Test mode: only open the message visibly in Mail, never send it.
    case draftOnly
}

public protocol MailSending: Sendable {
    /// Creates the message in the mail client and sends it (or only shows it for `.draftOnly`).
    /// Returns the Message-ID if the client reports one.
    func deliver(_ message: MailMessage, _ delivery: MailDelivery) async throws -> String?
}

public enum SendError: LocalizedError, Equatable, Sendable {
    case attachmentMissing(String)
    case noRecipient
    case notAllowed([String])
    case alreadySent
    case mail(String)

    public var errorDescription: String? {
        switch self {
        case .attachmentMissing(let path):
            "Lebenslauf nicht gefunden: \(path). Bitte in den Einstellungen › E-Mail-Versand auswählen."
        case .noRecipient: "Keine Empfängeradresse für diese Stelle."
        case .notAllowed(let reasons): "Senden nicht erlaubt: " + reasons.joined(separator: "; ")
        case .alreadySent: "Diese Bewerbung wurde von diesem Mac bereits gesendet."
        case .mail(let why): "Apple Mail: \(why)"
        }
    }
}

// MARK: - Local ledger (crash safety)

/// Remembers real sends on this Mac, so a job is never sent twice even if reporting the send
/// to the server failed (server unreachable right after sending). Pending reports are retried.
public protocol SendLedger: Sendable {
    func wasSent(_ jobID: Int) -> Bool
    func markSent(_ jobID: Int, report: SentReport)
    func markRecorded(_ jobID: Int)
    func pending() -> [Int: SentReport]
}

public final class InMemoryLedger: SendLedger, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: Set<Int> = []
    private var open: [Int: SentReport] = [:]

    public init() {}

    public func wasSent(_ jobID: Int) -> Bool { lock.withLock { sent.contains(jobID) } }
    public func markSent(_ jobID: Int, report: SentReport) {
        lock.withLock { sent.insert(jobID); open[jobID] = report }
    }
    public func markRecorded(_ jobID: Int) { lock.withLock { _ = open.removeValue(forKey: jobID) } }
    public func pending() -> [Int: SentReport] { lock.withLock { open } }
}

/// Persistent ledger in UserDefaults (keys `sentJobIDs`, `pendingSentReports`).
public final class UserDefaultsLedger: SendLedger, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    static let sentKey = "sentJobIDs"
    static let pendingKey = "pendingSentReports"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func wasSent(_ jobID: Int) -> Bool {
        lock.withLock { (defaults.array(forKey: Self.sentKey) as? [Int] ?? []).contains(jobID) }
    }

    public func markSent(_ jobID: Int, report: SentReport) {
        lock.withLock {
            var ids = defaults.array(forKey: Self.sentKey) as? [Int] ?? []
            if !ids.contains(jobID) { ids.append(jobID) }
            defaults.set(ids, forKey: Self.sentKey)
            var p = loadPending()
            p[jobID] = report
            savePending(p)
        }
    }

    public func markRecorded(_ jobID: Int) {
        lock.withLock {
            var p = loadPending()
            p.removeValue(forKey: jobID)
            savePending(p)
        }
    }

    public func pending() -> [Int: SentReport] { lock.withLock { loadPending() } }

    private func loadPending() -> [Int: SentReport] {
        guard let data = defaults.data(forKey: Self.pendingKey),
              let dict = try? JSONDecoder().decode([String: SentReport].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: dict.compactMap { k, v in Int(k).map { ($0, v) } })
    }

    private func savePending(_ p: [Int: SentReport]) {
        let dict = Dictionary(uniqueKeysWithValues: p.map { (String($0.key), $0.value) })
        defaults.set(try? JSONEncoder().encode(dict), forKey: Self.pendingKey)
    }
}

// MARK: - Coordinator

/// Sends e-mail applications through a `MailSending` client under the server's rules.
///
/// Safety properties (unit-tested with a fake sender):
/// * the server decides eligibility (`/outbox`, `/email-preview`); if it is unreachable,
///   nothing is sent (the API call throws before any delivery);
/// * when the server reports `dry_run`, `.send` is never used: automatic processing does
///   nothing and the manual button only opens an unsent message in Mail;
/// * automatic ("auto") items are only sent with mode=auto *and* the app toggle on;
///   approved items need an explicit approval on the server;
/// * a job sent from this Mac is never sent again (local ledger), and processing stops at the
///   first mail error.
public struct SendCoordinator: Sendable {
    public enum Outcome: Sendable, Equatable {
        case sent(jobID: Int, to: String, subject: String, recorded: Bool)
        case drafted(jobID: Int, to: String, subject: String)
        case skipped(jobID: Int, reason: String)
    }

    public struct BatchResult: Sendable {
        public var outcomes: [Outcome] = []
        public var error: Error?
        /// The outbox item whose delivery failed (for the "Fehler" row in the Postausgang).
        public var failedItem: OutboxItem?
        public var sentCount: Int { outcomes.filter { if case .sent = $0 { true } else { false } }.count }
    }

    public let api: APIClient
    public let sender: MailSending
    public let ledger: SendLedger
    /// Local CV path from the app settings ("~" allowed); empty = use the server's `cv_attachment`.
    public let attachmentPath: String
    public let fileExists: @Sendable (String) -> Bool
    public let now: @Sendable () -> Date

    public init(api: APIClient, sender: MailSending, ledger: SendLedger, attachmentPath: String,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.sender = sender
        self.ledger = ledger
        self.attachmentPath = attachmentPath
        self.fileExists = fileExists
        self.now = now
    }

    public static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    func message(for email: OutgoingEmail) throws -> MailMessage {
        guard let to = email.to?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty else {
            throw SendError.noRecipient
        }
        let raw = attachmentPath.trimmingCharacters(in: .whitespaces).isEmpty ? (email.attachment ?? "") : attachmentPath
        var attachment: String?
        if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = Self.expand(raw)
            guard fileExists(path) else { throw SendError.attachmentMissing(path) }
            attachment = path
        }
        return MailMessage(fromAddress: email.from, senderName: email.senderName, to: to, subject: email.subject,
                           body: email.body, attachmentPath: attachment)
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now())
    }

    /// Re-sends reports of real sends the server has not acknowledged yet.
    @discardableResult
    public func retryPending() async -> Int {
        var done = 0
        for (jobID, report) in ledger.pending() {
            if (try? await api.recordSent(id: jobID, report)) != nil {
                ledger.markRecorded(jobID)
                done += 1
            }
        }
        return done
    }

    private func deliverAndRecord(jobID: Int, msg: MailMessage, trigger: String) async throws -> Outcome {
        let messageID = try await sender.deliver(msg, .send)
        let report = SentReport(dryRun: false, sentAt: timestamp(), messageId: messageID, to: msg.to,
                                subject: msg.subject, body: msg.body, trigger: trigger)
        ledger.markSent(jobID, report: report)
        var recorded = false
        if (try? await api.recordSent(id: jobID, report)) != nil {
            ledger.markRecorded(jobID)
            recorded = true
        }
        return .sent(jobID: jobID, to: msg.to, subject: msg.subject, recorded: recorded)
    }

    /// "Per Mail senden" (after the user confirmed in the app). Checks the server's rules first;
    /// in dry-run only opens the message in Mail without sending and logs a test entry.
    public func sendNow(jobID: Int) async throws -> Outcome {
        await retryPending()
        let preview = try await api.emailPreview(id: jobID)
        guard preview.canSend, let email = preview.email else {
            throw SendError.notAllowed(preview.blockerTexts.isEmpty ? ["Server erlaubt keinen Versand"] : preview.blockerTexts)
        }
        let msg = try message(for: email)
        if preview.dryRun {
            _ = try await sender.deliver(msg, .draftOnly)
            let report = SentReport(dryRun: true, sentAt: timestamp(), to: msg.to, subject: msg.subject,
                                    body: msg.body, trigger: "manual")
            _ = try? await api.recordSent(id: jobID, report)
            return .drafted(jobID: jobID, to: msg.to, subject: msg.subject)
        }
        guard !ledger.wasSent(jobID) else { throw SendError.alreadySent }
        return try await deliverAndRecord(jobID: jobID, msg: msg, trigger: "manual")
    }

    /// Called after every refresh. Sends what the server's outbox allows right now.
    public func processOutbox(autoSendEnabled: Bool) async -> BatchResult {
        var result = BatchResult()
        await retryPending()
        let outbox: Outbox
        do {
            outbox = try await api.outbox()
        } catch {
            result.error = error  // server unreachable -> never send
            return result
        }
        guard !outbox.killSwitch, outbox.mode != "off", !outbox.dryRun else { return result }
        var budget = outbox.remainingToday
        for item in outbox.items {
            if budget <= 0 { break }
            if !item.isApproved && !(outbox.mode == "auto" && autoSendEnabled) {
                result.outcomes.append(.skipped(jobID: item.jobId, reason: "auto aus"))
                continue
            }
            if ledger.wasSent(item.jobId) {
                result.outcomes.append(.skipped(jobID: item.jobId, reason: "bereits gesendet"))
                continue
            }
            do {
                let msg = try message(for: item.email)
                result.outcomes.append(try await deliverAndRecord(jobID: item.jobId, msg: msg,
                                                                  trigger: item.isApproved ? "approved" : "auto"))
                budget -= 1
            } catch {
                result.error = error  // stop at the first problem (permission, missing CV, …)
                result.failedItem = item
                break
            }
        }
        return result
    }
}
