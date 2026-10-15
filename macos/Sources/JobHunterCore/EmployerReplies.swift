import Foundation

// Employer replies ("Rückmeldungen") from the user's mailbox.
//
// The app reads – read-only, nothing is moved, marked or sent – the e-mails employers send about
// applications (Absage, Einladung, "bitte senden Sie uns noch Ihre Zeugnisse", "Ihre
// Gehaltsvorstellung?" …) from the same Apple Mail account as the job alerts and posts them to the
// server (`POST /api/v1/jobs/replies`). The server classifies them, matches them to the application,
// writes a line into the job's notes and counts Rückfrage/Rücksprache and requested documents as
// "Rückmeldung" in the tracker (`jobhunter/replies.py`).

/// One employer e-mail (body of `POST /api/v1/jobs/replies`).
public struct EmployerReplyMail: Codable, Sendable, Hashable {
    public var messageId: String
    public var sender: String
    public var subject: String
    /// Plain text of the mail (Mail's `content`), shortened to `maxBody`.
    public var body: String
    public var receivedAt: String

    public static let maxBody = 20_000

    public init(messageId: String, sender: String, subject: String, body: String, receivedAt: Date) {
        self.messageId = messageId
        self.sender = sender
        self.subject = subject
        self.body = String(body.prefix(Self.maxBody))
        self.receivedAt = ISO8601DateFormatter().string(from: receivedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case sender, subject, body
        case messageId = "message_id"
        case receivedAt = "received_at"
    }
}

/// Response of `POST /api/v1/jobs/replies`.
public struct RepliesResult: Decodable, Sendable, Equatable {
    public var received: Int
    public var matched: [Int]
    public var unmatched: Int
    public var duplicates: Int
    public var invalid: Int
    public var statusChanged: [Int]
    /// absage | einladung | unterlagen | rueckfrage | eingang | sonstiges → count
    public var kinds: [String: Int]
}

public enum EmployerReplyFilter {
    /// Subjects that are about an application (AppleScript `contains` ignores case).
    public static let subjectKeys = [
        "Bewerbung", "application", "Bewerbungsunterlagen", "Vorstellungsgespräch", "Interview",
        "kennenlernen", "Kennenlernen", "Absage", "Rückmeldung", "Unterlagen", "Ihre Kandidatur", "candidature",
    ]
    /// Applicant-tracking systems that send on behalf of employers (any subject, e.g. "Terminverschiebung").
    public static let atsSenders = [
        "personio.de", "softgarden", "join.com", "onlyfy.jobs", "successfactors", "icims", "hrworks",
        "workday", "greenhouse", "lever.co", "recruitee", "smartrecruiters", "dvinci", "rexx-systems",
        "umantis", "concludis", "teamtailor", "ashbyhq",
    ]

    /// Sender patterns for one run: ATS + the domains the user applied to by e-mail (from the jobs).
    public static func senderKeys(applied jobs: [JobSummary]) -> [String] {
        var keys = atsSenders
        for j in jobs where Tracker.isApplied(j) {
            for addr in [j.sendState?.to, j.applyEmail].compactMap({ $0 }) {
                guard let at = addr.lastIndex(of: "@") else { continue }
                let domain = addr[addr.index(after: at)...].lowercased()
                if domain.count >= 4, !keys.contains("@" + domain) { keys.append("@" + domain) }
            }
        }
        return keys
    }

    /// Job-board mails that forward the employer's answer ("Neuigkeiten zu deiner Bewerbung" = StepStone
    /// with the employer's feedback). All other job-board mails (alerts, "ist raus") are not replies.
    public static let boardReplySubjects = ["Neuigkeiten zu deiner Bewerbung", "Neuigkeiten zu Ihrer Bewerbung"]

