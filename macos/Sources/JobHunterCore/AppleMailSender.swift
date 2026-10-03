import Foundation

/// Sends through Apple Mail via AppleScript (in-process `NSAppleScript`).
///
/// All values are passed as Apple Event parameters to AppleScript handlers – never spliced into
/// script source – so subjects/bodies with quotes or backslashes cannot break or inject code.
/// The first use triggers macOS' Automation prompt ("JobHunter möchte Mail steuern").
public struct AppleMailSender: MailSending {
    public init() {}

    /// AppleScript with three handlers. Public for tests (compiles with `osacompile`).
    public static let scriptSource = #"""
    on find_account(senderAddress)
        tell application "Mail"
            repeat with acc in (get every account)
                set addrList to (get email addresses of acc)
                repeat with addr in addrList
                    if (contents of addr) is senderAddress then return (contents of acc)
                end repeat
            end repeat
        end tell
        error "Kein Mail-Account mit der Adresse " & senderAddress & " gefunden." number 1001
    end find_account

    on send_mail(senderAddress, senderName, toAddress, theSubject, theBody, attachmentPath, shouldSend)
        set acc to find_account(senderAddress)
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:theSubject, content:theBody, visible:(not shouldSend)}
            tell msg
                set sender to senderName & " <" & senderAddress & ">"
                make new to recipient at end of to recipients with properties {address:toAddress}
            end tell
            if attachmentPath is not "" then
                tell content of msg
                    make new attachment with properties {file name:(POSIX file attachmentPath as alias)} at after last paragraph
                end tell
            end if
            if shouldSend then
                delay 2 -- let Mail finish loading the attachment before sending
                set ok to send msg
                if ok is false then error "Mail hat das Senden abgelehnt." number 1002
                return "sent"
            else
                activate
                return "draft"
            end if
        end tell
    end send_mail

    on account_addresses()
        set out to {}
        tell application "Mail"
            repeat with acc in (get every account)
                set addrList to (get email addresses of acc)
                repeat with addr in addrList
                    set end of out to (contents of addr)
                end repeat
            end repeat
        end tell
        return out
    end account_addresses

    on find_sent(theSubject, toAddress)
        tell application "Mail"
            set found to (messages of sent mailbox whose subject is theSubject)
            repeat with m in found
                repeat with r in (to recipients of m)
                    if (address of r) is toAddress then return message id of m
                end repeat
            end repeat
        end tell
        return ""
    end find_sent
    """#

    public func deliver(_ message: MailMessage, _ delivery: MailDelivery) async throws -> String? {
        let args: [ScriptArg] = [.text(message.fromAddress), .text(message.senderName), .text(message.to),
                                 .text(message.subject), .text(message.body), .text(message.attachmentPath ?? ""),
                                 .flag(delivery == .send)]
        _ = try await Self.call("send_mail", args) { $0.stringValue }
        return nil  // Mail does not expose the Message-ID of an outgoing message
    }

    /// Read-only: e-mail addresses of all accounts configured in Mail.
    public func accountAddresses() async throws -> [String] {
        try await Self.call("account_addresses", []) { result in
            guard result.numberOfItems > 0 else { return [String]() }
            return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
        }
    }

    /// Read-only: Message-ID of a sent message (Mail's "Gesendet" mailbox), matched by subject + recipient.
    public func findSentMessageID(subject: String, to: String) async throws -> String? {
        let id = try await Self.call("find_sent", [.text(subject), .text(to)]) { $0.stringValue ?? "" }
        return id.isEmpty ? nil : id
    }

    /// `message://` URL that opens a message in Mail.
    public static func messageURL(messageID: String) -> URL? {
        let bare = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        guard let enc = "<\(bare)>".addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "message://\(enc)")
    }

    // MARK: AppleScript plumbing

    enum ScriptArg: Sendable {
        case text(String)
        case flag(Bool)
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    @MainActor
    private static func call<T: Sendable>(_ handler: String, _ args: [ScriptArg],
                                          _ transform: (NSAppleEventDescriptor) -> T) throws -> T {
        guard let script = NSAppleScript(source: scriptSource) else { throw SendError.mail("Skript ungültig") }
        let params = NSAppleEventDescriptor.list()
        for (i, arg) in args.enumerated() {
            switch arg {
            case .text(let s): params.insert(NSAppleEventDescriptor(string: s), at: i + 1)
            case .flag(let b): params.insert(NSAppleEventDescriptor(boolean: b), at: i + 1)
            }
        }
        // kASAppleScriptSuite 'ascr' / kASSubroutineEvent 'psbr' / keyASSubroutineName 'snam' / keyDirectObject '----'
        let event = NSAppleEventDescriptor(eventClass: fourCC("ascr"), eventID: fourCC("psbr"),
                                           targetDescriptor: .currentProcess(),
                                           returnID: -1, transactionID: 0)
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: fourCC("snam"))
        event.setParam(params, forKeyword: fourCC("----"))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            let num = error[NSAppleScript.errorNumber] as? Int
            if num == -1743 {
                throw SendError.mail("Keine Berechtigung, Mail zu steuern. Systemeinstellungen › Datenschutz & Sicherheit › Automation › JobHunter › Mail erlauben.")
            }
            throw SendError.mail(msg + (num.map { " (\($0))" } ?? ""))
        }
        return transform(result)
    }
}
