import Foundation

/// Reads job-alert e-mails from Apple Mail (read-only: nothing is moved, marked or sent).
///
/// Like `AppleMailSender`, every value is passed as an Apple Event parameter to an AppleScript
/// handler – never spliced into script source.
public struct AppleMailAlertReader: AlertMailReading {
    public init() {}

    /// Handlers: `alert_messages(accountName, daysBack, skipIDs, senderPatterns)` and `account_names()`.
    public static let scriptSource = #"""
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

    on alert_messages(accountName, daysBack, skipIDs, senderPatterns)
        set acc to find_account(accountName)
        set cutoff to (current date) - (daysBack * days)
        set out to {}
        tell application "Mail"
            set mb to mailbox "INBOX" of acc
            set seen to {}
            repeat with p in senderPatterns
                set pat to (contents of p)
                set found to (messages of mb whose date received ≥ cutoff and sender contains pat)
                repeat with m in found
                    set mid to message id of m
                    if (skipIDs does not contain mid) and (seen does not contain mid) then
                        set end of seen to mid
                        set secs to ((date received of m) - (current date))
                        set end of out to {mid, (secs as integer) as text, (sender of m), (subject of m), (source of m)}
                    end if
                end repeat
            end repeat
        end tell
        return out
    end alert_messages

    on account_names()
        tell application "Mail"
            return name of every account
        end tell
    end account_names
    """#

    public func alertMessages(account: String, daysBack: Int, skipIDs: [String]) async throws -> [AlertMailMessage] {
        let now = Date.now
        return try await AppleMailSender.call(
            "alert_messages",
            [.text(account), .int(max(1, daysBack)), .texts(skipIDs), .texts(AlertSource.senderPatterns)],
            source: Self.scriptSource
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

    /// Names of the accounts configured in Mail (for the settings picker).
    public func accountNames() async throws -> [String] {
        try await AppleMailSender.call("account_names", [], source: Self.scriptSource) { result in
            guard result.numberOfItems > 0 else { return [String]() }
            return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
        }
    }
}