    /// Job alerts and the user's own mails are never sent as replies.
    public static func isCandidate(_ m: AlertMailMessage, ownAddresses: [String] = []) -> Bool {
        if AlertSource.from(sender: m.sender) != nil {
            return boardReplySubjects.contains { m.subject.localizedCaseInsensitiveContains($0) }
        }
        let s = m.sender.lowercased()
        if ownAddresses.contains(where: { !$0.isEmpty && s.contains($0.lowercased()) }) { return false }
        return !m.subject.isEmpty || !m.source.isEmpty
    }
}

extension AppleMailAlertReader {
    /// `reply_messages(accountName, daysBack, skipIDs, subjectKeys, senderKeys, maxCount)` → list of
    /// {id, secondsFromNow, sender, subject, plain text}. Values are Apple Event parameters only.
    public static let replyScriptSource = #"""
    on find_account(accountName)
        tell application "Mail"
            repeat with acc in (get every account)
                if (name of acc) is accountName then return (contents of acc)
            end repeat
            repeat with acc in (get every account)
                repeat with addr in (get email addresses of acc)
                    if (contents of addr) is accountName then return (contents of acc)
                end repeat
            end repeat
        end tell
        error "Kein Mail-Account „" & accountName & "“ gefunden." number 1001
    end find_account

    on reply_messages(accountName, daysBack, skipIDs, subjectKeys, senderKeys, maxCount)
        set acc to find_account(accountName)
        set cutoff to (current date) - (daysBack * days)
        set out to {}
        set seen to {}
        with timeout of 600 seconds
            tell application "Mail"
                set mb to mailbox "INBOX" of acc
                set found to {}
                repeat with k in subjectKeys
                    set found to found & (messages of mb whose date received ≥ cutoff and subject contains (contents of k))
                end repeat
                repeat with k in senderKeys
                    set found to found & (messages of mb whose date received ≥ cutoff and sender contains (contents of k))
                end repeat
                repeat with m in found
                    if (count of out) ≥ maxCount then exit repeat
                    set mid to message id of m
                    if (skipIDs does not contain mid) and (seen does not contain mid) then
                        set end of seen to mid
                        set secs to ((date received of m) - (current date))
                        set c to ""
                        try
                            set c to content of m
                            if (length of c) > 20000 then set c to text 1 thru 20000 of c
                        end try
                        set end of out to {mid, (secs as integer) as text, (sender of m), (subject of m), c}
                    end if
                end repeat
            end tell
        end timeout
        return out
    end reply_messages
    """#

    public func replyMessages(account: String, daysBack: Int, skipIDs: [String], senderKeys: [String],
                              maxCount: Int) async throws -> [AlertMailMessage] {
        let now = Date.now
        return try await AppleMailSender.call(
            "reply_messages",
            [.text(account), .int(max(1, daysBack)), .texts(skipIDs), .texts(EmployerReplyFilter.subjectKeys),
             .texts(senderKeys), .int(maxCount)],
            source: Self.replyScriptSource
        ) { list in
            guard list.numberOfItems > 0 else { return [AlertMailMessage]() }
            return (1...list.numberOfItems).compactMap { i -> AlertMailMessage? in
                guard let item = list.atIndex(i), item.numberOfItems >= 5,
                      let id = item.atIndex(1)?.stringValue, !id.isEmpty else { return nil }
                let offset = Double(item.atIndex(2)?.stringValue ?? "") ?? 0
                return AlertMailMessage(id: id, receivedAt: now.addingTimeInterval(offset),
                                        sender: item.atIndex(3)?.stringValue ?? "",
                                        subject: item.atIndex(4)?.stringValue ?? "",
                                        source: item.atIndex(5)?.stringValue ?? "")
            }
        }
    }
}

/// Reading replies (separate from the alert protocol so existing readers/mocks stay valid).
public protocol EmployerReplyReading: Sendable {
    /// Employer e-mails of the last `daysBack` days (`source` = plain text), except `skipIDs`.
    func replyMessages(account: String, daysBack: Int, skipIDs: [String], senderKeys: [String],
                       maxCount: Int) async throws -> [AlertMailMessage]
}

extension AppleMailAlertReader: EmployerReplyReading {}

public protocol EmployerReplyAPI: Sendable {
    func employerReplies(_ items: [EmployerReplyMail]) async throws -> RepliesResult
}

extension APIClient: EmployerReplyAPI {
    /// `POST /api/v1/jobs/replies` (newer servers; older ones answer 404/405 → kept queued).
    public func employerReplies(_ items: [EmployerReplyMail]) async throws -> RepliesResult {
        try await send("POST", "jobs/replies", body: try Self.encoder.encode(items))
    }
}

/// Result of one reply run (merged into the job-alert summary).
public struct EmployerReplyOutcome: Sendable, Equatable {
    public var mails = 0
    public var matched = 0
    public var kinds: [String: Int] = [:]
    public var queued = 0
    public var mailError: String?
    public var serverError: String?

    public init() {}

    /// Rückfrage/Rücksprache or documents requested in this run.
    public var requests: Int { (kinds["unterlagen"] ?? 0) + (kinds["rueckfrage"] ?? 0) }

    public var summary: String? {
        guard mails > 0 || mailError != nil || queued > 0 || matched > 0 else { return nil }
        var parts: [String] = []
        if let mailError { parts.append("Antworten nicht lesbar – \(mailError)") }
        if mails > 0 {
            var s = mails == 1 ? "1 Firmen-Mail" : "\(mails) Firmen-Mails"
            if matched > 0 { s += " (\(matched) zugeordnet)" }
            parts.append(s)
        }
        if requests > 0 { parts.append(requests == 1 ? "1 Rückfrage/Unterlagen-Anfrage" : "\(requests) Rückfragen/Unterlagen-Anfragen") }
        if let n = kinds["einladung"], n > 0 { parts.append(n == 1 ? "1 Einladung" : "\(n) Einladungen") }
        if let n = kinds["absage"], n > 0 { parts.append(n == 1 ? "1 Absage" : "\(n) Absagen") }
        if queued > 0 { parts.append("\(queued) Antworten warten auf den Server" + (serverError.map { " (\($0))" } ?? "")) }
        return parts.joined(separator: " · ")
    }
}

public enum EmployerReplyImporter {
    public static let batchSize = 50
    /// Mails read per run at most (the first run reads the whole window).
    public static let maxPerRun = 150

    /// `reader == nil`: only send what is still queued (Mail not running).
    public static func run(state: inout JobAlertState, reader: EmployerReplyReading?, api: EmployerReplyAPI?,
                           account: String, daysBack: Int, senderKeys: [String], ownAddresses: [String] = [],
                           now: Date = .now) async -> EmployerReplyOutcome {
        var out = EmployerReplyOutcome()
        var processed = state.processedReplies ?? [:]
        var pending = state.pendingReplies ?? []
        if let reader { do {
            let messages = try await reader.replyMessages(account: account, daysBack: daysBack,
                                                          skipIDs: Array(processed.keys), senderKeys: senderKeys,
                                                          maxCount: maxPerRun)
            var known = Set(pending.map(\.messageId))
            for m in messages where processed[m.id] == nil {
                processed[m.id] = now
                guard EmployerReplyFilter.isCandidate(m, ownAddresses: ownAddresses), known.insert(m.id).inserted else { continue }
                out.mails += 1
                pending.append(EmployerReplyMail(messageId: m.id, sender: m.sender, subject: m.subject,
                                                 body: m.source, receivedAt: m.receivedAt))
            }
        } catch {
            out.mailError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        } }
        if let api {
            while !pending.isEmpty {
                let batch = Array(pending.prefix(batchSize))
                do {
                    let r = try await api.employerReplies(batch)
                    out.matched += Set(r.matched).count
                    for (k, v) in r.kinds { out.kinds[k, default: 0] += v }
                    pending.removeFirst(batch.count)
                } catch let e as APIError where !SyncEngine.isTransient(e) && !JobAlertImporter.serverLacksImport(e) {
                    pending.removeFirst(batch.count)   // rejected for good (e.g. 422) – never block the queue
                    out.serverError = e.errorDescription
                } catch {
                    if let e = error as? APIError, JobAlertImporter.serverLacksImport(e) {
                        out.serverError = "Server kennt Firmen-Antworten noch nicht (Backend aktualisieren)"
                    } else {
                        out.serverError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                    break
                }
            }
        }
        out.queued = pending.count
        let keep = now.addingTimeInterval(-Double(max(daysBack, 1) + 60) * 86_400)
        state.processedReplies = processed.filter { $0.value >= keep }
        state.pendingReplies = pending
        return out
    }
}
